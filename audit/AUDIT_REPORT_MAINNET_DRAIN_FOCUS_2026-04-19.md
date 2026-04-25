# Doppi Mainnet Security Review
## Fresh Drain and Deadlock Focus

**Date:** 2026-04-19  
**Scope:** Mainnet contracts under [src/mainnet](src/mainnet)  
**Review style:** Manual source review with emphasis on fund drain, stuck funds, automation deadlocks, settlement edge cases, and loop-related denial of service.

---

## Executive Summary

This pass did **not** identify a simple unauthenticated “instant drain” primitive across the reviewed mainnet contracts.

The more realistic risk is different:

- **LP value leakage through settlement accounting edge cases**
- **stuck funds when automation or cross-contract dependencies fail**
- **gas-sensitive range scans that can eventually deadlock settlement or unwind paths**

Overall, the protocol appears to rely heavily on **correct upkeep execution, bounded strike-range growth, and accurate partial-fill accounting**. That means the main danger is **slow loss or lockup under stressed conditions**, not necessarily a one-transaction exploit.

---

## Risk Snapshot

| ID | Severity | Title |
|---|---|---|
| F-01 | Low | Partial-fill settlement can misattribute proceeds and overcharge the LP backstop — **Fixed** ✅ |
| F-02 | Low | Bound-scanning loops can deadlock automation under wide or fragmented strike ranges — **Fixed** |
| F-03 | Low | Emergency LP exit is mitigated, but still depends on owner-coordinated emergency settlement |
| F-04 | Low | Missing unwind bookkeeping on swap-assisted settlement paths can accumulate untracked inventory drift |
| F-05 | Low | Forwarder misconfiguration can halt automated settlement and bot execution — **Fixed** ✅ |

---

## Detailed Findings

### F-01 — Low ✅ Fixed
### Partial-fill settlement can misattribute proceeds and overcharge the LP backstop

