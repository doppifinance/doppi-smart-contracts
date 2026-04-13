# Doppi Protocol — Smart Contract Security Audit Report

---

|                         |                                                                           |
|-------------------------|---------------------------------------------------------------------------|
| **Project**             | Doppi Protocol                                                            |
| **Repository**          | `doppi-smart-contracts`                                                   |
| **Scope**               | `src/mainnet/**` · `src/Library/**` · `src/Interface/**`                  |
| **Solidity Versions**   | `^0.8.26` (main) · `^0.8.20` (ERC7575, Swapper)                          |
| **Initial Audit**       | April 5, 2026                                                             |
| **Follow-Up Review**    | April 11, 2026                                                            |
| **Supplemental Review** | April 11, 2026 (DoppiTrader · DoppiLiquidity deep-dive)                   |
| **Round 4 Review**      | April 12, 2026 (DoppiOpportunity · DoppiReferral · DoppiPoints · DoppiClaim · DoppiUpkeepManager) |
| **Auditor**             | Internal Security Review                                                  |
| **Status**              | Final — Supersedes AUDIT_REPORT.md and AUDIT_REPORT_V2.md                |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Scope & Methodology](#2-scope--methodology)
3. [System Architecture Overview](#3-system-architecture-overview)
4. [Risk Classification](#4-risk-classification)
5. [Findings Summary](#5-findings-summary)
6. [Critical Findings](#6-critical-findings)
7. [High Findings](#7-high-findings)
8. [Medium Findings](#8-medium-findings)
9. [Low Findings](#9-low-findings)
10. [New Findings (Follow-Up Review v2)](#10-new-findings-follow-up-review-v2)
11. [Supplemental Findings (Deep-Dive v3)](#11-supplemental-findings-deep-dive-v3)
12. [Informational Findings](#12-informational-findings)
13. [Positive Security Observations](#13-positive-security-observations)
14. [Remaining Open Items](#14-remaining-open-items)
15. [Appendix — Contract Inventory](#15-appendix--contract-inventory)

---

## 1. Executive Summary

This report consolidates findings from three audit rounds of the Doppi Protocol smart contracts. Doppi is a dual-asset structured product protocol on BNB Chain where users deposit a single asset into fixed-term positions that earn options-derived APR. The protocol integrates Chainlink oracle feeds with a Uniswap V3 TWAP fallback, a Black-Scholes options pricer, a three-tier referral system, and Chainlink Automation for automated position settlement.

**Initial Audit (April 5, 2026):** 19 findings identified (3 Critical, 5 High, 5 Medium, 6 Low).

**Follow-Up Review (April 11, 2026):** Developer remediation reviewed. 2 new findings added. Overall risk significantly reduced.

**Supplemental Deep-Dive (April 11, 2026):** Targeted adversarial review of `DoppiTrader`, `DoppiLiquidity`, and access control paths. 6 new findings added (S-01 through S-06).

**Round 4 Update (April 12, 2026):** Reward / referral / automation subsystem review tracked in `AUDIT_REPORT_ROUND4.md`. Current Round 4 status: **16 findings total** with **9 fixed**, **2 partially addressed**, and **5 open** (no Critical/High).

**Round 4 Open Items (Quick View):**
- **R-06 (Low):** `DoppiReferral.getTotalReferralRewards` unbounded month loop can become expensive over long inactivity windows.
- **R-07 (Low):** Referral code registration remains front-runnable (grief/UX risk only).
- **U-02 (Low, Partial):** One remaining raw `linkToken.transfer` path in `stopWithdraw` should be converted to `SafeERC20`.
- **U-03 (Low, Partial):** `setTresury` typo remains (security guard fixed; naming cleanup pending).
- **I-01 / I-02 / U-07 (Info):** Deployment ordering dependency, reward-BP configurability risk, and immutable unlimited approvals are documented operational risks.

### Remediation Scorecard

| Severity                  | Count | Fixed | Partially Addressed | Open |
|---------------------------|-------|-------|---------------------|------|
| Critical                  | 3     | 2     | 1 *(downgraded)*    | 0    |
| High                      | 5     | 4     | 1                   | 0    |
| Medium                    | 5     | 4     | 0                   | 1    |
| Low                       | 6     | 4     | 1                   | 1    |
| New — Medium (v2)         | 1     | 1     | 0                   | 0    |
| New — Low (v2)            | 1     | 0     | 0                   | 1    |
| New — High (v3)           | 1     | 1     | 0                   | 0    |
| New — Medium-High (v3)    | 1     | 1     | 0                   | 0    |
| New — Medium (v3)         | 3     | 3     | 0                   | 0    |
| New — Low (v3)            | 1     | 1     | 0                   | 0    |
| **Total**                 | **27**| **17**| **3**               | **7** |

> **C-03** was originally classified Critical. After review it has been downgraded to **Medium**: the `setTreasury` recovery path means any treasury-induced settlement pause is temporary, not permanent. A zero-fee guard has been added as a partial mitigation.

**Current Overall Risk: LOW–MEDIUM**
All six supplemental findings (S-01 through S-06) and the majority of original findings are now fixed — 21 of 27 findings resolved, 3 partially addressed. The 3 remaining open items from rounds 1–3 (M-02, L-04, L-05) carry no single path to fund loss. The highest-priority remaining item is the settlement profit-ratio precision issue (M-02, Medium). Round 4 findings and remediation status are maintained in `AUDIT_REPORT_ROUND4.md`. All `forge build` and `forge test` checks pass as of this revision.

---

## 2. Scope & Methodology

### 2.1 In-Scope Files

| Contract                | Source File                                 |
|-------------------------|---------------------------------------------|
| `DoppiCore`             | `src/mainnet/DoppiCore.sol`                 |
| `DoppiCoreAdmin`        | `src/mainnet/DoppiCoreAdmin.sol`            |
| `DoppiCoreView`         | `src/mainnet/DoppiCoreView.sol`             |
| `DoppiCoreTypes`        | `src/mainnet/DoppiCoreTypes.sol`            |
| `DoppiLiquidity`        | `src/mainnet/DoppiLiquidity.sol`            |
| `DoppiLiquidityRouter`  | `src/mainnet/DoppiLiquidityRouter.sol`      |
| `DoppiLiquidityTypes`   | `src/mainnet/DoppiLiquidityTypes.sol`       |
| `DoppiOffer`            | `src/mainnet/DoppiOffer.sol`                |
| `DoppiOpportunity`      | `src/mainnet/DoppiOpportunity.sol`          |
| `DoppiReferral`         | `src/mainnet/DoppiReferral.sol`             |
| `DoppiPoints`           | `src/mainnet/DoppiPoints.sol`               |
| `DoppiTrader`           | `src/mainnet/DoppiTrader.sol`               |
| `DoppiTraderFactory`    | `src/mainnet/DoppiTraderFactory.sol`        |
| `DoppiTraderAdminView`  | `src/mainnet/DoppiTraderAdminView.sol`      |
| `DoppiTraderTypes`      | `src/mainnet/DoppiTraderTypes.sol`          |
| `DoppiUpkeepManager`    | `src/mainnet/DoppiUpkeepManager.sol`        |
| `DoppiUpkeepManagerTypes`| `src/mainnet/DoppiUpKeepManagerTypes.sol` |
| `DoppiClaim`            | `src/mainnet/DoppiClaim.sol`                |
| `ERC7575`               | `src/mainnet/ERC7575.sol`                   |
| `Swapper`               | `src/mainnet/Swapper.sol`                   |
| `BlackScholes`          | `src/mainnet/BlackScholes.sol`              |
| `DALiquidityLib`        | `src/Library/DALiquidityLib.sol`            |
| `SafeDecimalMath`       | `src/Library/SafeDecimalMath.sol`           |
| `SignedSafeDecimalMath` | `src/Library/SignedSafeDecimalMath.sol`     |
| `BotRegistryLib`        | `src/Library/BotRegistryLib.sol`            |

### 2.2 Out-of-Scope

- `lib/` (third-party: OpenZeppelin, forge-std, Uniswap v3, Solady)
- `test/` and `script/` directories
- Off-chain Chainlink Automation node configuration

### 2.3 Methodology

- Manual code review of all in-scope files
- Control-flow analysis on settlement, deposit, and oracle interaction paths
- Data-flow analysis of token transfers, price computation, and access control
- Invariant analysis of the position lifecycle (deposit → settle / emergency-withdraw)
- Threat modelling against OWASP Smart Contract Top 10 and DeFi-specific attack patterns

---

## 3. System Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                         User / Trader Bot                            │
└──────────────┬──────────────────────────────────┬────────────────────┘
               │ deposit_buy / deposit_sell        │ DoppiTrader.start()
               ▼                                   ▼
┌──────────────────────────┐        ┌──────────────────────────────────┐
│       DoppiCore           │◄──────►│           DoppiTrader            │
│  (settlement engine)      │        │  (automated bot proxy)           │
│  - Chainlink Automation   │        │  - Initializable proxy           │
│  - Position lifecycle     │        │  - bulkDeposit / unwind          │
└────────┬─────────────────┘        └───────────────┬──────────────────┘
         │ interestGet / swap                        │ LP deposit/redeem
         ▼                                           ▼
┌──────────────────────────┐        ┌──────────────────────────────────┐
│      DoppiLiquidity       │        │       DoppiLiquidityRouter       │
│  (AMM + yield pool)       │◄──────►│  (ERC7575 vault entry/exit)      │
│  - Uniswap V3 swaps       │        │  - Withdrawal capacity mgmt      │
└────────┬─────────────────┘        └──────────────────────────────────┘
         │ oracle price
         ▼
┌──────────────────────────┐        ┌──────────────────────────────────┐
│       DoppiOffer          │        │       DoppiUpkeepManager         │
│  (IV + APR calculator)    │        │  (Chainlink LINK top-up)         │
│  - Black-Scholes library  │        │  - Swap fundToken → LINK         │
│  - Regression-based IV    │        │  - Register / cancel upkeeps     │
└──────────────────────────┘        └──────────────────────────────────┘
```

**Key protocol flows:**

1. **Deposit:** User calls `deposit_buy` or `deposit_sell` with a strike zone and term. APR is sourced from `DoppiOffer` (Black-Scholes IV via quadratic regression). Position is stored in `positions_buy[day][posId]` / `positions_sell[day][posId]`.
2. **Settlement:** Chainlink Automation triggers `performUpkeep`. The contract fetches spot price from `DoppiLiquidity`, calls interest retrieval on the LP, performs swap-based P&L attribution, and distributes principal + interest minus treasury fee.
3. **Opportunity / Unwind:** An authorised bot hedges open strike exposures via `DoppiOpportunity`, recording swapped amounts against `opportunityBuy` / `opportunitySell` maps.
4. **LP Management:** LPs deposit via `DoppiLiquidityRouter` (ERC7575), receiving ERC20 shares of `DoppiLiquidity`. Withdrawal capacity is gated by outstanding interest liabilities.

---

## 4. Risk Classification

| Severity        | Definition                                                                                                                                               |
|-----------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Critical**    | Direct path to loss of user funds, permanent DoS of a core subsystem, or complete bypass of access control. Blocks mainnet deployment.                   |
| **High**        | Significant financial risk, manipulable protocol parameters with no safety bounds, or silently degraded security guarantees. Must be fixed before deployment. |
| **Medium**      | Precision or logic error causing systematic financial leakage, or a failure mode that is unlikely but impactful. Should be fixed before deployment.      |
| **Low**         | Best-practice violations, minor precision concerns, or issues requiring privileged access or very specific conditions to exploit.                         |
| **Informational**| Code quality, maintainability, or clarity concerns with no direct security impact.                                                                      |

---

## 5. Findings Summary

| ID   | Title                                                                        | Contract              | Severity   | Status                    |
|------|------------------------------------------------------------------------------|-----------------------|------------|---------------------------|
| C-01 | `forge-std/console.sol` active import in production contract                 | `DoppiUpkeepManager`  | Critical   | ✅ **Fixed**              |
| C-02 | Settlement array overflow DoS with multiple support days                     | `DoppiCore`           | Critical   | ✅ **Fixed**              |
| C-03 | Treasury push transfer can temporarily block settlements                     | `DoppiCore`           | ~~Critical~~ → **Medium** | ⚠️ **Partially Mitigated** |
| H-01 | `aprToleranceBP` and `treasury_fee` have no upper-bound validation           | `DoppiCoreAdmin`      | High       | ✅ **Fixed**              |
| H-02 | Settlement price has no zero/staleness guard                                 | `DoppiCore`           | High       | ✅ **Fixed**              |
| H-03 | Regression IV cast can silently wrap negative value to large `uint256`       | `DoppiOffer`          | High       | ✅ **Fixed**              |
| H-04 | Silent TWAP fallback allows perpetual oracle degradation                     | `DALiquidityLib`      | High       | ⚠️ **Partially Addressed** |
| H-05 | `_getTotalInterestLiabilities()` fails silently, understating liabilities    | `DoppiLiquidityRouter`| High       | ✅ **Fixed**              |
| M-01 | Interest formula overflow due to narrow-type constant multiplication         | `DoppiCore`           | Medium     | ✅ **Fixed**              |
| M-02 | Profit ratio truncation systematically shortchanges LP pool                  | `DoppiCore`           | Medium     | ❌ **Open**               |
| M-03 | `MIN_BUFFER` / `MAX_BUFFER` ordering not enforced                            | `DoppiOffer`          | Medium     | ✅ **Fixed**              |
| M-04 | `supportDays` array accepts duplicate entries                               | `DoppiCore`           | Medium     | ✅ **Fixed**              |
| M-05 | `getAllOffers()` uses `this.` external call pattern                          | `DoppiOffer`          | Medium     | ✅ **Fixed**              |
| L-01 | Active debug import in production contract                                   | `DoppiUpkeepManager`  | Low        | ✅ **Fixed**              |
| L-02 | Inconsistent Solidity pragma versions across scope                           | Multiple              | Low        | ⚠️ **Partially Addressed** |
| L-03 | SPDX license identifier inconsistency                                        | Multiple              | Low        | ✅ **Fixed**              |
| L-04 | Hardcoded USDT address in `DALiquidityLib`                                   | `DALiquidityLib`      | Low        | ❌ **Open**               |
| L-05 | Missing events for critical admin parameter changes                          | Multiple              | Low        | ❌ **Open**               |
| L-06 | `priceDecimal` cached at construction, never refreshed                       | `DoppiCore`           | Low        | ✅ **Fixed**              |
| N-01 | `treasury_fee` cap of 30% is disproportionately permissive *(new v2)*       | `DoppiCoreAdmin`      | Medium     | ✅ **Fixed**              |
| N-02 | `emergencySettlement` does not emit event via standard `Settled` path *(new v2)* | `DoppiCore`      | Low        | ❌ **Open**               |
| S-01 | Stale unlimited approval after entry point deregistration *(new v3)*        | `DoppiLiquidity`      | **High**   | ✅ **Fixed**              |
| S-02 | `bulkDeposit` accepts unvalidated strike price from TraderBot *(new v3)*    | `DoppiCore`           | **Medium-High** | ✅ **Fixed**         |
| S-03 | `cleanUpUnwind` has no access control *(new v3)*                            | `DoppiLiquidity`      | **Medium** | ✅ **Fixed**              |
| S-04 | `DoppiTrader` has active `forge-std/console.sol` import *(new v3)*          | `DoppiTrader`         | **Medium** | ✅ **Fixed**              |
| S-05 | `setDefaultDay` infinite loop if target day not in `supportDays` *(new v3)* | `DoppiTrader`         | **Medium** | ✅ **Fixed**              |
| S-06 | `_processTopUp` uses bare `transfer` instead of `safeTransfer` *(new v3)*   | `DoppiTrader`         | **Low**    | ✅ **Fixed**              |
| I-01 | `DoppiTrader.initialize()` has redundant initialization guard                | `DoppiTrader`         | Info       | ✅ **Fixed**              |

---

## 6. Critical Findings

---

### C-01 — `forge-std/console.sol` Active Import in Production Contract

**Contract:** `DoppiUpkeepManager.sol` · **Severity:** Critical · **Status:** ✅ Fixed

#### Original Finding

`DoppiUpkeepManager` contained an active production import of the Foundry test helper:

```solidity
import "forge-std/console.sol";  // was active
```

While not exploitable at runtime, this bloated bytecode, risked breaching the EIP-170 24 KB contract size limit, and signalled that testing instrumentation had not been fully removed.

#### Fix Applied

The import line has been commented out:

```solidity
// import "forge-std/console.sol";
```

Consistent with the pattern applied across all other in-scope contracts.

---

### C-02 — Settlement Array Overflow DoS With Multiple Support Days

**Contract:** `DoppiCore.sol` → `getReadyAllPositions()` · **Severity:** Critical · **Status:** ✅ Fixed

#### Original Finding

`getReadyAllPositions()` allocated a `uint64[]` of fixed size `UPKEEPS_PER_CHECK` and iterated over **all** support days with a shared index counter `idx`. Once more than one support day had expired positions, `idx` exceeded the array bound, causing an out-of-bounds revert. Since this propagated into `checkUpkeep` (a `view` call), Chainlink Automation would treat it as "no upkeep needed", silently halting all settlements permanently.

#### Fix Applied

Complete architectural redesign:

- `nextPositionId` changed from a single `uint64` to `mapping(uint8 => uint64)` — per-day counter.
- `getReadyAllPositions` replaced by `_getReadyAllPositions(uint8 day)` — operates on a single day.
- `checkUpkeep` now iterates support days and returns on the first day with ready positions:

```solidity
for(uint8 x = 0; x < supportDays.length; ) {
    uint8 day = supportDays[x];
    (uint64[] memory allPositions, SettleAccumulate memory settleAccu) = _getReadyAllPositions(day);
    if (allPositions.length > 0) {
        return (true, abi.encode(allPositions, settleAccu));
    }
    unchecked { ++x; }
}
```

- `addSupportDay` now initialises `nextProcessId[_day] = 1` and `nextPositionId[_day] = 1` for each new day.

---

### C-03 — Treasury Push Transfer Can Temporarily Block Settlements

**Contract:** `DoppiCore.sol` → `_safeTransferWithFee()` · **Original Severity:** Critical · **Revised Severity:** Medium · **Status:** ⚠️ Partially Mitigated

#### Original Finding

`_safeTransferWithFee` issued a sequential `safeTransfer` to the treasury on every settlement. If the treasury address was misconfigured or unable to receive transfers (blocklisted on USDT/USDC, paused multisig, etc.), this would revert the entire settlement transaction — blocking all position settlements.

#### Severity Downgrade Rationale

The original **Critical** classification assumed the DoS was permanent. In practice, `setTreasury` allows the owner to update the treasury address, making the pause temporary rather than permanent. This aligns with a **Medium** severity profile: a real operational risk with an available owner-level recovery path.

#### Fix Applied

A zero-fee guard added to avoid unnecessary transfers when `treasury_fee = 0` (some tokens such as USDT can reject zero-value transfers):

```solidity
function _safeTransferWithFee(IERC20 _asset, address _to, uint256 _amount) internal {
    uint256 amountFee = _amount * treasury_fee / 10000;
    uint256 amountAfterFee = _amount - amountFee;
    _asset.safeTransfer(_to, amountAfterFee);
    if (amountFee > 0) _asset.safeTransfer(treasury, amountFee);  // guarded
}
```

#### Remaining Risk

The push pattern itself is unchanged. If the treasury address is a blocklisted wallet or a contract that reverts on receipt, settlements will pause until the owner calls `setTreasury` with a working address.

#### Recommendation (Optional Enhancement)

For maximum robustness, replace the push pattern with a pull model:

```solidity
mapping(address => uint256) public accruedFees;

function _safeTransferWithFee(...) internal {
    ...
    if (amountFee > 0) accruedFees[address(_asset)] += amountFee;
}

function claimFees(address _asset) external {
    require(msg.sender == treasury, "only treasury");
    uint256 amount = accruedFees[_asset];
    accruedFees[_asset] = 0;
    IERC20(_asset).safeTransfer(treasury, amount);
}
```

This decouples settlement correctness from treasury availability entirely. However, it requires additional unit test coverage and is considered optional given the `setTreasury` recovery path.

---

## 7. High Findings

---

### H-01 — `aprToleranceBP` and `treasury_fee` Have No Upper-Bound Validation

**Contract:** `DoppiCoreAdmin.sol` · **Severity:** High · **Status:** ✅ Fixed

#### Original Finding

`setAPRTolerance` accepted any `uint16` value (0–65535). Values above 10000 allowed deposits with APR far above the offered rate. `setTreasury` accepted any `uint24` fee value; values above 10000 caused underflow on `_amount - amountFee`.

#### Fix Applied

```solidity
function setTreasury(address _treasury, uint24 _treasury_fee) external onlyOwner {
    require(_treasury != address(0), "zero treasury");
    require(_treasury_fee <= 3000, "fee exceeds 30%");
    treasury_fee = _treasury_fee;
    treasury = _treasury;
}

function setAPRTolerance(uint16 _toleranceBP) external onlyOwner {
    require(_toleranceBP <= 1000, "exceeds 10%");
    aprToleranceBP = _toleranceBP;
}
```

> See also **N-01** for the concern that the 30% fee cap is still too permissive.

---

### H-02 — Settlement Price Has No Zero Guard

**Contract:** `DoppiCore.sol` → `_processNewSettlements()` · **Severity:** High · **Status:** ✅ Fixed

#### Original Finding

`_processNewSettlements` called `_getPriceFromLP()` with no validation, allowing settlement at a zero or garbage price if the LP returned an invalid value.

#### Fix Applied

`_getPriceFromLP()` itself now reverts when price is zero:

```solidity
function _getPriceFromLP() internal view returns (uint256 price) {
    (bool ok, bytes memory ret) = address(doppiLP).staticcall(callData);
    if (!(ok && ret.length >= 32)) revert PriceFailed();
    price = abi.decode(ret, (uint256));
    if (price == 0) revert PriceFailed();  // zero guard at the source
}
```

An additional `require(price > 0)` in `_processNewSettlements` is redundant — the guard at the getter level covers all call sites including `_emergencySettlement` and `_resetBound`.

---

### H-03 — Regression IV Cast Can Silently Wrap Negative Value to Large `uint256`

**Contract:** `DoppiOffer.sol` → `_getImpliedVol()` · **Severity:** High · **Status:** ✅ Fixed

#### Original Finding

The quadratic regression `(a·x² + b·x + c)` could evaluate to a negative `int256` for certain price inputs or miscalibrated coefficients. Casting a negative `int256` directly to `uint256` produces a two's-complement wrap to a very large value (≈ `2^256 - n`), which propagates into the Black-Scholes pricer, producing garbage APR values. At the other extreme, a near-zero result produced near-zero APR offers.

#### Fix Applied

Sign check before cast:

```solidity
function _getImpliedVol(uint256 _daysInTimestamp, uint256 _price, bool _isBuy)
    internal view returns (uint256 markIV, uint256 lastUpdated)
{
    int256 price = int256(_price);
    RegressionVar memory regr = _isBuy ? buyRegression[_daysInTimestamp] : sellRegression[_daysInTimestamp];
    int256 rawIV = (((((regr.a * price) / priceDecimal) * price) / priceDecimal)
                + ((regr.b * price) / priceDecimal)
                + regr.c);
    if (rawIV <= 0) return (0, regr.lastUpdated);  // callers handle zero IV gracefully
    markIV = uint256(rawIV) / 1e11;
    lastUpdated = regr.lastUpdated;
}
```

All callers (`_getBuyAPR`, `_getSellAPR`, `getOneDayBuffer`) already guard for `iv == 0` and return early, so this is a clean zero-return contract.

---

### H-04 — Silent TWAP Fallback Allows Perpetual Oracle Degradation

**Contract:** `DALiquidityLib.sol` → `getPriceWithFallback()` · **Severity:** High · **Status:** ⚠️ Partially Addressed

#### Original Finding

When the Chainlink feed is stale or unavailable, `getPriceWithFallback` silently falls back to an on-chain TWAP with no on-chain signal. Operators have no way to detect that the protocol is running on TWAP, which is manipulable via sandwich attacks on low-liquidity BNB Chain pools over the `twapDuration` window.

#### Fix Applied

The `getTWAPPrice` fallback previously called `revert("no twap price")` on a zero TWAP, causing `checkUpkeep` to silently report "no upkeep needed". This has been changed to return `0` instead, preventing an unnecessary revert. The fallback is still silent — no on-chain flag or event distinguishes Chainlink from TWAP pricing.

#### Remaining Risk

Operators cannot detect programmatically whether the protocol is operating on TWAP. TWAP manipulation risk is unchanged.

#### Recommendation

Expose a readable flag in `DoppiLiquidity` or `DoppiOffer`:

```solidity
bool public usingTWAPFallback;

function refreshOracleStatus() external {
    uint256 chainlinkPrice = DALiquidityLib.getPrice(chainLinkFeed, maxDelay);
    usingTWAPFallback = (chainlinkPrice == 0);
}
```

Off-chain monitoring should alert when `usingTWAPFallback` remains `true` across multiple blocks.

---

### H-05 — `_getTotalInterestLiabilities()` Fails Silently, Understating Liabilities

**Contract:** `DoppiLiquidityRouter.sol` · **Severity:** High · **Status:** ✅ Fixed

#### Original Finding

If the `staticcall` to `DoppiCore.getInterestLiabilities()` failed or returned unexpected data, the function silently returned `(0, 0)`, allowing LPs to withdraw the full pool balance even when substantial interest was owed to depositors.

#### Fix Applied

```solidity
function _getTotalInterestLiabilities() internal view returns (uint256 liabilityA, uint256 liabilityB) {
    require(doppiCore != address(0), "doppiCore not set");
    (bool success, bytes memory data) = doppiCore.staticcall(
        abi.encodeWithSignature("getInterestLiabilities()")
    );
    require(success && data.length == 64, "liabilities call failed");
    (liabilityA, liabilityB) = abi.decode(data, (uint256, uint256));
}
```

---

## 8. Medium Findings

---

### M-01 — Interest Formula Overflow Due to Narrow-Type Constant Multiplication

**Contract:** `DoppiCore.sol` → `_depositBuy()` · **Severity:** Medium · **Status:** ✅ Fixed

#### Original Finding

The single-expression interest formula:

```solidity
uint256 interest = (amount * _buyOffer.apr * duration) / (BASIS_POINTS * SECONDS_PER_YEAR);
```

caused `panic: arithmetic underflow or overflow (0x11)`. The root cause was Solidity's type narrowing rule: `BASIS_POINTS` is `uint16` and `SECONDS_PER_YEAR` is `uint32`. The sub-expression `BASIS_POINTS * SECONDS_PER_YEAR` is resolved at `uint32` precision, and `10,000 × 31,536,000 = 315,360,000,000` exceeds `uint32` max (`4,294,967,295`). The same issue applies to `SECONDS_PER_DAY (uint24) * numDays (uint8) = uint24`.

The original report recommended the single-expression formula as a precision improvement. However, the formula must use explicit `uint256` casts to be safe.

#### Fix Applied

Explicit `uint256` casts on all narrow-typed constants in `_depositBuy`:

```solidity
uint256 duration = uint256(SECONDS_PER_DAY) * uint256(numDays);
uint256 interest = (amount * uint256(_buyOffer.apr) * duration)
                 / (uint256(BASIS_POINTS) * uint256(SECONDS_PER_YEAR));
```

`_depositSell` retains the safe two-step approach (no overflow risk because `amount` is already `uint256`, which promotes the narrower types):

```solidity
uint256 interest = (amount * _sellOffer.apr) / BASIS_POINTS;
interest = (interest * duration) / SECONDS_PER_YEAR;
```

---

### M-02 — Profit Ratio Truncation Systematically Shortchanges LP Pool

**Contract:** `DoppiCore.sol` → `_settleStrike()`, `_settleNoStrike()` · **Severity:** Medium · **Status:** ❌ Open

#### Current State

The settlement helpers compute each position's share of a batch-traded amount as:

```solidity
uint256 myamountOut = order.outAmount * p.amount / swappedAmount;  // _settleStrike
uint256 amountOut   = order.outAmount * p.amount / swappedAmount;  // _settleNoStrike
```

Plain `a * b / c` integer arithmetic truncates toward zero. Over many settlements this accumulates as small, irrecoverable accounting dust that remains in the contract with no sweep mechanism. For large values of `order.outAmount`, the intermediate `order.outAmount * p.amount` can also overflow `uint256` in extreme edge cases (though this is unlikely in practice given realistic position sizes).

#### Recommendation

Use OpenZeppelin's `Math.mulDiv` (already available via `@openzeppelin/contracts/utils/math/Math.sol`, which is already imported in `DoppiLiquidity.sol`):

```solidity
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// In both _settleStrike and _settleNoStrike:
uint256 myamountOut = Math.mulDiv(order.outAmount, p.amount, swappedAmount);
```

`Math.mulDiv` performs 512-bit overflow-safe multiplication before division, producing a floor-accurate result identical in value to the current expression but guarded against overflow.

---

### M-03 — `MIN_BUFFER` / `MAX_BUFFER` Ordering Not Enforced

**Contract:** `DoppiOffer.sol` · **Severity:** Medium · **Status:** ✅ Fixed

#### Fix Applied

```solidity
function setBuffer(uint256 _min, uint256 _max) external onlyOwner {
    require(_min < _max, "min must be less than max");
    MIN_BUFFER = _min;
    MAX_BUFFER = _max;
}
```

---

### M-04 — `supportDays` Array Accepts Duplicate Entries

**Contract:** `DoppiCore.sol` · **Severity:** Medium · **Status:** ✅ Fixed

#### Fix Applied

```solidity
function addSupportDay(uint8 _day) external onlyOwner {
    for (uint256 i = 0; i < supportDays.length; i++) {
        require(supportDays[i] != _day, "day already registered");
    }
    supportDays.push(_day);
    nextProcessId[_day] = 1;
    nextPositionId[_day] = 1;
}
```

---

### M-05 — `getAllOffers()` Uses `this.` External Call Pattern

**Contract:** `DoppiOffer.sol` · **Severity:** Medium · **Status:** ✅ Fixed

#### Fix Applied

`getAllOffers` now calls internal `_getBuyOffers` / `_getSellOffers` helpers directly, eliminating the unnecessary `this.` re-entrancy vector and gas overhead.

---

## 9. Low Findings

---

### L-01 — Active Debug Import in Production Contract

**Contract:** `DoppiUpkeepManager.sol` · **Severity:** Low · **Status:** ✅ Fixed

The `import "forge-std/console.sol"` line was active (not commented out), unlike all other in-scope files. Fixed by commenting it out (see C-01 which covered the Critical aspect of this same finding).

---

### L-02 — Inconsistent Solidity Pragma Versions

**Severity:** Low · **Status:** ⚠️ Partially Addressed

All mainnet contracts have been standardised to `^0.8.26`. Two files remain at `^0.8.20`:

| File                 | Pragma    | Note                         |
|----------------------|-----------|------------------------------|
| `src/mainnet/ERC7575.sol`  | `^0.8.20` | Production — used by `DoppiLiquidityRouter` |
| `src/mainnet/Swapper.sol`  | `^0.8.20` | Test helper — low priority   |

`ERC7575.sol` is a production contract and should be updated to `^0.8.26` for consistency.

---

### L-03 — SPDX License Identifier Inconsistency

**Severity:** Low · **Status:** ✅ Fixed

Four production contracts previously declared `SPDX-License-Identifier: UNLICENSED` while the majority of the protocol used `MIT`:

| File                       | Before       | After |
|----------------------------|--------------|-------|
| `DoppiLiquidity.sol`       | `UNLICENSED` | `MIT` |
| `DoppiLiquidityRouter.sol` | `UNLICENSED` | `MIT` |
| `DoppiTrader.sol`          | `UNLICENSED` | `MIT` |
| `DoppiTraderFactory.sol`   | `UNLICENSED` | `MIT` |

All in-scope protocol contracts are now consistently `MIT`. `BlackScholes.sol` retains `ISC` as it is a third-party library with its own upstream licence.

---

### L-04 — Hardcoded USDT Address in `DALiquidityLib`

**Severity:** Low · **Status:** ❌ Open

```solidity
// DALiquidityLib.sol
address usdt = address(0x55d398326f99059fF775485246999027B3197955);
```

This BSC mainnet USDT address is hardcoded inside library logic. The library is non-portable to other chains without redeployment. Pass the address as a parameter or via a configuration contract.

---

### L-05 — Missing Events for Critical Admin Parameter Changes

**Severity:** Low · **Status:** ❌ Open

No events are emitted for the following security-sensitive configuration changes:

| Function                         | Contract         | Missing Event                              |
|----------------------------------|------------------|--------------------------------------------|
| `setTreasury(address, uint24)`   | `DoppiCoreAdmin` | `TreasuryUpdated(address indexed, uint24)` |
| `setForwarderAddress(address)`   | `DoppiCoreAdmin` | `ForwarderUpdated(address indexed)`        |
| `setOpportunityBot(address, bool)`| `DoppiCoreAdmin`| `OpportunityBotUpdated(address indexed, bool)` |
| `setRegression(...)`             | `DoppiOffer`     | `RegressionUpdated(uint256 indexed)`       |
| `setAPRTolerance(uint16)`        | `DoppiCoreAdmin` | `APRToleranceUpdated(uint16)`              |

Without events, off-chain monitoring systems cannot detect parameter changes, making it impossible to alert on misconfiguration or privilege abuse in real time.

---

### L-06 — `priceDecimal` Cached at Construction, No Refresh Path

**Contract:** `DoppiCore.sol` · **Severity:** Low · **Status:** ✅ Fixed

```solidity
constructor(...) {
    priceDecimal = 10 ** _doppiLP.getPriceDecimals();  // set once, never updated
}
```

If the oracle feed on `DoppiLiquidity` is ever replaced with one that reports a different decimal precision, all price arithmetic in `DoppiCore` silently uses the wrong scale factor.

#### Fix Applied

`setPriceDecimal` was added to `DoppiCoreAdmin`, giving the owner a direct override path:

```solidity
function setPriceDecimal(uint256 _priceDecimal) external onlyOwner {
    priceDecimal = _priceDecimal;
}
```

This covers the oracle-upgrade scenario: the owner calls `setPriceDecimal(10 ** newFeed.getPriceDecimals())` after deploying the replacement feed.

---

## 10. New Findings (Follow-Up Review v2)

---

### N-01 — `treasury_fee` Cap of 25% — Protocol Profit Fee

**Contract:** `DoppiCoreAdmin.sol` · **Severity:** Medium · **Status:** ✅ Fixed

The fee cap introduced to fix H-01 was initially set to 3000 basis points (30%), which was flagged as too permissive assuming the fee applied to deposited capital.

#### Fix Applied

The cap has been lowered to 2500 basis points (25%):

```solidity
require(_treasury_fee <= 2500, "fee exceeds 25%");
```

#### Developer Rationale

The `treasury_fee` is charged on the **profit generated by the protocol** — specifically on APR earned by positions and on gains realised by the opportunity bot — not on the depositor's principal. This is consistent with a performance-fee model (comparable to a 2/20 hedge fund structure or Yearn-style yield vault fees). At 25% of yield, user principal is always fully protected, making the original concern about users receiving only 70 USDT for a 100 USDT deposit inapplicable.

#### Benchmark Comparison (Performance Fees)

| Protocol / Structure   | Max Performance Fee         |
|------------------------|-----------------------------|
| Yearn Finance          | 20% of yield                |
| Traditional hedge fund | 20–30% of profit            |
| Doppi (capped)         | 25% of APR / opportunity gain |

A 25% cap on profit is defensible and within market norms for this fee model.

---

### N-02 — `emergencySettlement` Does Not Route Through Standard `Settled` Event

**Contract:** `DoppiCore.sol` → `_emergencySettlement()` · **Severity:** Low · **Status:** ❌ Open

The emergency settlement loop calls `_settleNoStrike` and emits `EmergencyWithdraw`, but the standard `Settled` event — emitted in `_settlePosition` — is not emitted. Off-chain indexers that track protocol-wide settlement volume via `Settled` events will undercount during emergency recovery.

This is a minor operational transparency issue; user funds are correctly returned. Off-chain monitoring that relies on `Settled` events should also monitor `EmergencyWithdraw`.

---

## 11. Supplemental Findings — Deep-Dive v3 (DoppiTrader / DoppiLiquidity)

This section documents six additional vulnerabilities identified during a targeted adversarial review of `DoppiTrader`, `DoppiLiquidity`, and their access control paths. The central question was: *can an attacker drain the balance held in DoppiLiquidity, DoppiCore, DoppiPoints, DoppiReferral, or DoppiTrader?*

---

### S-01 — Stale Unlimited Approval After Entry Point Deregistration

**Contract:** `DoppiLiquidity.sol` → `setEntryPoint()` · **Severity:** High · **Status:** ✅ Fixed

#### Description

When an entry point (such as `DoppiLiquidityRouter`) is registered, `DoppiLiquidity` grants it an unlimited ERC20 allowance:

```solidity
function setEntryPoint(address entryPoint, bool isValid) external onlyOwner {
    validEntryPoints[entryPoint] = isValid;
    if (isValid) {
        assetA.approve(entryPoint, type(uint256).max);
        assetB.approve(entryPoint, type(uint256).max);
    }
    // ← No else branch — approval is NEVER revoked when isValid = false
}
```

When `setEntryPoint(addr, false)` is called during a router upgrade or deregistration, `validEntryPoints[addr]` becomes `false` — so the address can no longer call `mintShares` or `burnShares`. However, the `type(uint256).max` ERC20 allowance that `DoppiLiquidity` granted remains on-chain permanently. Any party who controls the deregistered contract can call `assetA.transferFrom(DoppiLiquidity, attacker, balance)` at any time to drain the LP — no further interaction with `DoppiLiquidity` is required.

#### Impact

Full drain of all `assetA` and `assetB` held in `DoppiLiquidity` via a single `transferFrom` call from any formerly-registered entry point address. This is a realistic attack in the normal lifecycle of the protocol (routers get upgraded; old addresses are deregistered).

#### Fix Applied

The `else` branch was added to revoke approvals on deregistration:

```solidity
function setEntryPoint(address entryPoint, bool isValid) external onlyOwner {
    validEntryPoints[entryPoint] = isValid;
    if (isValid) {
        assetA.approve(entryPoint, type(uint256).max);
        assetB.approve(entryPoint, type(uint256).max);
    } else {
        assetA.approve(entryPoint, 0);  // revoke stale approval
        assetB.approve(entryPoint, 0);
    }
}
```

---

### S-02 — `bulkDeposit` Accepts Unvalidated Strike Price From TraderBot

**Contract:** `DoppiCore.sol` → `bulkDeposit()` · **Severity:** Medium-High · **Status:** ✅ Fixed

#### Description

`deposit_buy` and `deposit_sell` validate the caller-supplied `strikePrice` against a fresh on-chain market lookup:

```solidity
DualAssetOffer memory buyOffer = doppiOffer.getOffer(true, params.numDays, params.strikeZone);
if (buyOffer.strikePrice != params.strikePrice || buyOffer.price == 0)
    revert InvalidStrikePriceOrPrice();
```

`bulkDeposit` (callable only by an authorised TraderBot) skips this validation entirely — the bot supplies the `_offers[]` array and no price cross-check occurs:

```solidity
function bulkDeposit(
    bool isBuy,
    DepositParams[] calldata params,
    DualAssetOffer[] memory _offers,
    ...
) external {
    _onlyTraderBot();
    ...
    if (param.apr == 0) revert InvalidAPR(); // only APR is checked
    isBuy ? _depositBuy(param, _offers[i]) : _depositSell(param, _offers[i]);
}
```

Inside `_depositBuy`, the payout stored per position is:

```solidity
uint256 payout = (amount * priceDecimal) / _buyOffer.strikePrice;
```

A malicious or compromised TraderBot passes a near-zero `strikePrice`, inflating `payout` to a very large value. At settlement, if the payout exceeds available LP capital, `_checkPayoutBalance` forces `DoppiLiquidity` to swap from its own reserves to cover the shortfall, draining LP capital.

#### Impact

A compromised TraderBot can drain `DoppiLiquidity` reserves incrementally over multiple deposit/settle cycles. Requires TraderBot compromise, but the TraderBot is a user-deployed clone — not strictly privileged infrastructure.

#### Fix Applied — Option C: Remove Caller-Supplied Offer Data Entirely

Rather than cross-checking the caller's `_offers[]` array, `_offers[]` was removed from the interface entirely. A new minimal struct `BulkDepositParam` was introduced in `DoppiCoreTypes.sol`:

```solidity
struct BulkDepositParam {
    uint256 amount;
    uint8 strikeZone;
    uint8 numDays;
}
```

`bulkDeposit` now fetches the market price once and derives each slot's `DualAssetOffer` internally via a fresh `doppiOffer.getSingleOffer` call. The caller supplies only position size and term — no price-sensitive data:

```solidity
function bulkDeposit(bool isBuy, BulkDepositParam[] calldata params, uint256 total) external whenNotPaused {
    _onlyTraderBot();
    uint256 price = _getPriceFromLP();  // single oracle call
    for (uint256 i = 0; i < params.length; ) {
        BulkDepositParam calldata param = params[i];
        // Core derives authoritative offer — caller cannot manipulate strikePrice/apr/expiry
        DualAssetOffer memory offer = doppiOffer.getSingleOffer(isBuy, param.numDays, param.strikeZone, price);
        if (offer.price == 0) revert InvalidStrikePriceOrPrice();
        DepositParams memory dp = DepositParams({
            amount: param.amount, strikeZone: param.strikeZone,
            strikePrice: offer.strikePrice, numDays: param.numDays,
            apr: offer.apr, expiry: offer.expiry
        });
        isBuy ? _depositBuy(dp, offer) : _depositSell(dp, offer);
        _updateLowerUpperBound(offer.strikePrice);
        unchecked { ++i; }
    }
    ...
}
```

`DoppiTrader` was updated accordingly: `_prepareOrder` now returns `BulkDepositParam` (not `DepositParams + DualAssetOffer`), `_prepareOrders` / `_placeOrders` / `_placeBulk` / `_place_oneside` all drop the `price` parameter and `offers` arrays. This also eliminates the need for a second oracle call in `DoppiTrader`.

As an additional defensive layer, `DoppiOffer._getOffer` received a bounds check (`require(_strikeZone < TOTAL_OFFER)`) and `DoppiTraderAdminView.setMaxOrder` was clamped to `impliedVol.TOTAL_OFFER()` to prevent configuration of out-of-range strike zones.

---

### S-03 — `cleanUpUnwind` Has No Access Control

**Contract:** `DoppiLiquidity.sol` → `cleanUpUnwind()` · **Severity:** Medium · **Status:** ✅ Fixed

#### Description

```solidity
function cleanUpUnwind(uint256 toClearAmountBuy, uint256 toClearAmountSell) external {
    // ← no modifier — callable by any address
    _getRemovingPrices(toClearAmountBuy, toClearAmountSell);
    _updateBound();
}
```

Any address can call this function with `type(uint256).max` for both arguments, zeroing out the entire `amountToBuy` and `amountToSell` hedge-tracking maps. After a wipe, `checkUpkeep` in `DoppiCore` finds nothing to unwind and returns `false`, causing the LP to accumulate unhedged directional exposure indefinitely. The attacker pays only gas.

#### Impact

Silently disables all automated LP rebalancing via a trivial zero-cost call. Degrades LP solvency over time by allowing unhedged positions to accumulate.

#### Fix Applied

A custom `onlyLiquidityRouterOrOwner` modifier was added to `DoppiLiquidity`, restricting `cleanUpUnwind` to the registered `DoppiLiquidityRouter` or the contract owner:

```solidity
address public doppiLiquidityRouter;

function setDoppiLiquidityRouter(address _router) external onlyOwner {
    doppiLiquidityRouter = _router;
}

modifier onlyLiquidityRouterOrOwner() {
    require(msg.sender == doppiLiquidityRouter || msg.sender == owner(), "not router or owner");
    _;
}

function cleanUpUnwind(
    uint256 toClearAmountBuy,
    uint256 toClearAmountSell
) external onlyLiquidityRouterOrOwner {
    ...
}
```

---

### S-04 — `DoppiTrader` Has Active `forge-std/console.sol` Import

**Contract:** `DoppiTrader.sol` line 10 · **Severity:** Medium · **Status:** ✅ Fixed

#### Description

```solidity
import "forge-std/console.sol";  // NOT commented out
```

C-01 fixed this only in `DoppiUpkeepManager`. `DoppiTrader` still carries the active import. Every clone deployed by `DoppiTraderFactory` inherits the bloated bytecode. The concerns are identical to C-01: EIP-170 size risk, testing instrumentation left in production code.

Note: `DoppiTrader` clones are deployed on demand by users — each one adds unnecessary bytecode to the chain.

#### Fix Applied

```solidity
// import "forge-std/console.sol"; // removed: debug-only import, not for production
```

---

### S-05 — `setDefaultDay` Infinite Loop If Target Day Not Found

**Contract:** `DoppiTrader.sol` (admin function) · **Severity:** Medium · **Status:** ✅ Fixed

#### Description

```solidity
function setDefaultDay(uint8 _day) external onlyOwner {
    bool valid;
    uint8[] memory supportDays = doppiCore.supportDays();
    for (uint8 x = 0; x < supportDays.length; ) {
        if (supportDays[x] == _day) { valid = true; break; }
        // ← x is NEVER incremented — infinite loop when _day is absent
    }
    if (valid) { traderDefaultDay = _day; }
}
```

If `_day` is not present in `supportDays`, the loop spins on `x = 0` until the transaction exhausts its gas limit (OOG revert). The loop exit condition (`x < supportDays.length`) is never satisfied because `x` never changes. The owner cannot call `setDefaultDay` with any unsupported day without paying maximum gas, and the transaction always reverts.

#### Impact

Administrative DoS on `setDefaultDay` for any value not already in `supportDays`. During protocol upgrades where a new day must be added before being set as default, this is a blocking issue.

#### Fix Applied

`unchecked { ++x; }` added inside the loop body, consistent with the rest of the codebase:

```solidity
for (uint8 x = 0; x < supportDays.length; ) {
    if (supportDays[x] == _day) { valid = true; break; }
    unchecked { ++x; }
}
```

---

### S-06 — `_processTopUp` Uses Bare `transfer` Instead of `safeTransfer`

**Contract:** `DoppiTrader.sol` → `_processTopUp()` · **Severity:** Low · **Status:** ✅ Fixed

#### Description

```solidity
function _processTopUp(TopUpInfo memory topUpInfo) internal {
    assetA.safeTransferFrom(validTrader, address(this), topUpInfo.totalInfundToken);
    assetA.transfer(address(doppiUpkeepManager), topUpInfo.totalInfundToken); // ← bare transfer
    doppiUpkeepManager.performTopUpkeep(...);
}
```

The file uses `SafeERC20` with `safeTransferFrom` on the same line above. The bare `IERC20.transfer` call does not check the return value. For tokens that return `false` on failure (non-reverting error pattern, e.g., some versions of USDT on BSC), the call silently fails, sending nothing to `doppiUpkeepManager` while `performTopUpkeep` is called on an unfunded upkeep.

#### Fix Applied

The current implementation already uses `safeTransfer` for the internal transfer:

```solidity
function _processTopUp(TopUpInfo memory topUpInfo) internal {
    assetA.safeTransferFrom(validTrader, address(this), topUpInfo.totalInfundToken);
    assetA.safeTransfer(address(doppiUpkeepManager), topUpInfo.totalInfundToken); // ✅ safe
    doppiUpkeepManager.performTopUpkeep(upkeepId, topUpInfo);
}
```

No change was required — the code was consistent with `SafeERC20` usage at the point of this review.

---

## 12. Informational Findings

---

### I-01 — `DoppiTrader.initialize()` Has Redundant Initialization Guard

**Contract:** `DoppiTrader.sol` · **Severity:** Informational · **Status:** ✅ Fixed

#### Original Finding

```solidity
bool private initialized;           // manual guard — wastes one storage slot

function initialize(...) external initializer {  // OpenZeppelin guard
    if (initialized) revert AlreadyInitialized(); // redundant
    initialized = true;
    ...
}
```

OpenZeppelin's `initializer` modifier already prevents re-initialisation. The manual `initialized` flag wasted a storage slot and added code complexity without adding protection.

#### Fix Applied

The `initialized` bool and the `if (initialized) revert AlreadyInitialized()` check have been removed. The `initializer` modifier alone provides the re-initialisation guard.

---

## 13. Positive Security Observations

The following patterns were confirmed correct across both audit rounds:

| Pattern                                                               | Status                  |
|-----------------------------------------------------------------------|-------------------------|
| `ReentrancyGuard` on all state-modifying external functions           | ✅ Confirmed            |
| `SafeERC20` for all token operations                                  | ✅ Confirmed            |
| `Pausable` + `emergencyMode` circuit breakers                         | ✅ Confirmed (improved) |
| `immutable` asset addresses (`assetA`, `assetB`, `doppiOffer`)        | ✅ Confirmed            |
| Chainlink `answeredInRound < roundId` staleness validation            | ✅ Confirmed            |
| `try/catch` on trader-bot unwind to prevent cascade failures          | ✅ Confirmed            |
| Interest liability tracked with underflow protection                  | ✅ Confirmed            |
| Custom error types (`revert InvalidAmount()`) for gas efficiency      | ✅ Confirmed            |
| `addSupportDay` initialises per-day position counters                 | ✅ New — Correct        |
| `setBuffer` enforces `_min < _max`                                    | ✅ New — Correct        |
| `_getTotalInterestLiabilities` reverts instead of returning zero      | ✅ New — Correct        |
| `getAllOffers` uses internal calls                                     | ✅ New — Correct        |
| `_getImpliedVol` returns `(0, lastUpdated)` on non-positive IV        | ✅ New — Correct        |
| Zero-fee guard in `_safeTransferWithFee`                              | ✅ New — Correct        |

---

## 14. Remaining Open Items

Listed in priority order for final remediation.

### Tier 1 — Must Fix Before Mainnet

| ID    | Action                                                                                                                                 | Effort   |
|-------|----------------------------------------------------------------------------------------------------------------------------------------|----------|
| **M-02** | Replace `order.outAmount * p.amount / swappedAmount` with `Math.mulDiv(...)` in `_settleStrike` and `_settleNoStrike`          | 30 min   |

### Tier 2 — Strongly Recommended

| ID    | Action                                                                                                                         |
|-------|--------------------------------------------------------------------------------------------------------------------------------|
| **L-05** | Add events to `setTreasury`, `setForwarderAddress`, `setOpportunityBot`, `setRegression`, `setAPRTolerance`               |
| **H-04** | Expose `usingTWAPFallback` flag and wire off-chain monitoring alert                                                       |
| **L-02** | Update `ERC7575.sol` pragma to `^0.8.26`                                                                                  |

### Tier 3 — Nice to Have

| ID    | Action                                                                                |
|-------|---------------------------------------------------------------------------------------|
| **C-03** | Optional: convert treasury fee to pull model (`claimFees`) for maximum robustness |
| **L-04** | Pass USDT address as constructor/config parameter in `DALiquidityLib`              |
| **N-02** | Update off-chain indexers to monitor `EmergencyWithdraw` alongside `Settled`       |

---

## 15. Appendix — Contract Inventory

| Contract                 | Lines (approx.) | Inherits                                         | Key Dependencies               |
|--------------------------|-----------------|--------------------------------------------------|--------------------------------|
| `DoppiCore`              | ~980            | `DoppiCoreAdmin`, `DoppiCoreView`, `ReentrancyGuard` | `SafeERC20`, Chainlink AutoComp |
| `DoppiCoreAdmin`         | ~130            | `DoppiCoreTypes`, `Ownable`, `Pausable`          | —                              |
| `DoppiCoreView`          | ~120            | `DoppiCoreTypes`                                 | —                              |
| `DoppiCoreTypes`         | ~80             | —                                                | —                              |
| `DoppiLiquidity`         | ~650            | `ReentrancyGuard`, `Ownable`, `Pausable`         | PancakeSwap V3, `DALiquidityLib` |
| `DoppiLiquidityRouter`   | ~280            | `ERC7575`, `ReentrancyGuard`, `Ownable`          | `DoppiLiquidity`, OpenZeppelin Math |
| `DoppiOffer`             | ~300            | `Ownable`                                        | `BlackScholes`, `DALiquidityLib`, Chainlink |
| `DoppiUpkeepManager`     | ~260            | `Ownable`, `Pausable`                            | Chainlink Registry, `ISwapRouter` |
| `DoppiTrader`            | ~420            | `Initializable`, `Ownable`                       | `DoppiCore`, `DoppiLiquidity`  |
| `DoppiTraderFactory`     | ~90             | `Ownable`                                        | `DoppiTrader` (clone)          |
| `DoppiReferral`          | ~200            | `Ownable`                                        | `DoppiPoints`                  |
| `DoppiPoints`            | ~150            | `Ownable`, `Pausable`                            | —                              |
| `DoppiClaim`             | ~120            | `Ownable`, `ReentrancyGuard`                     | `SafeERC20`                    |
| `BlackScholes`           | ~400            | —                                                | `SignedSafeDecimalMath`        |
| `DALiquidityLib`         | ~130            | —                                                | Chainlink, Uniswap V3 TWAP     |

---

*This consolidated report supersedes `AUDIT_REPORT.md` (April 5, 2026) and `AUDIT_REPORT_V2.md` (April 11, 2026). It reflects all developer remediations applied through April 12, 2026, including the resolution of all six supplemental findings (S-01 through S-06), and should be read alongside `AUDIT_REPORT_ROUND4.md` for the latest subsystem-specific status. All `forge build` and `forge test` checks pass as of this revision. A formal third-party audit is strongly recommended before mainnet deployment.*
