# FLOCK Stock-Pair Hook (Uniswap v4, Robinhood Chain)

`FlockStockPairHook` is the Uniswap v4 hook for FLOCK / <Robinhood Stock Token> pools on Robinhood Chain
(chain id 4663). Pilot pair: **GOOGL / FLOCK**. Hooks are immutable per pool, so the pilot is a **new pool**;
the existing hookless FLOCK/USDG, FLOCK/NVDA, TSLA/FLOCK and FLOCK/SNDK pools are untouched. The same hook contract can serve additional FLOCK/<stock> pools through its registry (`registerPool` +
`initializePool`); no new deployment is needed.

Status: deployed on Robinhood Chain (chain id 4663) at `0x33e924fb8663871bAb61D6844e79CDea159C60c0`; the deployment
record is in `deployments/`. Unit tests and Robinhood mainnet fork tests pass, including a swap through the canonical
Universal Router (the path app.uniswap.org uses) whose output equals the V4Quoter quote. An internal adversarial review
with PoC tests (see `review-poc/`) was run and its findings applied — see "Security review".

## What the hook does

| Capability | Mechanism | Why |
|---|---|---|
| Registry + owner-gated initialisation | owner calls `registerPool(key, feeConfig)` then `initializePool(key, sqrtPrice)`; any direct `PoolManager.initialize` with this hook reverts in `beforeInitialize` | nobody can front-run the launch at a wrong price or create a look-alike pool that borrows the hook's address |
| Paused launch | a freshly initialised pool is **paused**; the owner unpauses after the seed liquidity is in, and that unpause starts the launch-fee clock | closes the init→seed gap (an empty v4 pool's price can otherwise be walked for free) and stops the anti-snipe window from burning before trading starts |
| No-op swap guard | `afterSwap` reverts when a swap exchanged nothing on both sides | the price can only move through real trades; counters cannot be inflated for gas |
| Dynamic LP fee | `beforeSwap` returns `fee \| OVERRIDE_FEE_FLAG`; fee = max(base, launch-decay, closed-market) clamped to `[min, max]` and a 10% hard cap; the stored pool fee is re-synced after each swap so explorers show the live fee | anti-snipe at launch; protect LPs while US markets are closed (stock tokens cannot be minted then) |
| Trade accounting | `afterSwap` records per-trader (`tx.origin`) net FLOCK acquired, gross volumes; swaps moving ≥ `minCountedStock` also count towards swap count, unique traders and first-trade time; emits `StockPairSwap` | exposes per-pool aggregates (per-address net FLOCK, gross volumes, counted swaps) for off-chain analytics; informational only |
| Pause | owner can pause swaps per pool; liquidity removal is never affected (no remove-liquidity callback) | incident response |
| Governance | `Ownable2Step`, owner = FLock Safe (or the ops EOA for a faster pilot, then handed to the Safe), `renounceOwnership` disabled, no proxy | fee schedule and pause always have an accountable owner; not upgradeable |

What it deliberately does **not** do: no return-delta flags (it never takes a cut of a swap), no `hookData`,
no liquidity callbacks (third-party LPs are allowed), no custody of funds, no tick-dependent fee (a surge fee was
removed because empty ranges make the tick griefable), no upgradeability. Consequences: the canonical `V4Quoter` and
Universal Router execute it exactly (`test/fork/UniversalRouterPath.fork.t.sol`). Routing is **not automatic**:
Uniswap Labs' allowlist page (developers.uniswap.org/hook-allowlist) states that hooks using the `dynamicFees`
flag must submit the allowlist form (automatic allowlisting only covers hooks with none of `beforeSwapReturnsDelta`,
`afterSwapReturnsDelta`, `dynamicFees` and no `0x91…` address). Submit the form right after step 00 and verify
routing empirically with a dust pool before relying on it; until approval the pool is reachable through the
PoolManager/Universal Router directly and through aggregators that index v4 pools, not necessarily through app.uniswap.org.
All fee income accrues to liquidity providers; the hook takes no share of any swap.

Permission bits encoded in the address: `beforeInitialize | beforeSwap | afterSwap` = `0x20C0` (8384). The
deploy script rejects addresses starting with `0x91`.

## Fee schedule (script defaults; hundredths of a bip, 10_000 = 1%)

| Parameter | Default | Meaning |
|---|---|---|
| `baseFee` | 3_000 (0.30%) | steady state; keeps the pool competitive with the two-hop FLOCK→USDG→GOOGL route (0.25% + 0.30% on the active pools) so routers use it |
| `minFee` / `maxFee` | 2_500 / 10_000 | clamp; `maxFee` ≤ `HARD_MAX_FEE` = 100_000 (10%) |
| `launchFee` / `launchSeconds` | 10_000 / 1_800 | 1% at unpause, decaying linearly to `baseFee` over 30 minutes (time-based; `block.number` on Robinhood is the Ethereum L1 block) |
| `closedMarketFee` | 6_000 (0.60%) | applied from Friday 20:00 UTC to Monday 14:30 UTC (covers NYSE hours in both DST regimes); US holidays are not modelled |
| `minCountedStock` | 3e16 (0.03 GOOGL ≈ $10) | swaps moving less stock token than this update `netFlock`/volumes but not the trader/swap counters |

`previewFee(poolId)` returns the fee the next swap would pay; `poolState(poolId)`, `feeConfig(poolId)` and
`poolKey(poolId)` expose everything a dashboard needs. The owner can change the schedule with `setFeeConfig`.

## Repository layout

```
src/FlockStockPairHook.sol        the hook
src/libraries/RobinhoodV4.sol     canonical addresses (PoolManager, PositionManager, Quoter, Universal Router, FLOCK, stock tokens, Safe)
test/FlockStockPairHook.t.sol     unit tests: registry, init gate, paused launch, no-op guard, fee schedule, accounting, pause, ownership, fuzz
test/fork/*.t.sol                 Robinhood mainnet fork: deploy → register → init → single-sided seed → unpause → quote == swap (hookmate router and Universal Router) → accounting
script/00_DeployHook.s.sol        HookMiner + CREATE2 deploy; writes deployments/<chain>-<hook>.json
script/01_RegisterPool.s.sol      register pool key + fee schedule (direct if owner is the broadcaster, else Safe Transaction Builder JSON)
script/02_InitializeAndSeed.s.sol initialise through the hook (owner, paused) → seed single-sided FLOCK → unpause (owner)
script/03_SmokeSwap.s.sol         quote with V4Quoter and swap through the Universal Router
script/04_ReadState.s.sol         read-only status for the launch checklist / monitoring
script/05_AddCoreLiquidity.s.sol  two-sided position straddling spot (exact stock-token leg, FLOCK leg derived)
script/06_RebalanceCore.s.sol     builds (never broadcasts) a Safe batch moving part of a position into a stock-only band above spot
review-poc/                       PoC tests from the internal security review (against earlier revisions; not compiled)
```

## Build and test

```bash
forge build
forge test --no-match-path "test/fork/*"
forge test --match-path "test/fork/*" --fork-url robinhood
```

Rehearse the whole launch on a local fork. `broadcast/` is git-ignored because rehearsal artifacts on a fork of
chain 4663 look exactly like mainnet runs (anvil account 0 is `0xf39F…2266`); after a mainnet run, copy
`broadcast/*/4663/run-latest.json` into `deployments/` next to the JSON written by `00_DeployHook` and delete the
rehearsal files.

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 4663 --port 8546
# mint FLOCK to the anvil account by impersonating the CCIP pool, then run 00 → 01 → 02 → 03 → 04 against
# http://127.0.0.1:8546 with HOOK_OWNER / LP_RECIPIENT = the anvil account; rm -rf broadcast deployments/4663-* afterwards.
```

## Launch sequence (mainnet)

Everything below is a dry run until you add `--broadcast`. Use a Foundry keystore (`--account <name>`), never a
raw private key on the command line. Use `--slow` for multi-transaction scripts so a failed step stops the run.

0. **Pre-flight**
   - Decide the hook owner (a Safe, or an EOA with a later `transferOwnership` to the Safe) and the LP recipient (Safe
     recommended). When the owner is a Safe the scripts write Transaction Builder JSON and print raw `to / data`.
   - Make sure the seeding wallet holds the FLOCK to be seeded on chain 4663 and a little ETH for gas.

1. **Deploy the hook** (verification goes to Blockscout, not Etherscan)
   ```bash
   export HOOK_OWNER=0x6052279aa6BF2E145eDafC7042A9BD6b4A80d31f   # FLock Safe, or the ops EOA for the pilot
   forge script script/00_DeployHook.s.sol --rpc-url robinhood --account <keystore> --broadcast \
     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
   export HOOK_ADDRESS=<printed address>      # also recorded in deployments/4663-<hook>.json
   ```
   If verification fails after the deploy, retry with `forge verify-contract <hook> src/FlockStockPairHook.sol:FlockStockPairHook
   --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --constructor-args $(cast abi-encode
   "constructor(address,address,address)" <poolManager> <FLOCK> <owner>)`.
   Verify with `04_ReadState`: permission bits 8384, `0x91` prefix false, return-delta false, owner as expected.

2. **Register the pool key and fee schedule** (owner action)
   ```bash
   export STOCK_TOKEN=0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3   # GOOGL • Robinhood Token
   forge script script/01_RegisterPool.s.sol --rpc-url robinhood --account <keystore> --broadcast
   ```
   If the owner is the Safe, the script writes `safe-batches/registerPool-GOOGL-4663.json` for the Safe
   Transaction Builder instead of broadcasting. Fee env vars: `BASE_FEE MIN_FEE MAX_FEE LAUNCH_FEE LAUNCH_SECONDS
   CLOSED_MARKET_FEE MIN_COUNTED_STOCK_E18`. Values that would truncate or exceed the 10% hard cap are rejected.

3. **Initialise (owner, pool starts paused) → seed single-sided FLOCK → unpause (owner)** — add `UNPAUSE=false` to stop after the seed with the pool still paused, then unpause later with `setPaused(poolId,false)` from the owner key
   ```bash
   # FLOCK per GOOGL → tick. GOOGL $343.74 / FLOCK $0.0388 ≈ 8,860 FLOCK per GOOGL → tick ≈ 90,860.
   export INIT_TICK=90780 SEED_FLOCK=2600000 RANGE_SPACINGS=60 LP_RECIPIENT=<Safe> STOCK_USD_E6=343740000
   forge script script/02_InitializeAndSeed.s.sol --rpc-url robinhood --account <keystore> --broadcast --slow
   ```
   The script refuses to run unless `INIT_TICK` is within `MAX_TICK_DEVIATION` (default 2,000 ticks ≈ 22%) of the
   price implied by the live FLOCK/USDG pool and `STOCK_USD_E6` (override only with `SKIP_TICK_CHECK=true`).
   - Owner == broadcaster: initialise (paused) → mint → unpause in one run (3 transactions).
   - Owner == Safe: run 1 writes `safe-batches/initializePool-GOOGL-4663.json`; after the Safe executes it, run 2
     mints the seed (the pool is still paused, so nothing can trade or move the price) and writes
     `safe-batches/unpause-GOOGL-4663.json`; the Safe's unpause is the launch and starts the launch-fee clock.
   The band ends exactly at spot: at T0 active liquidity is 0 and the first GOOGL→FLOCK buy crosses into it.

4. **Smoke test through the Uniswap path**
   ```bash
   AMOUNT_IN_E18=10000000000000000 forge script script/03_SmokeSwap.s.sol --rpc-url robinhood --account <keystore> --broadcast
   ```
   Buys FLOCK with 0.01 GOOGL through the Universal Router, asserts `V4Quoter` quote == executed output, and
   revokes its allowances.

5. **After launch**
   - `forge script script/04_ReadState.s.sol --rpc-url robinhood` for the checklist; the same reads can feed operational
     monitoring (paused flag, fee preview, stored fee, counters).
   - Optionally submit the hook to the Uniswap hook registry (`github.com/Uniswap/hooklist`); this is informational
     only and does not affect routing (see the allowlist note above).
   - Submit Uniswap Labs' hook allowlist form (developers.uniswap.org/hook-allowlist) immediately after step 00 —
     required for `dynamicFees` hooks; attach the Blockscout-verified address, permission bits (0x20C0), `HARD_MAX_FEE()`,
     and the note that the hook is non-upgradeable and takes no hookData. app.uniswap.org routing depends on Uniswap Labs' allowlist decision and is not guaranteed.
   - Pause switch: `setPaused(poolId, true)` by the owner; LPs can always exit. To exit the Safe-held position the
     Safe calls `PositionManager.modifyLiquidities(abi.encode(DECREASE_LIQUIDITY + TAKE_PAIR, params), deadline)`
     itself (no approvals needed); use a deadline of days to allow for multisig latency.

## Operations recipes

- **Ownership handover (EOA pilot → Safe):** owner EOA calls `transferOwnership(<Safe>)`; the Safe executes
  `acceptOwnership()` (calldata `0x79ba5097`). Until acceptance the EOA remains owner; nothing else changes.
- **Incident:** owner calls `setPaused(poolId, true)` (swaps revert, LPs can exit); adjust with
  `setFeeConfig(poolId, cfg)`; `setPaused(poolId, false)` resumes (the launch clock only starts on the first unpause).
- **Safe exit of the LP NFT:** the Safe calls `PositionManager.modifyLiquidities(abi.encode(actions, params), deadline)`
  with actions `DECREASE_LIQUIDITY, TAKE_PAIR`, params `[(tokenId, liquidity, 0, 0, "")], (currency0, currency1, <Safe>)`
  and a deadline of days; no approvals are needed because the Safe owns the NFT.
- **Post-launch verification:** `04_ReadState` (paused false, launchTs set, stored fee tracking the live fee),
  a Uniswap routing-API / app quote that routes through the pool, and the first `StockPairSwap` events on Blockscout.
- **Rollback:** pause the pool, exit the LP position to the Safe, leave the empty pool (v4 pools cannot be deleted),
  ask the aggregators to hide it, and disclose.
- **Before any mainnet broadcast:** commit and tag the exact revision, run `forge build --force`, the unit suite and
  the fork suite from a clean checkout, and record the tag alongside the deployment JSON; the deploy script records hook, salt,
  owner and timestamp in `deployments/`.

## Security review

An internal security review of an earlier revision (v4 security, economics, operations) produced the PoC tests in
`review-poc/`; every finding was re-checked against the current revision and all code findings are resolved. The
resulting 15-test regression suite runs in `test/review/VerifierPoC.t.sol`. Applied: owner-gated initialisation (front-run initialise), paused start + unpause-anchored launch
clock (init→seed gap, launch window burn), no-op swap revert (free price walks, phantom counters, surge griefing),
surge fee removed, closed-market window instead of UTC weekend, stored-fee sync, `registerPool` ordering/tick-spacing
checks, `RenounceDisabled` error, counted-swap threshold, env-var range checks, mandatory tick sanity check,
approval revocation, Blockscout verification flags, deployment records, chain guards, `initBlock` dropped (L1 block
number on Orbit chains). Known and accepted: `tx.origin` attribution (data only), third-party LPs share fees, the
single-sided band has no liquidity above spot and none below its lower tick (re-range from the LP wallet), stock-token
issuer controls (pause/block/admin burn), US holidays not in the closed-market window.

## Risks and known limitations

- **`tx.origin` identity.** Smart-contract wallets and bundlers appear as their relayer in the accounting; the data is
  informational only.
- **Single-sided band ends at spot.** Until the first GOOGL→FLOCK buy, active liquidity is 0 and FLOCK→GOOGL
  sells revert (there is nothing to sell into). If the price falls below the band all FLOCK is sold and buys revert
  until liquidity is re-ranged; if the price moves above the initial tick there is no liquidity above it either.
  A small two-sided position straddling spot removes both edges (see `05_AddCoreLiquidity`); a stock-only band further above
  spot lets arbitrage keep tracking the pool price after larger moves (see `06_RebalanceCore`).
- **Third-party LPs are allowed.** They share fee income and can JIT the pool; the alternative (hook-owned,
  single-LP liquidity) needs the hook to custody positions and was judged too much surface for a pilot.
- **Fee income is LP income.** The hook never custodies funds and takes no share of any swap.
- **Weekend dislocations.** Stock tokens cannot be minted or redeemed while US markets are closed; the closed-market
  fee mitigates LP gap risk but does not remove it.