**Impacted areas**  
- [src/mainnet/DoppiCore.sol](src/mainnet/DoppiCore.sol#L442-L520)  
- [src/mainnet/DoppiCore.sol](src/mainnet/DoppiCore.sol#L956-L972)

**Observation**

Settlement for traded positions uses the formula below in both strike and no-strike flows:

- user share of traded output is derived from remaining strike bucket state
- the calculation uses the **full position amount** relative to the bucket’s remaining swapped amount

At the same time, the helper that decides whether a position is “traded” only checks whether the remaining untraded amount is smaller than the position size.

That combination is fragile during **partial fills**.

**Why this matters**

If a strike bucket has only been partially executed, the next position settled at that strike can be treated as though a larger portion of its size was already hedged than actually was. That creates two bad outcomes:

1. **too much output is attributed to the position**, or  
2. the remaining shortfall is silently pushed onto the LP through the interest or settlement backstop.

In a stressed market, repeated partial fills can therefore cause **value leakage from the pool** and inconsistent payout accounting between users.

**Impact**

- LP can absorb losses that should not be socialized
- settlement outcomes become order-dependent within the same strike bucket
- under some balance conditions, settlement can revert and temporarily freeze expiries

**Recommendation**

Use an explicit traded portion for each position:

- tradedPortion = minimum of position amount and remaining swapped amount
- allocate output only against tradedPortion
- settle the untraded remainder through the normal LP path

This should be handled consistently in both the strike and no-strike branches.

**Fix applied**

All four attack surfaces are now addressed in `_prepareSettlementPlan` and the downstream settle helpers:

1. **Stale-read / double-allocation** — per-strike capacity is seeded from storage on the *first encounter only* into in-memory arrays (`bRemSwap`, `bRemOut` for buys; `sRemSwap`, `sRemOut` for sells). Every subsequent position at the same strike reads from the already-depleted in-memory remainder, not from raw storage. This eliminates double-allocation entirely.

2. **Proportional output attribution** — `myAmountOut` is computed as `remOut * tradedPortion / remSwap` against the in-memory remainder. No position can be over-credited relative to the bucket it actually consumed.

3. **Partial-fill 3-state handling** — `SettlementPlan.tradeState` is `0` (none), `1` (partial), or `2` (full). Both `_settleStrikePlanned` and `_settleNoStrikePlanned` branch on this value; the untraded remainder is routed through the LP path rather than silently socialized.

4. **Emergency settlement path** — `_emergencySettlement` now routes through `_settleNoStrikePlanned` with `tradedPortion` and `myAmountOut` derived from the current opportunity state, consistent with the planned settlement logic.

---

### F-02 — Low ✅ Fixed
### Bound-scanning loops can deadlock automation under wide or fragmented strike ranges

**Impacted areas**  
- [src/mainnet/DoppiCore.sol](src/mainnet/DoppiCore.sol#L642-L770)  
- [src/mainnet/DoppiLiquidity.sol](src/mainnet/DoppiLiquidity.sol#L248-L334)  
- [src/mainnet/DoppiLiquidity.sol](src/mainnet/DoppiLiquidity.sol#L411-L457)  
- [src/mainnet/DoppiTraderAdminView.sol](src/mainnet/DoppiTraderAdminView.sol#L107-L156)  
- stress-test reference: [test/mainnet/DoppiCoreGasTest.t.sol](test/mainnet/DoppiCoreGasTest.t.sol)

**Observation**

Several critical paths previously scanned price buckets from the current lower bound to the current upper bound, one step at a time — O(range / priceGap), visiting empty buckets.

This pattern appeared in:

- bound refresh logic
- opportunity discovery
- unwind discovery
- cleanup paths (`_getRemovingPrices` in DoppiLiquidity, `_calcPnL` in DoppiTraderAdminView)

**Fix applied**

All three contracts now maintain a sorted doubly-linked list of **active strike nodes** (`StrikeNode { prev, next, active }`), with `head`/`tail` pointers per side:

- `DoppiCore`: `_scanActiveStrikes` traverses `buyStrikeNodes`/`sellStrikeNodes`; `_syncStrikeState` activates/deactivates nodes on deposit, settlement, and opportunity execution.
- `DoppiLiquidity`: `_getAccumulatedPrices` and `_getRemovingPrices` both traverse the linked list. `lowerBound`/`upperBound` state variables removed; `getLowerUpperBound()` derived from head/tail.
- `DoppiTraderAdminView`: `_calcPnL` traverses the linked list.

All hot paths are now **O(active strike count)**, not O(price range). Gas tests pass (4/4).

**Residual note**

The `_activateStrikeNode` insertion sort is O(active strike count) in the worst case. For typical live strike counts this is negligible, but worth monitoring if deposits become highly fragmented across many distinct strikes simultaneously.

---

### F-03 — Low
### Emergency LP exit is mitigated, but still depends on owner-coordinated emergency settlement

**Impacted areas**  
- [src/mainnet/DoppiLiquidityRouter.sol](src/mainnet/DoppiLiquidityRouter.sol#L53-L67)  
- [src/mainnet/DoppiLiquidityRouter.sol](src/mainnet/DoppiLiquidityRouter.sol#L92-L145)  
- [src/mainnet/DoppiCore.sol](src/mainnet/DoppiCore.sol#L211-L222)  
- [src/mainnet/DoppiCore.sol](src/mainnet/DoppiCore.sol#L296-L338)

**Updated assessment**

Your emergency flow materially improves this item.

In the current design, the owner can:

- pause the system
- enable emergency mode
- run emergency settlement to clear pending positions
- return principal while ignoring interest
- let LP users withdraw through the router once liabilities have been cleared down

That means the earlier version of F-03 should no longer be treated as a primary stuck-funds bug.

**Residual risk**

The remaining concern is operational rather than critical:

- LP exit still depends on a live DoppiCore liability read
- emergency recovery requires trusted owner action
- large backlogs may require repeated emergency settlement calls across batches and supported days before users can fully exit

**Impact**

- reduced severity versus the original report
- still a recovery-path dependency on admin coordination and a responsive core contract

**Recommendation**

I would keep this as a low-severity operational note and optionally harden it further with:

- a clear flag indicating all emergency settlements are complete
- a cached zero-liability checkpoint after emergency cleanup
- operational runbooks to ensure all supported days are fully processed before opening LP emergency withdrawals

---

### F-04 — Low
### Missing unwind bookkeeping on swap-assisted settlement paths can accumulate untracked inventory drift

**Impacted areas**  
- [src/mainnet/DoppiLiquidity.sol](src/mainnet/DoppiLiquidity.sol#L59-L80)  
- [src/mainnet/DoppiLiquidity.sol](src/mainnet/DoppiLiquidity.sol#L83-L104)

**Observation**

When the LP has enough of the payout asset, the settlement path updates unwind targets. But when the pool is short and must swap to source the payout, the unwind-target update is skipped.

A similar pattern appears in the interest payment helper, where cross-asset balancing happens without explicit unwind-target accounting.
**Design clarification (post-review)**

The protocol intentionally records unwind state only for swaps that occur **inside the `settle` function through the internal DEX**. Any swap executed outside the protocol's DEX is not tracked by design and is not expected to contribute to the unwind registry. The original concern about silent drift from external swap paths therefore does not apply.

**Residual concern**

Even within the internal `settle` path, the swap-assisted branch still skips the unwind-target update that the direct-transfer branch applies. If this branch is hit repeatedly, the unwind tracker may undercount internal inventory movement.
**Why this matters**

That means part of the protocol’s inventory drift can occur outside the normal unwind tracker. Over time, repeated usage of these branches can leave the LP with **real exposure changes that automation does not fully “see.”**

**Impact**

- limited to the internal swap branch of `settle`
- external swaps are intentionally out of scope
- residual drift from the internal branch is bounded by settlement frequency

**Recommendation**

Confirm that the internal swap branch of `settle` applies the same unwind-target update as the direct-transfer branch, or document the asymmetry explicitly.

---

### F-05 — Low ✅ Fixed
### Forwarder misconfiguration can halt automated settlement and bot execution

**Impacted areas**  
- [src/mainnet/DoppiCoreAdmin.sol](src/mainnet/DoppiCoreAdmin.sol#L55-L60)  
- [src/mainnet/DoppiTraderAdminView.sol](src/mainnet/DoppiTraderAdminView.sol#L93-L100)  
- compare with stricter validation in [src/mainnet/DoppiUpkeepManager.sol](src/mainnet/DoppiUpkeepManager.sol#L113-L116)

**Observation**

Some forwarder setters allow a zero address or do not enforce a strong configuration invariant.

Because settlement and trader automation depend on the correct forwarder, a bad configuration can pause automation for an extended period.

**Impact**

- expired positions may wait for manual settlement
- trader bots can stop executing their upkeep path
- operational recovery depends on trusted admin action

**Recommendation**

Reject zero addresses and emit stronger configuration events so broken automation is immediately visible.

**Fix applied**

- **`DoppiCoreAdmin.setForwarderAddress`** — now has `require(forwarderAddress != address(0), "zero forwarder")` and is `onlyOwner`. Zero-address misconfiguration by an admin call is no longer possible.
- **`DoppiUpkeepManager.setForwarderAddress`** — already had the zero-address guard (the positive reference cited in the original finding); confirmed unchanged.
- **`DoppiTraderAdminView.setForwarderAddress`** — accepts zero intentionally: `DoppiUpkeepManager.stopWithdraw` calls `IDoppiTrader(targetContract).setForwarderAddress(address(0))` to reset the forwarder on upkeep cancellation. Access is restricted to `_onlyUpkeepOrTrader()`, so an external actor cannot misuse this path. This is by design, not an oversight.

---

## Positive Controls Observed

The following controls were generally positive in this pass:

- broad use of reentrancy guards on fund-moving paths
- SafeERC20 wrappers for token transfers
- separate owner pause controls for core operational contracts
- manual settlement escape hatch in the core when automation is unavailable

These controls reduce the chance of a trivial exploit, but they do **not** eliminate the accounting and deadlock issues described above.

---

## Final Assessment

From a fresh mainnet-focused viewpoint, the protocol’s biggest risk is **not a simple public wallet-drain function**.

The bigger concern is a combination of:

- **partial-fill accounting mistakes**
- **automation dependence**
- **range-based gas growth**
- **inventory drift that is not fully tracked**

If left unresolved, these can translate into either:

1. **slow LP loss**, or  
2. **stuck user funds during volatile conditions or heavy throughput**.

---

## Priority Order

1. Fix partial-fill settlement accounting in DoppiCore  
2. Refactor bound scanning into populated-bucket iteration  
3. Decouple LP emergency exit logic from a hard DoppiCore dependency  
4. Track unwind exposure on all settlement and interest branches  
5. Harden forwarder configuration checks
