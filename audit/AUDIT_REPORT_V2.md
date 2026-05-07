# Doppi Protocol — Smart Contract Security Audit Report
## Follow-Up Review (v2)

---

| | |
|---|---|
| **Project** | Doppi Protocol |
| **Repository** | `doppi-smart-contracts` |
| **Scope** | `src/mainnet/**` · `src/Library/**` · `src/Interface/**` |
| **Solidity Versions** | `^0.8.26` (main), `^0.8.20` (ERC7575, Swapper) |
| **Original Audit Date** | April 5, 2026 |
| **Follow-Up Review Date** | April 11, 2026 |
| **Auditor** | Internal Security Review |
| **Status** | Draft — Pending Remediation of Remaining Findings |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Remediation Status of Previous Findings](#2-remediation-status-of-previous-findings)
3. [Notable Architectural Improvements](#3-notable-architectural-improvements)
4. [Remaining Open Findings](#4-remaining-open-findings)
5. [New Findings Introduced in This Revision](#5-new-findings-introduced-in-this-revision)
6. [Positive Security Observations](#6-positive-security-observations)
7. [Recommended Fix Summary](#7-recommended-fix-summary)

---

## 1. Executive Summary

This follow-up report reviews the Doppi Protocol smart contracts after a round of developer remediation based on the initial April 5, 2026 audit. Of the original **19 findings** (3 Critical, 5 High, 5 Medium, 6 Low), **11 have been fully resolved** and **2 have been partially addressed**. The most impactful structural change — the per-day scoping of the settlement loop (C-02) — represents a substantial architectural improvement that eliminates what was previously the most dangerous denial-of-service vector.

**4 findings of material significance remain unresolved**, including one Critical (C-03: blocking treasury push) and two High (H-02: stale settlement price; H-03: unbounded regression IV). Additionally, **1 partially applied fix** (M-01: interest precision) is currently disabled via a source comment and requires activation.

**Overall Risk Assessment: MEDIUM-HIGH**  
The protocol is significantly safer than at first review. It should not be deployed to mainnet until the 4 remaining High/Critical findings are resolved.

### Summary Scorecard

| Severity | Total | Fixed | Partially Addressed | Open |
|---|---|---|---|---|
| Critical | 3 | 2 | 0 | 1 |
| High | 5 | 2 | 1 | 2 |
| Medium | 5 | 3 | 1 | 1 |
| Low | 6 | 1 | 1 | 4 |
| **Total** | **19** | **8** | **3** | **8** |

---

## 2. Remediation Status of Previous Findings

| ID | Title | Severity | Status |
|---|---|---|---|
| C-01 | `forge-std/console.sol` active import in `DoppiUpkeepManager` | Critical | **Fixed** |
| C-02 | Settlement array overflow DoS with multiple support days | Critical | **Fixed** |
| C-03 | Treasury transfer failure permanently reverts all settlements | Critical | **Open** |
| H-01 | `aprToleranceBP` and `treasury_fee` have no upper-bound validation | High | **Fixed** |
| H-02 | Settlement price has no staleness check | High | **Open** |
| H-03 | Regression IV can produce negative or zero `markIV` | High | **Open** |
| H-04 | Silent TWAP fallback allows perpetual oracle degradation | High | **Partially Addressed** |
| H-05 | `_getTotalInterestLiabilities()` fails silently, understating liabilities | High | **Fixed** |
| M-01 | Interest calculation performs two sequential integer divisions | Medium | **Partially Addressed** |
| M-02 | Profit ratio truncation systematically shortchanges LP pool | Medium | **Partially Addressed** |
| M-03 | `MIN_BUFFER` / `MAX_BUFFER` ordering not enforced | Medium | **Fixed** |
| M-04 | `supportDays` array accepts duplicate entries | Medium | **Fixed** |
| M-05 | `getAllOffers()` uses external `this.` call pattern | Medium | **Fixed** |
| L-01 | Commented-out debug imports in production files | Low | **Fixed** |
| L-02 | Inconsistent Solidity pragma versions | Low | **Partially Addressed** |
| L-03 | SPDX license identifier inconsistency | Low | **Open** |
| L-04 | Hardcoded USDT address in `DALiquidityLib` | Low | **Open** |
| L-05 | Missing events for critical admin parameter changes | Low | **Open** |
| L-06 | `priceDecimal` cached at construction, never refreshed | Low | **Open** |
| I-01 | `DoppiTrader.initialize()` has redundant initialization guard | Info | **Open** |
| I-02 | Referral tree has no cycle detection | Info | **Acknowledged** |
| I-03 | `DoppiUpkeepManager` pragma inconsistency | Info | **Fixed** |

---

## 3. Notable Architectural Improvements

### 3.1 Per-Day Position Scoping (C-02 fix) — Major

The most significant change in this revision is the complete redesign of the settlement position lookup. The previous single global `nextPositionId` counter has been replaced with a per-day mapping:

```solidity
// DoppiCoreView.sol — new
mapping(uint8 => uint64) public nextPositionId;
```

`getReadyAllPositions` has been replaced with `_getReadyAllPositions(uint8 day)`, which accepts and scopes to a single support day. `checkUpkeep` now iterates over support days and returns immediately on the first day that has ready positions:

```solidity
for(uint8 x=0; x < supportDays.length; ) {
    uint8 day = supportDays[x];
    (uint64[] memory allPositions, SettleAccumulate memory settleAccu) = _getReadyAllPositions(day);
    if (allPositions.length > 0) {
        return (true, abi.encode(allPositions, settleAccu));
    }
    unchecked { ++x; }
}
```

This completely eliminates the array overflow risk described in C-02 and makes position settlement correctly composable across multiple term lengths. `addSupportDay` also now initialises `nextProcessId[_day]` and `nextPositionId[_day]` to 1 for each new day.

### 3.2 Emergency Settlement by Day

A new `emergencySettlement(uint8 day)` function (owner-only, `whenPaused`) was added, replacing the previous `emergencyWithdraw`. It correctly runs a bounded UPKEEPS_PER_CHECK loop per day and calls `_settleNoStrike` to return principal, which is superior to a simple withdrawal as it also handles any opportunity positions tied to the expiring strike.

### 3.3 Input Validation Added to Admin Setters (H-01 fix)

`setTreasury` now validates:
```solidity
require(_treasury != address(0), "zero treasury");
require(_treasury_fee <= 3000, "fee exceeds 30%");
```

`setAPRTolerance` now validates:
```solidity
require(_toleranceBP <= 1000, "exceeds 10%");
```

### 3.4 LP Liabilities Check Made Strict (H-05 fix)

`DoppiLiquidityRouter._getTotalInterestLiabilities()` now reverts on any failure rather than silently returning zero, preventing LPs from withdrawing when outstanding interest is owed:

```solidity
require(doppiCore != address(0), "doppiCore not set");
(bool success, bytes memory data) = doppiCore.staticcall(...);
require(success && data.length == 64, "liabilities call failed");
```

### 3.5 `getAllOffers` Internal Call Refactor (M-05 fix)

`DoppiOffer.getAllOffers` now calls internal `_getBuyOffers` / `_getSellOffers` helpers instead of `this.getBuyOffers` / `this.getSellOffers`, eliminating unnecessary external calls.

### 3.6 Buffer Ordering Enforcement (M-03 fix) and Duplicate Day Guard (M-04 fix)

Both are now correctly validated via `require` statements as recommended.

---

## 4. Remaining Open Findings

---

### C-03 — Treasury Push Transfer Blocks All Settlements [OPEN — CRITICAL]

**Contract:** `DoppiCore.sol` — `_safeTransferWithFee()`  
**Severity:** Critical  
**Original Finding:** C-03 in April 5 report

#### Current State

The `setTreasury` setter now correctly validates a non-zero treasury address and caps the fee at 30%. However, the transfer function itself is unchanged:

```solidity
// DoppiCore.sol line ~951
function _safeTransferWithFee(IERC20 _asset, address _to, uint256 _amount) internal {
    uint256 amountFee = _amount * treasury_fee / 10000;
    uint256 amountAfterFee = _amount - amountFee;
    _asset.safeTransfer(_to, amountAfterFee);
    _asset.safeTransfer(treasury, amountFee);   // still blocking
}
```

If the treasury address is a contract that conditionally reverts token transfers (e.g., a multisig paused for key rotation, a smart wallet with a deny list, or a protocol contract undergoing upgrade), the second `safeTransfer` will revert. Since `_safeTransferWithFee` is called on every settlement of every position, this reverts the entire Chainlink Automation upkeep, halting all protocol settlements.

The validation improvements to `setTreasury` reduce the likelihood of misconfiguration but do not eliminate the runtime failure mode. A valid non-zero address can still reject ERC20 transfers.

#### Recommended Fix

Accumulate fees internally and let the treasury pull them, decoupling settlement correctness from treasury availability:

```solidity
// Add state variable:
mapping(address => uint256) public accruedFees; // token => amount

function _safeTransferWithFee(IERC20 _asset, address _to, uint256 _amount) internal {
    uint256 amountFee = _amount * treasury_fee / 10000;
    uint256 amountAfterFee = _amount - amountFee;
    _asset.safeTransfer(_to, amountAfterFee);
    if (amountFee > 0) {
        accruedFees[address(_asset)] += amountFee;
    }
}

function claimFees(address _asset) external {
    require(msg.sender == treasury, "only treasury");
    uint256 amount = accruedFees[_asset];
    require(amount > 0, "nothing to claim");
    accruedFees[_asset] = 0;
    IERC20(_asset).safeTransfer(treasury, amount);
}
```

---

### H-02 — Settlement Uses Unvalidated Price From LP [OPEN — HIGH]

**Contract:** `DoppiCore.sol` — `_processNewSettlements()`  
**Severity:** High  
**Original Finding:** H-02 in April 5 report

#### Current State

No changes have been made:

```solidity
function _processNewSettlements(uint64[] memory allPositions, SettleAccumulate memory settleAccu) internal {
    uint256 price = _getPriceFromLP();   // no staleness validation
    _batchProcess(allPositions, settleAccu, price);
    _settle_positions(allPositions, price);
    _updateBound();
}
```

`_getPriceFromLP` makes a low-level call to `doppiLP.getPrice()`. While `DoppiLiquidity.getPrice()` internally reads from the oracle with staleness checks via `DALiquidityLib`, `DoppiCore` has no independent guard. If the LP contract is paused, in an error state, or returns a cached/zero price, settlement proceeds at the wrong price.

#### Recommended Fix

```solidity
function _processNewSettlements(...) internal {
    uint256 price = _getPriceFromLP();
    require(price > 0, "invalid settlement price");
    // Optionally: also validate priceUpdatedAt freshness if LP exposes it
    ...
}
```

At minimum, a `require(price > 0)` guard prevents settlement at a zero price, which would result in division-by-zero panics or extreme payout miscalculations.

---

### H-03 — Regression IV Can Wrap to Extremely Large `uint256` [OPEN — HIGH]

**Contract:** `DoppiOffer.sol` — `_getImpliedVol()`  
**Severity:** High  
**Original Finding:** H-03 in April 5 report

#### Current State

No changes have been made to either `setRegression` (no bounds validation) or `_getImpliedVol` (no sign check before casting):

```solidity
function _getImpliedVol(...) internal view returns (uint256 markIV, uint256 lastUpdated) {
    int256 price = int256(_price);
    RegressionVar memory regr = _isBuy ? buyRegression[...] : sellRegression[...];
    // If the expression evaluates to a negative int256, casting to uint256 silently wraps
    markIV = uint256(
        (((((regr.a * price) / priceDecimal) * price) / priceDecimal)
        + ((regr.b * price) / priceDecimal)
        + regr.c)
    ) / 1e11;
    lastUpdated = regr.lastUpdated;
}
```

A negative polynomial evaluation (common when `b` is large negative and `c` is small) produces a two's-complement wrap to a very large `uint256`, which then propagates into the Black-Scholes pricer producing garbage APR values. Conversely, incorrectly calibrated coefficients can produce `markIV = 0`, which causes `getBuyAPR` / `getSellAPR` to return `(0, 0)`, resulting in zero APR being offered on all positions.

#### Recommended Fix

Add a sign check before the cast:

```solidity
function _getImpliedVol(...) internal view returns (uint256 markIV, uint256 lastUpdated) {
    int256 price = int256(_price);
    RegressionVar memory regr = _isBuy ? buyRegression[_daysInTimestamp] : sellRegression[_daysInTimestamp];
    int256 rawIV = (((((regr.a * price) / priceDecimal) * price) / priceDecimal)
                  + ((regr.b * price) / priceDecimal)
                  + regr.c);
    if (rawIV <= 0) return (0, regr.lastUpdated);  // callers already handle zero IV
    markIV = uint256(rawIV) / 1e11;
    lastUpdated = regr.lastUpdated;
}
```

---

### M-01 — Interest Precision Fix Applied but Disabled [OPEN — MEDIUM]

**Contract:** `DoppiCore.sol` — `_depositBuy()`, `_depositSell()`  
**Severity:** Medium  
**Original Finding:** M-01 in April 5 report

#### Current State

The recommended single-multiplication fix has been written but is currently commented out. The old two-division path is still active:

```solidity
// _depositBuy and _depositSell, lines ~358-360 and ~394-396:
uint256 interest = (amount * _buyOffer.apr) / BASIS_POINTS;      // active — division 1
interest = (interest * duration) / SECONDS_PER_YEAR;              // active — division 2
// uint256 interest = (amount * _buyOffer.apr * duration) / (BASIS_POINTS * SECONDS_PER_YEAR);  // inactive fix
```

The commented-out formula is exactly correct. It must be **activated** (uncomment the fix, delete the two-line version) to take effect.

#### Recommended Action

Uncomment the single-expression formula and remove the two-step version in both `_depositBuy` and `_depositSell`.

---

### M-02 — Profit Ratio Arithmetic Still Susceptible to Truncation [OPEN — MEDIUM]

**Contract:** `DoppiCore.sol` — `_settleStrike()`, `_settleNoStrike()`  
**Severity:** Medium (downgraded from original due to partial improvement)  
**Original Finding:** M-02 in April 5 report

#### Current State

The intermediate `1e18` scaling ratio has been removed, which is an improvement. The expression is now:

```solidity
// _settleStrike, line ~514
uint256 myamountOut = order.outAmount * p.amount / swappedAmount;

// _settleNoStrike, line ~540
uint256 amountOut = order.outAmount * p.amount / swappedAmount;
```

This is better than the previous chained multiplication-then-division approach. However, simple `a * b / c` integer arithmetic in Solidity still truncates toward zero. For large values (e.g., `order.outAmount` near `uint256` max), this could also overflow before division.

#### Recommended Fix

Use `Math.mulDiv` (already imported in `DoppiLiquidity.sol` via OpenZeppelin) which performs overflow-safe 512-bit multiplication prior to division:

```solidity
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// In _settleStrike and _settleNoStrike:
uint256 myamountOut = Math.mulDiv(order.outAmount, p.amount, swappedAmount);
```

---

### L-02 — Pragma Version Inconsistency Remains for `ERC7575` and `Swapper` [OPEN — LOW]

**Severity:** Low  
**Original Finding:** L-02 in April 5 report (partially addressed)

#### Current State

All mainnet contracts have been standardised to `^0.8.26`. However, two files remain at `^0.8.20`:

| File | Pragma |
|---|---|
| `src/mainnet/ERC7575.sol` | `^0.8.20` |
| `src/mainnet/Swapper.sol` | `^0.8.20` |

`Swapper.sol` is a test-only helper and likely intentional. `ERC7575.sol`, however, is a production contract used by `DoppiLiquidityRouter` in the LP deposit and redemption flow. It should be standardised to `^0.8.26`.

---

### L-03 — SPDX License Identifier Inconsistency [OPEN — LOW]

**Severity:** Low

Four production contracts still declare `SPDX-License-Identifier: UNLICENSED` while the majority of the protocol declares `MIT`:

| File | License |
|---|---|
| `DoppiLiquidity.sol` | `UNLICENSED` |
| `DoppiLiquidityRouter.sol` | `UNLICENSED` |
| `DoppiTrader.sol` | `UNLICENSED` |
| `DoppiTraderFactory.sol` | `UNLICENSED` |

This creates legal ambiguity for integrators and auditors. Decide on a consistent license and apply it uniformly.

---

### L-04 — Hardcoded USDT Address in `DALiquidityLib` [OPEN — LOW]

**Contract:** `DALiquidityLib.sol` — `getPancakePrice()`

```solidity
address usdt = address(0x55d398326f99059fF775485246999027B3197955);
```

This BSC mainnet USDT address is hardcoded inside library logic, making the library non-portable. If deployed to another chain, this address is either invalid or a different token.

---

### L-05 — Missing Events for Critical Admin Parameter Changes [OPEN — LOW]

No events are emitted for the following security-critical configuration changes:

| Function | Contract | Missing Event |
|---|---|---|
| `setTreasury(address, uint24)` | `DoppiCoreAdmin` | `TreasuryUpdated(address indexed, uint24)` |
| `setForwarderAddress(address)` | `DoppiCoreAdmin` | `ForwarderUpdated(address indexed)` |
| `setOpportunityBot(address, bool)` | `DoppiCoreAdmin` | `OpportunityBotUpdated(address indexed, bool)` |
| `setRegression(...)` | `DoppiOffer` | `RegressionUpdated(uint256 indexed daysInTimestamp)` |
| `setAPRTolerance(uint16)` | `DoppiCoreAdmin` | `APRToleranceUpdated(uint16)` |

Without events, off-chain monitoring systems cannot detect parameter changes, making it impossible to alert on misconfiguration or privilege abuse in real time.

---

### L-06 — `priceDecimal` Cached at Construction, No Refresh Path [OPEN — LOW]

**Contract:** `DoppiCore.sol`

```solidity
constructor(...) {
    priceDecimal = 10 ** _doppiLP.getPriceDecimals();  // set once, never updated
}
```

If the oracle feed on `DoppiLiquidity` is ever replaced with one that reports a different decimal precision, all price arithmetic in `DoppiCore` (deposit payout computation, settlement P&L, interest, etc.) will silently use the wrong scale factor.

**Recommendation:** Add `refreshPriceDecimal()` callable by the owner:

```solidity
function refreshPriceDecimal() external onlyOwner {
    priceDecimal = 10 ** doppiLP.getPriceDecimals();
}
```

---

### I-01 — `DoppiTrader.initialize()` Has Redundant Initialization Guard [OPEN — INFORMATIONAL]

**Contract:** `DoppiTrader.sol`

```solidity
bool private initialized;   // manual guard

function initialize(...) external initializer {  // OZ guard
    if (initialized) revert AlreadyInitialized(); // redundant
    initialized = true;
    ...
}
```

OpenZeppelin's `initializer` modifier already prevents re-initialisation via its own internal storage slot (`_initialized`). The manual `initialized` flag wastes one storage slot and adds code complexity without adding any protection.

---

## 5. New Findings Introduced in This Revision

### N-01 — `treasury_fee` Cap of 30% Is Disproportionately Permissive [NEW — MEDIUM]

**Contract:** `DoppiCoreAdmin.sol`  
**Severity:** Medium

The fee cap introduced to fix H-01 is set to 3000 basis points (30%):

```solidity
require(_treasury_fee <= 3000, "fee exceeds 30%");
```

At 30%, a malicious or compromised owner can silently extract 30% of every settlement and every interest payment. Benchmark comparison:

| Protocol | Max Protocol Fee |
|---|---|
| Uniswap V3 | 10–25% of swap fees |
| Aave | ~9% of interest |
| Typical DeFi | ≤10% on yield |

For a protocol handling fixed-term principal-protected positions, a 30% fee cap on settlement payouts is disproportionate. If a user deposits 100 USDT and receives only 70 USDT on no-strike settlement because treasury_fee was set to 3000, they face material principal loss, which contradicts the protocol's principal-protection guarantee.

**Recommendation:** Lower the cap to 1000 (10%) which aligns with the original recommendation and is defensible across all settlement scenarios.

---

### N-02 — `emergencySettlement` Does Not Emit `EmergencyWithdraw` for All Positions [NEW — LOW]

**Contract:** `DoppiCore.sol` — `_emergencySettlement()`  
**Severity:** Low

The new `_emergencySettlement` loop calls `_settleNoStrike` and emits `EmergencyWithdraw`, but only if `pos.amount > 0`:

```solidity
if (pos.amount > 0) {
    ...
    emit EmergencyWithdraw(isBuy, pos.owner, i, amountToReturn);
}
```

However, the existence check `_posExist(day, i)` already guarantees a non-zero amount before this block is reached. The inner `if (pos.amount > 0)` is therefore always true but harmless. More importantly, `_settleNoStrike` itself may transfer principal back to the user without emitting a separate `Settled` event (since the settlement emitter is in `_settlePosition`, which is not called here). Only `EmergencyWithdraw` is emitted — this is sufficient but is worth noting for off-chain indexers that track settlement events.

---

## 6. Positive Security Observations

The following were confirmed correct and unchanged from the first review:

| Pattern | Confirmation |
|---|---|
| `ReentrancyGuard` on all state-modifying external functions | Confirmed |
| `SafeERC20` for all token operations | Confirmed |
| `Pausable` + `emergencyMode` circuit breakers | Confirmed — improved with per-day `emergencySettlement` |
| `immutable` asset addresses | Confirmed |
| Chainlink `answeredInRound < roundId` validation | Confirmed |
| `try/catch` on trader-bot unwind to prevent cascade failures | Confirmed |
| Interest liability tracked with underflow protection | Confirmed |
| Custom error types for gas efficiency | Confirmed |
| `addSupportDay` now initialises per-day position counters | New — correct |
| `setBuffer` now enforces `min < max` | New — correct |
| `_getTotalInterestLiabilities` now reverts instead of returning zero | New — correct |
| `getAllOffers` uses internal calls | New — correct |

---

## 7. Recommended Fix Summary

Fixes are ordered by expected implementation effort (ascending) within each priority tier.

### Tier 1 — Must Fix Before Mainnet Deployment

| ID | Action | Effort |
|---|---|---|
| **M-01** | Uncomment the single-expression interest formula in `_depositBuy` and `_depositSell`; delete the two-line version | Minutes |
| **H-02** | Add `require(price > 0, "invalid settlement price")` in `_processNewSettlements` | Minutes |
| **N-01** | Lower `treasury_fee` cap from 3000 to 1000 in `setTreasury` | Minutes |
| **H-03** | Add sign check before `uint256()` cast in `_getImpliedVol`; return `(0, lastUpdated)` on non-positive result | 30 min |
| **M-02** | Replace `order.outAmount * p.amount / swappedAmount` with `Math.mulDiv(...)` in both settlement helpers | 30 min |
| **C-03** | Replace push-to-treasury with internal fee accrual mapping + pull `claimFees()` function | 2–4 hours |

### Tier 2 — Strongly Recommended Before Deployment

| ID | Action |
|---|---|
| **L-05** | Add events to `setTreasury`, `setForwarderAddress`, `setOpportunityBot`, `setRegression`, `setAPRTolerance` |
| **L-06** | Add `refreshPriceDecimal()` owner function |
| **L-02** | Update `ERC7575.sol` pragma to `^0.8.26` |
| **H-04** | Expose a `usingTWAPFallback` flag that monitoring systems can detect |

### Tier 3 — Nice to Have

| ID | Action |
|---|---|
| **L-03** | Standardise all SPDX identifiers to `MIT` or `UNLICENSED` |
| **L-04** | Pass USDT address as a constructor parameter in `DALiquidityLib` or the calling contract |
| **I-01** | Remove redundant `initialized` flag from `DoppiTrader` |

---

*This follow-up report documents the state of the codebase as of April 11, 2026 and supersedes the April 5, 2026 initial report. Findings not listed as Fixed remain the responsibility of the development team to address. A formal third-party audit is strongly recommended before mainnet deployment.*
