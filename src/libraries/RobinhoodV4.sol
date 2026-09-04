// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title RobinhoodV4
/// @notice Canonical Uniswap v4 and FLOCK addresses on Robinhood Chain mainnet (chain id 4663).
/// @dev Source: developers.uniswap.org/contracts/v4/deployments (read 2026-09-03); FLOCK and Safe addresses re-read on-chain.
///      Every address here was re-read on-chain on 2026-09-03 (PoolManager/PositionManager/StateView via cast).
library RobinhoodV4 {
    uint256 internal constant CHAIN_ID = 4663;

    // --- Uniswap v4 core / periphery ---
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant POSITION_DESCRIPTOR = 0x9639443158E8C5efa35Bd45287bf2EFfd3D8dC06;
    address internal constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // --- Deterministic CREATE2 factory used by HookMiner / forge scripts ---
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // --- FLOCK (same hex on Base, Ethereum, BNB, HyperEVM, Robinhood; 18 decimals) ---
    address internal constant FLOCK = 0x5aB3D4c385B400F3aBB49e80DE2fAF6a88A7B691;
    /// @notice CCIP BurnMint pool for FLOCK on Robinhood (owner: governance Safe).
    address internal constant FLOCK_CCIP_POOL = 0x05E42e03996379cd0B6290cC2767A1BDd78B737a;
    /// @notice FLock governance Safe (same address as on Base).
    address internal constant FLOCK_SAFE = 0x6052279aa6BF2E145eDafC7042A9BD6b4A80d31f;

    // --- Robinhood Stock Tokens (Robinhood Assets (Jersey) Ltd, 18 decimals, Chainlink-priced) ---
    address internal constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3; // Alphabet Class A • Robinhood Token
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // NVIDIA • Robinhood Token
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d; // Tesla • Robinhood Token
    address internal constant SNDK = 0xB90A19fF0Af67f7779afF50A882A9CfF42446400; // SanDisk • Robinhood Token
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C; // SPDR S&P 500 • Robinhood Token

    // --- Quote assets ---
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // Paxos Global Dollar
}
