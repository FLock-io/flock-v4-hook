// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title FlockStockPairHook
/// @notice Uniswap v4 hook for FLOCK / <Robinhood Stock Token> pools on Robinhood Chain.
///
/// What it does (and deliberately does not do):
///  - Registry + owner-gated initialisation: a pool can only be created through `initializePool`, called by the
///    owner (FLock governance) on a pre-registered `PoolKey`. Any other initialiser hits `beforeInitialize` and
///    reverts, so nobody can front-run the launch with a wrong price or create a look-alike pool that borrows the
///    hook's address. (When the hook itself calls `PoolManager.initialize`, v4 skips the hook callbacks, so the
///    state is recorded directly in `initializePool`.) A freshly initialised pool starts PAUSED: the owner
///    unpauses it once the seed liquidity is in place, and that moment starts the launch-fee clock.
///  - Dynamic LP fee, applied per swap through the override-fee flag:
///      * launch fee that decays linearly to the base fee over the first N seconds after unpause (anti-snipe),
///      * closed-market fee while US equity markets are shut (Fri 20:00 UTC → Mon 14:30 UTC, covering both DST
///        regimes) because Robinhood Stock Tokens cannot be minted by the authorised participant then, so LPs
///        carry the gap risk alone,
///      * all clamped to [minFee, maxFee] and to a hard cap of 10%.
///    The fee depends only on configuration and time, never on the pool tick: with single-sided liquidity the
///    tick can be moved through empty ranges, so any tick-based surcharge would be griefable.
///  - No-op swaps are rejected: a swap that exchanges nothing (zero delta on both sides, i.e. a walk through empty
///    liquidity) reverts, so the pool price can only move through real trades and counters cannot be inflated.
///  - Transparent trade accounting for dashboards: per-trader net FLOCK acquired through the pool, first-trade
///    timestamp, gross volumes, swap count and unique traders (counted only above `minCountedStock`), plus a rich
///    `StockPairSwap` event. Informational only.
///  - Pause switch per pool (swaps revert; liquidity can always be removed because the hook has no
///    remove-liquidity callback).
///
///  It takes NO share of any swap (no return-delta flags), requires NO hookData, and is NOT upgradeable. It quotes
///  exactly through the V4Quoter and the Universal Router, and all fee income stays with liquidity providers.
///  NOTE: because the pool uses the dynamic-fee flag, Uniswap Labs' routing allowlist policy
///  (developers.uniswap.org/hook-allowlist) requires submitting the allowlist form; routing is NOT automatic.
///
///  Trader identity uses `tx.origin`: routers (Universal Router, aggregators) are the `sender` seen by the
///  PoolManager, so the EOA that signed the transaction is the only trust-minimised identity available without
///  hookData. Smart-contract wallets therefore appear as their relayer; documented for the dashboard.
contract FlockStockPairHook is BaseHook, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // ---------------------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Fees are in hundredths of a bip (1e6 = 100%), like Uniswap LP fees.
    struct FeeConfig {
        uint24 baseFee; // steady-state fee, e.g. 3_000 = 0.30%
        uint24 minFee; // floor
        uint24 maxFee; // cap (<= HARD_MAX_FEE)
        uint24 launchFee; // fee right after unpause, decays linearly to baseFee over launchSeconds
        uint24 closedMarketFee; // applied while US markets are closed when >= the fee otherwise due
        uint32 launchSeconds; // seconds the launch fee decays over (0 disables)
        uint128 minCountedStock; // swaps moving less stock token than this do not count as traders/swaps
    }

    struct PoolState {
        bool registered;
        bool initialized;
        bool paused;
        bool flockIsCurrency0;
        uint40 initTs; // initialisation timestamp (informational)
        uint40 launchTs; // first unpause timestamp; launch-fee decay anchor (0 until unpaused)
        int24 lastTick; // tick after the most recent swap (informational)
        uint40 lastSwapTs; // timestamp of the most recent swap
        uint64 swapCount; // counted swaps (>= minCountedStock)
        uint64 uniqueTraders; // counted traders (>= minCountedStock)
        uint256 flockVolume; // gross FLOCK moved through the pool
        uint256 stockVolume; // gross stock token moved through the pool
    }

    // ---------------------------------------------------------------------------------------------------------
    // Constants / immutables
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Absolute ceiling for any configured fee: 10%.
    uint24 public constant HARD_MAX_FEE = 100_000;

    /// @notice The FLOCK token; every registered pool must contain it.
    address public immutable flock;

    // ---------------------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------------------

    mapping(PoolId => FeeConfig) private _feeConfig;
    mapping(PoolId => PoolState) private _poolState;
    mapping(PoolId => PoolKey) private _poolKey;

    /// @notice Net FLOCK acquired by `trader` through the pool (positive = bought more than sold).
    mapping(PoolId => mapping(address => int256)) public netFlock;
    /// @notice Timestamp of the trader's first counted swap in the pool (0 if never).
    mapping(PoolId => mapping(address => uint40)) public firstTradeAt;

    /// @dev Fee chosen in beforeSwap, read back in afterSwap for the event and the stored-fee sync. Transient.
    uint24 private transient _pendingFee;

    // ---------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------

    event PoolRegistered(PoolId indexed poolId, PoolKey key, bool flockIsCurrency0, FeeConfig config);
    event FeeConfigUpdated(PoolId indexed poolId, FeeConfig config);
    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tick);
    event PausedSet(PoolId indexed poolId, bool paused);
    event LaunchStarted(PoolId indexed poolId, uint40 launchTs);
    event StockPairSwap(
        PoolId indexed poolId,
        address indexed trader,
        address indexed sender,
        bool zeroForOne,
        int128 amount0,
        int128 amount1,
        int256 flockDelta,
        uint24 fee,
        int24 tickAfter
    );

    // ---------------------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------------------

    error PoolNotRegistered();
    error PoolAlreadyRegistered();
    error PoolNotInitialized();
    error PoolAlreadyInitialized();
    error PoolPaused();
    error NotDynamicFee();
    error NotFlockPair();
    error InvalidFeeConfig();
    error InitializerNotHook();
    error NoOpSwap();
    error RenounceDisabled();
    error ZeroAddress();

    // ---------------------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------------------

    constructor(IPoolManager _poolManager, address _flock, address _owner) BaseHook(_poolManager) Ownable(_owner) {
        if (_flock == address(0) || _owner == address(0)) revert ZeroAddress();
        flock = _flock;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Hook permissions
    // ---------------------------------------------------------------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------------------
    // Owner (FLock governance) administration
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Pre-register a FLOCK/<stock> pool so it can be initialised (by the owner) with this hook.
    function registerPool(PoolKey calldata key, FeeConfig calldata config) external onlyOwner {
        if (address(key.hooks) != address(this)) revert InvalidPool();
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        if (Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)) revert InvalidPool();
        if (key.tickSpacing < TickMath.MIN_TICK_SPACING || key.tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidPool();
        }
        bool flockIs0 = Currency.unwrap(key.currency0) == flock;
        bool flockIs1 = Currency.unwrap(key.currency1) == flock;
        if (flockIs0 == flockIs1) revert NotFlockPair(); // exactly one side must be FLOCK
        _validateFeeConfig(config);

        PoolId id = key.toId();
        PoolState storage st = _poolState[id];
        if (st.registered) revert PoolAlreadyRegistered();
        st.registered = true;
        st.flockIsCurrency0 = flockIs0;
        _feeConfig[id] = config;
        _poolKey[id] = key;

        emit PoolRegistered(id, key, flockIs0, config);
    }

    /// @notice Initialise a registered pool at `sqrtPriceX96`. Only the owner can do this, and only through the
    ///         hook: direct `PoolManager.initialize` calls by anyone else revert in `beforeInitialize`.
    ///         The pool starts PAUSED so nothing can trade (or walk the empty price) before the seed is in place;
    ///         call `setPaused(id, false)` after seeding — that starts the launch-fee clock.
    /// @dev v4 skips hook callbacks when the hook itself is the caller, so all initialisation state is recorded here.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external onlyOwner returns (int24 tick) {
        PoolId id = key.toId();
        PoolState storage st = _poolState[id];
        if (!st.registered) revert PoolNotRegistered();
        if (st.initialized) revert PoolAlreadyInitialized();

        tick = poolManager.initialize(key, sqrtPriceX96);

        st.initialized = true;
        st.paused = true;
        st.initTs = uint40(block.timestamp);
        st.lastTick = tick;

        // Store the steady-state fee as the pool's default LP fee so explorers show a sensible number; swaps are
        // priced by the per-swap override and the stored value is re-synced whenever the override changes.
        poolManager.updateDynamicLPFee(key, _feeConfig[id].baseFee);

        emit PoolInitialized(id, sqrtPriceX96, tick);
        emit PausedSet(id, true);
    }

    /// @notice Update the fee schedule of a registered pool.
    function setFeeConfig(PoolId id, FeeConfig calldata config) external onlyOwner {
        if (!_poolState[id].registered) revert PoolNotRegistered();
        _validateFeeConfig(config);
        _feeConfig[id] = config;
        emit FeeConfigUpdated(id, config);
    }

    /// @notice Pause / unpause swaps in a pool. Liquidity removal is never affected. The first unpause of an
    ///         initialised pool starts the launch-fee clock.
    function setPaused(PoolId id, bool paused) external onlyOwner {
        PoolState storage st = _poolState[id];
        if (!st.registered) revert PoolNotRegistered();
        st.paused = paused;
        emit PausedSet(id, paused);
        if (!paused && st.initialized && st.launchTs == 0) {
            st.launchTs = uint40(block.timestamp);
            emit LaunchStarted(id, st.launchTs);
        }
    }

    /// @dev Ownership renouncement is disabled: the pause switch and fee schedule must always have an owner.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------

    function feeConfig(PoolId id) external view returns (FeeConfig memory) {
        return _feeConfig[id];
    }

    function poolState(PoolId id) external view returns (PoolState memory) {
        return _poolState[id];
    }

    function poolKey(PoolId id) external view returns (PoolKey memory) {
        return _poolKey[id];
    }

    /// @notice The fee a swap submitted right now would pay (reverts while the pool is not initialised).
    function previewFee(PoolId id) external view returns (uint24) {
        PoolState storage st = _poolState[id];
        if (!st.initialized) revert PoolNotInitialized();
        return _computeFee(st, _feeConfig[id]);
    }

    /// @notice True while US equity markets are closed for the weekend: from Friday 20:00 UTC (NYSE close in
    ///         summer time) to Monday 14:30 UTC (NYSE open in winter time), inclusive of both DST regimes.
    ///         US holidays are not modelled; the owner can raise `baseFee` around them if needed.
    function isMarketClosed(uint256 timestamp) public pure returns (bool) {
        // 1970-01-01 was a Thursday. With Sunday = 0: dayOfWeek = (days + 4) % 7.
        uint256 dayOfWeek = (timestamp / 1 days + 4) % 7;
        uint256 secondsIntoDay = timestamp % 1 days;
        if (dayOfWeek == 6 || dayOfWeek == 0) return true; // Saturday, Sunday
        if (dayOfWeek == 5 && secondsIntoDay >= 20 hours) return true; // Friday after the close
        if (dayOfWeek == 1 && secondsIntoDay < 14 hours + 30 minutes) return true; // Monday before the open
        return false;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Only reached when someone other than the hook calls `PoolManager.initialize` with this hook in the key
    ///      (the PoolManager skips callbacks for the hook's own calls). Always reject.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert InitializerNotHook();
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolState storage st = _poolState[id];
        if (!st.initialized) revert PoolNotInitialized();
        if (st.paused) revert PoolPaused();

        uint24 fee = _computeFee(st, _feeConfig[id]);
        _pendingFee = fee;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // A swap that exchanged nothing only moved the price through empty liquidity: reject it.
        if (delta.amount0() == 0 && delta.amount1() == 0) revert NoOpSwap();

        PoolId id = key.toId();
        int256 flockDelta = _account(id, delta);
        int24 tickAfter = _recordTickAndSyncFee(id, key);

        emit StockPairSwap(
            id, tx.origin, sender, params.zeroForOne, delta.amount0(), delta.amount1(), flockDelta, _pendingFee, tickAfter
        );
        return (this.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Trade accounting. Deltas are from the swapper's point of view: positive = received, negative = paid.
    ///      `netFlock` is always updated; the counters only for swaps moving at least `minCountedStock`.
    function _account(PoolId id, BalanceDelta delta) internal returns (int256 flockDelta) {
        PoolState storage st = _poolState[id];
        int256 a0 = delta.amount0();
        int256 a1 = delta.amount1();
        flockDelta = st.flockIsCurrency0 ? a0 : a1;
        int256 stockDelta = st.flockIsCurrency0 ? a1 : a0;

        address trader = tx.origin;
        netFlock[id][trader] += flockDelta;
        uint256 stockAbs = _abs(stockDelta);
        unchecked {
            st.flockVolume += _abs(flockDelta);
            st.stockVolume += stockAbs;
        }
        if (stockAbs >= _feeConfig[id].minCountedStock) {
            if (firstTradeAt[id][trader] == 0) {
                firstTradeAt[id][trader] = uint40(block.timestamp);
                unchecked {
                    st.uniqueTraders += 1;
                }
            }
            unchecked {
                st.swapCount += 1;
            }
        }
    }

    /// @dev Records the post-swap tick (informational) and keeps the pool's stored LP fee equal to the fee just
    ///      charged, so explorers and StateView show the live schedule (one SSTORE only when it changed).
    function _recordTickAndSyncFee(PoolId id, PoolKey calldata key) internal returns (int24 tickAfter) {
        PoolState storage st = _poolState[id];
        uint24 storedFee;
        (, tickAfter,, storedFee) = poolManager.getSlot0(id);
        st.lastTick = tickAfter;
        st.lastSwapTs = uint40(block.timestamp);
        if (storedFee != _pendingFee) poolManager.updateDynamicLPFee(key, _pendingFee);
    }

    function _computeFee(PoolState storage st, FeeConfig storage cfg) internal view returns (uint24 fee) {
        fee = cfg.baseFee;

        // 1) Launch phase: linear decay from launchFee to baseFee over launchSeconds after the first unpause.
        //    Before the first unpause (launchTs == 0) the full launch fee applies.
        if (cfg.launchSeconds > 0 && cfg.launchFee > cfg.baseFee) {
            uint256 elapsed = st.launchTs == 0 ? 0 : block.timestamp - st.launchTs;
            if (elapsed < cfg.launchSeconds) {
                uint24 launch =
                    cfg.launchFee - uint24((uint256(cfg.launchFee - cfg.baseFee) * elapsed) / cfg.launchSeconds);
                if (launch > fee) fee = launch;
            }
        }

        // 2) Closed market: the AP cannot mint stock tokens, LPs carry the gap risk alone.
        if (cfg.closedMarketFee > fee && isMarketClosed(block.timestamp)) fee = cfg.closedMarketFee;

        // 3) Clamp.
        if (fee < cfg.minFee) fee = cfg.minFee;
        if (fee > cfg.maxFee) fee = cfg.maxFee;
    }

    function _validateFeeConfig(FeeConfig calldata c) internal pure {
        if (c.maxFee > HARD_MAX_FEE) revert InvalidFeeConfig();
        if (c.minFee > c.baseFee || c.baseFee > c.maxFee) revert InvalidFeeConfig();
        if (c.launchFee > c.maxFee || c.closedMarketFee > c.maxFee) revert InvalidFeeConfig();
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
