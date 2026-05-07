# PLACEHOLDER_TO_TRIGGER_FULL_REPLACE

---

| | |
|---|---|
| **Project** | Doppi Protocol |
| **Repository** | `doppi-smart-contracts` |
| **Scope** | `src/mainnet/**` · `src/Library/**` · `src/Interface/**` |
| **Solidity Versions** | `^0.8.19`, `^0.8.20`, `^0.8.26` |
| **Audit Date** | April 5, 2026 |
| **Auditor** | Internal Security Review |
| **Status** | Draft — Pending Remediation |

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
10. [Informational Findings](#10-informational-findings)
11. [Positive Security Observations](#11-positive-security-observations)
12. [Appendix — Contract Inventory](#12-appendix--contract-inventory)

---

## 1. Executive Summary

This report presents the findings of a security review performed on the Doppi Protocol smart contracts. Doppi is a dual-asset structured product protocol built on BNB Chain that allows users to deposit single assets into fixed-term positions earning options-derived APR. The protocol integrates Chainlink oracle feeds with a Uniswap V3 TWAP fallback, a Black-Scholes options pricer, a three-tier referral system, and Chainlink Automation for automated position settlement.

**Overall Risk Assessment: HIGH**

A total of **19 findings** were identified across four severity tiers. Three **Critical** findings were discovered that can directly lead to permanent loss of user funds or a complete halt of the settlement subsystem. These must be resolved before mainnet deployment.

| Severity | Count |
|----------|-------|
| Critical | 3 |
| High | 5 |
| Medium | 5 |
| Low | 6 |
| **Total** | **19** |

---

## 2. Scope & Methodology

### 2.1 In-Scope Files

| Contract | Source File |
|---|---|
| `DoppiCore` | `src/mainnet/DoppiCore.sol` |
| `DoppiCoreAdmin` | `src/mainnet/DoppiCoreAdmin.sol` |
| `DoppiCoreView` | `src/mainnet/DoppiCoreView.sol` |
| `DoppiCoreTypes` | `src/mainnet/DoppiCoreTypes.sol` |
| `DoppiLiquidity` | `src/mainnet/DoppiLiquidity.sol` |
| `DoppiLiquidityRouter` | `src/mainnet/DoppiLiquidityRouter.sol` |
| `DoppiLiquidityTypes` | `src/mainnet/DoppiLiquidityTypes.sol` |
| `DoppiOffer` | `src/mainnet/DoppiOffer.sol` |
| `DoppiOpportunity` | `src/mainnet/DoppiOpportunity.sol` |
| `DoppiReferral` | `src/mainnet/DoppiReferral.sol` |
| `DoppiPoints` | `src/mainnet/DoppiPoints.sol` |
| `DoppiTrader` | `src/mainnet/DoppiTrader.sol` |
| `DoppiTraderFactory` | `src/mainnet/DoppiTraderFactory.sol` |
| `DoppiTraderAdminView` | `src/mainnet/DoppiTraderAdminView.sol` |
| `DoppiTraderTypes` | `src/mainnet/DoppiTraderTypes.sol` |
| `DoppiUpkeepManager` | `src/mainnet/DoppiUpkeepManager.sol` |
| `DoppiUpkeepManagerTypes` | `src/mainnet/DoppiUpKeepManagerTypes.sol` |
| `DoppiClaim` | `src/mainnet/DoppiClaim.sol` |
| `ERC7575` | `src/mainnet/ERC7575.sol` |
| `Swapper` | `src/mainnet/Swapper.sol` |
| `BlackScholes` | `src/mainnet/BlackScholes.sol` |
| `DALiquidityLib` | `src/Library/DALiquidityLib.sol` |
| `SafeDecimalMath` | `src/Library/SafeDecimalMath.sol` |
| `SignedSafeDecimalMath` | `src/Library/SignedSafeDecimalMath.sol` |
| `BotRegistryLib` | `src/Library/BotRegistryLib.sol` |

### 2.2 Out-of-Scope

- `lib/` (third-party dependencies: OpenZeppelin, forge-std, Uniswap v3, Solady)
- `test/` and `script/` directories
- Off-chain Chainlink Automation node configuration

### 2.3 Methodology

The review was conducted through:

- **Manual code review** of all in-scope files
- **Control-flow analysis** focusing on settlement, deposit, and oracle interaction paths
- **Data-flow analysis** of token transfers, price computation, and access control checks
- **Invariant analysis** of position lifecycle (deposit → settle / emergency-withdraw)
- **Threat modeling** against OWASP Smart Contract Top 10 and DeFi-specific attack patterns

---

## 3. System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User / Trader Bot                           │
└──────────────┬───────────────────────────────────┬──────────────────┘
               │ deposit_buy / deposit_sell         │ DoppiTrader.start()
               ▼                                    ▼
┌──────────────────────────┐         ┌──────────────────────────────┐
│       DoppiCore           │◄───────►│         DoppiTrader          │
│  (settlement engine)      │         │  (automated bot proxy)       │
│  - Chainlink Automation   │         │  - Initializable proxy       │
│  - Position lifecycle     │         │  - bulkDeposit / unwind      │
└────────┬─────────────────┘         └─────────────┬────────────────┘
         │ interestGet / swap                       │ LP deposit/redeem
         ▼                                          ▼
┌──────────────────────────┐         ┌──────────────────────────────┐
│     DoppiLiquidity        │         │    DoppiLiquidityRouter      │
│  (AMM + yield pool)       │◄───────►│  (ERC7575 vault entry/exit)  │
│  - Uniswap V3 swaps       │         │  - Withdrawal capacity mgmt  │
└────────┬─────────────────┘         └──────────────────────────────┘
         │ oracle price
         ▼
┌──────────────────────────┐         ┌──────────────────────────────┐
│       DoppiOffer          │         │    DoppiUpkeepManager        │
│  (IV + APR calculator)    │         │  (Chainlink LINK top-up)     │
│  - Black-Scholes lib      │         │  - Swap fundToken → LINK     │
│  - Regression-based IV    │         │  - Register / cancel upkeeps │
└──────────────────────────┘         └──────────────────────────────┘
         │
         ▼
┌──────────────────────────┐
│       DoppiReferral       │
│  (3-tier referral system) │
│  - DoppiPoints volume     │
└──────────────────────────┘
```

**Key protocol flows:**

1. **Deposit**: User calls `deposit_buy` or `deposit_sell` with a strike zone and term. APR is sourced from `DoppiOffer` (Black-Scholes IV via regression lookup). Position is stored in `positions_buy[day][posId]` / `positions_sell[day][posId]`.
2. **Settlement**: Chainlink Automation triggers `performUpkeep`. The contract fetches a spot price from `DoppiLiquidity`, calls interest retrieval on the LP, performs swap-based P&L attribution, and distributes principal + interest (minus treasury fee).
3. **Opportunity / Unwind**: An authorised bot hedges open strike exposures via `DoppiOpportunity`, recording swapped amounts against `opportunityBuy` / `opportunitySell` maps.
4. **LP Management**: LPs deposit via `DoppiLiquidityRouter` (ERC7575), receiving ERC20 shares of `DoppiLiquidity`. Withdrawal capacity is gated by outstanding interest liabilities.

---

## 4. Risk Classification

| Severity | Definition |
|---|---|
| **Critical** | Direct path to loss of user funds, permanent DoS of a core subsystem, or complete bypass of access control. Blocks mainnet deployment. |
| **High** | Significant financial risk, manipulable protocol parameters with no safety bounds, or silently degraded security guarantees. Must be fixed before deployment. |
| **Medium** | Precision or logic error causing systematic (but bounded) financial leakage, or a failure mode that is unlikely but impactful. Should be fixed before deployment. |
| **Low** | Best-practice violations, minor precision concerns, or issues that require privileged access or very specific conditions to exploit. Fix recommended. |
| **Informational** | Code quality, maintainability, or clarity concerns with no direct security impact. |

---

## 5. Findings Summary

| ID | Title | Contract | Severity | Status |
|---|---|---|---|---|
| C-01 | `forge-std/console.sol` imported in production contract | `DoppiUpkeepManager` | **Critical** | Open |
| C-02 | Settlement array overflow DoS with multiple support days | `DoppiCore` | **Critical** | Open |
| C-03 | Treasury transfer failure permanently reverts all settlements | `DoppiCore` | **Critical** | Open |
| H-01 | `aprToleranceBP` and `treasury_fee` have no upper-bound validation | `DoppiCoreAdmin` | **High** | Open |
| H-02 | Settlement price has no staleness check | `DoppiCore` | **High** | Open |
| H-03 | Regression IV computation can produce a negative or zero `markIV` | `DoppiOffer` | **High** | Open |
| H-04 | Silent TWAP fallback allows perpetual oracle degradation | `DALiquidityLib` | **High** | Open |
| H-05 | `LiquidityRouter._getTotalInterestLiabilities()` fails silently | `DoppiLiquidityRouter` | **High** | Open |
| M-01 | Interest calculation performs two sequential integer divisions | `DoppiCore` | **Medium** | Open |
| M-02 | Profit ratio truncation systematically shortchanges LP pool | `DoppiCore` | **Medium** | Open |
| M-03 | `MIN_BUFFER` / `MAX_BUFFER` relationship not enforced | `DoppiOffer` | **Medium** | Open |
| M-04 | `supportDays` array accepts duplicate entries | `DoppiCore` | **Medium** | Open |
| M-05 | `getAllOffers()` uses `this.` external call pattern | `DoppiOffer` | **Medium** | Open |
| L-01 | Production debug import in `DoppiOffer`, `DoppiLiquidity`, others (commented-out) | Multiple | **Low** | Open |
| L-02 | Inconsistent Solidity pragma versions across scope | Multiple | **Low** | Open |
| L-03 | SPDX license inconsistency (`MIT` vs `UNLICENSED`) | Multiple | **Low** | Open |
| L-04 | Hardcoded USDT address in `DALiquidityLib` | `DALiquidityLib` | **Low** | Open |
| L-05 | Missing events for critical admin parameter changes | `DoppiCoreAdmin`, `DoppiOffer` | **Low** | Open |
| L-06 | `priceDecimal` cached at construction, never updated | `DoppiCore` | **Low** | Open |

---

## 6. Critical Findings

---

### C-01 — `forge-std/console.sol` Imported in Production Contract

**Contract:** `DoppiUpkeepManager.sol`  
**Severity:** Critical  
**Category:** Supply Chain / Debug Code in Production

#### Description

`DoppiUpkeepManager` contains an unconditional production import of the Foundry test helper:

```solidity
// DoppiUpkeepManager.sol line 17
import "forge-std/console.sol";
```

Unlike the other contracts in scope that have this import commented out (`// import "forge-std/console.sol";`), this import is active. `forge-std/console.sol` relies on `console2` and emits logs via `staticcall` to a hardcoded address (`0x000000000000000000636F6e736F6c652e6c6f67`). While it does not affect runtime execution on a non-Foundry EVM, it:

1. **Bloats bytecode size** — increases deployment gas cost and risks pushing the contract past the EIP-170 24 KB limit.
2. **Signals incomplete audit readiness** — reviewers and users cannot trust that all debug instrumentation has been removed when at least one active import remains.
3. **Creates a potential dependency chain risk** — if `forge-std` is upgraded or its address changes, the contract may behave differently at compile time.

#### Recommendation

Remove the import immediately:

```diff
- import "forge-std/console.sol";
```

Verify that the identical commented-out pattern applied in all other in-scope contracts is also applied here.

---

### C-02 — Settlement Array Overflow DoS With Multiple Support Days

**Contract:** `DoppiCore.sol` — `getReadyAllPositions()`  
**Severity:** Critical  
**Category:** Logic Error / Denial of Service

#### Description

`getReadyAllPositions()` allocates a `uint64[]` of fixed size `UPKEEPS_PER_CHECK` and then iterates over **all** support days, writing into the same shared index counter `idx`:

```solidity
uint64[] memory tempPositionId = new uint64[](UPKEEPS_PER_CHECK); // fixed size
uint256 idx = 0;

for(uint8 x = 0; x < supportDays.length; ) {       // iterates ALL days
    ...
    for (uint64 posId = id; posId < end; ) {
        if (pos.expiryTimestamp <= block.timestamp) {
            tempPositionId[idx] = posId;             // idx can exceed array length!
            idx++;
        }
        ...
    }
}
```

Once more than one support day is registered (e.g., 1-day and 7-day terms are both active) and both have expired positions, `idx` will exceed `UPKEEPS_PER_CHECK`, causing an **out-of-bounds array write** that reverts under Solidity `^0.8`.

This revert propagates to Chainlink Automation's `checkUpkeep` (which is a `view` call). A reverting view function is treated by the Automation network as "no upkeep needed," causing **all position settlements to be silently skipped forever** once the protocol supports more than one term length.

#### Impact

- All positions with `expiryTimestamp <= block.timestamp` are never settled.
- Users cannot recover principal or interest until emergency mode is activated.
- The protocol requires owner-level manual intervention via `settleOrders()` to recover, but this too calls `_processNewSettlements`, which calls `getReadyAllPositions` internally — so `settleOrders` would also fail on the same data.

#### Recommendation

Size `tempPositionId` to accommodate the total number of positions that can be collected across all support days, or add a hard cap check inside the loop:

```solidity
uint64[] memory tempPositionId = new uint64[](UPKEEPS_PER_CHECK * supportDays.length);

// Or, inside the inner loop, add an early exit:
if (idx >= UPKEEPS_PER_CHECK) break;
```

The cleaner fix is to also push the per-day limit down proportionally:

```solidity
uint16 perDayLimit = UPKEEPS_PER_CHECK / uint16(supportDays.length);
uint64 end = id + uint64(perDayLimit);
```

---

### C-03 — Treasury Transfer Failure Permanently Reverts All Settlements

**Contract:** `DoppiCore.sol` — `_safeTransferWithFee()`  
**Severity:** Critical  
**Category:** External Dependency / Denial of Service

#### Description

The internal helper `_safeTransferWithFee` sends two sequential `safeTransfer` calls: first to the position owner, then to the treasury:

```solidity
function _safeTransferWithFee(IERC20 _asset, address _to, uint256 _amount) internal {
    uint256 amountFee = _amount * treasury_fee / 10000;
    uint256 amountAfterFee = _amount - amountFee;
    _asset.safeTransfer(_to, amountAfterFee);        // user receives first
    _asset.safeTransfer(treasury, amountFee);        // if this reverts, entire settlement fails
}
```

If the `treasury` address is:
- A contract without a `receive()` / `fallback()` function,
- A contract that conditionally reverts (e.g., paused, blocklisted on the token),
- The zero address (no initial check is enforced in `setTreasury`),

then the second `safeTransfer` reverts. Since `_safeTransferWithFee` is called from within `_settlePosition`, `_settleStrike`, and `_settleNoStrike` — all of which are part of the non-reentrant settlement loop — a single bad treasury address permanently blocks **all** settlements for **all** positions.

This is compounded by the fact that `setTreasury` performs no validation:

```solidity
function setTreasury(address _treasury, uint24 _treasury_fee) external onlyOwner {
    treasury_fee = _treasury_fee;
    treasury = _treasury;          // no zero-address or contract check
}
```

#### Impact

- If the treasury address is misconfigured, the entire settlement subsystem is bricked.
- Users cannot withdraw principal or interest and must wait for emergency mode.
- The owner can fix the address but any already-initiated `performUpkeep` transaction in the mempool will revert.

#### Recommendation

1. Validate the treasury address in the setter:
```solidity
require(_treasury != address(0), "zero treasury");
require(_treasury_fee <= 1000, "fee exceeds 10%");  // reasonable cap
```

2. Make the treasury transfer non-blocking so settlement is never held hostage:
```solidity
(bool ok, ) = address(_asset).call(
    abi.encodeCall(IERC20.transfer, (treasury, amountFee))
);
// emit an event if ok == false; do not revert
```

3. Alternatively, accumulate fees in the contract and allow the treasury to `pull` them rather than pushing on every settlement.

---

## 7. High Findings

---

### H-01 — `aprToleranceBP` and `treasury_fee` Have No Upper-Bound Validation

**Contract:** `DoppiCoreAdmin.sol`  
**Severity:** High  
**Category:** Input Validation / Misconfiguration

#### Description

Two administrative setter functions accept values with no validation of upper bounds:

```solidity
function setAPRTolerance(uint16 _toleranceBP) external onlyOwner {
    aprToleranceBP = _toleranceBP;    // can be 0..65535; 10001+ breaks APR check
}

function setTreasury(address _treasury, uint24 _treasury_fee) external onlyOwner {
    treasury_fee = _treasury_fee;     // can be 0..16777215; >10000 causes underflow
    treasury = _treasury;
}
```

**`aprToleranceBP > 10000`:** The APR tolerance check computes:
```solidity
uint256 maxAllowedDeviation = (offerAPR * aprToleranceBP) / 10000;
return deviation <= maxAllowedDeviation;
```
Setting `aprToleranceBP = 65535` allows any caller to deposit with an APR ≈ 6.5× the offered rate, drastically underpricing interest liability.

**`treasury_fee > 10000`:** The fee deduction computes:
```solidity
uint256 amountAfterFee = _amount - amountFee;  // amountFee > _amount → underflow
```
Although Solidity 0.8 would revert on underflow, this would brick all settlements if the value is ever misconfigured.

#### Recommendation

```solidity
function setAPRTolerance(uint16 _toleranceBP) external onlyOwner {
    require(_toleranceBP <= 10000, "exceeds 100%");
    aprToleranceBP = _toleranceBP;
}

function setTreasury(address _treasury, uint24 _treasury_fee) external onlyOwner {
    require(_treasury != address(0), "zero address");
    require(_treasury_fee <= 1000, "fee > 10%");  // adjust cap as needed
    treasury_fee = _treasury_fee;
    treasury = _treasury;
}
```

---

### H-02 — Settlement Price Has No Staleness Check

**Contract:** `DoppiCore.sol` — `_processNewSettlements()`  
**Severity:** High  
**Category:** Oracle Manipulation / Stale Data

#### Description

Position settlement fetches the price from `DoppiLiquidity` using a low-level call without any staleness or validity check:

```solidity
function _processNewSettlements(...) internal {
    uint256 price = _getPriceFromLP();   // no freshness validation
    _batchProcess(allPositions, settleAccu, price);
    _settle_positions(allPositions, price);
}
```

The `_getPriceFromLP()` implementation ultimately calls `DoppiLiquidity.getPrice()`, which itself may use a Chainlink feed or TWAP. However, `DoppiCore` has no independent validation that the returned price is recent. If `DoppiLiquidity` is paused or returns a stale/cached price, settlement can proceed at an incorrect price, causing users to receive incorrect payouts or strike determination to be wrong.

This is distinct from the oracle staleness check in `DALiquidityLib.getPrice()` — that check guards `DoppiOffer`, but there is no equivalent protection on the settlement price path.

#### Recommendation

Cache the block number or timestamp of the last successful price update in `DoppiLiquidity.getPrice()` and expose it. In `DoppiCore`, validate before settling:

```solidity
(uint256 price, uint256 priceUpdatedAt) = doppiLP.getPriceWithTimestamp();
require(block.timestamp - priceUpdatedAt < MAX_SETTLEMENT_PRICE_AGE, "stale price");
```

---

### H-03 — Regression IV Can Produce Negative or Zero `markIV` Without Revert

**Contract:** `DoppiOffer.sol` — `_getImpliedVol()`  
**Severity:** High  
**Category:** Input Validation / Arithmetic

#### Description

Implied volatility is computed as a quadratic regression over price with signed integer coefficients:

```solidity
// coefficients are int256, scaled by 1e27
markIV = uint256(
    (((((regr.a * price) / priceDecimal) * price) / priceDecimal)
    + ((regr.b * price) / priceDecimal)
    + regr.c)
) / 1e11;
```

Because the inner expression is cast from `int256` to `uint256` before division, a **negative result produces a very large `uint256`** (two's complement wrap-around). Similarly, zero coefficients that evaluate near zero produce a near-zero `markIV`, which then propagates to Black-Scholes as a near-zero volatility, resulting in near-zero APR offers (`apr = 0`).

The `setRegression` function accepts fully unbounded `int256` values with no range check:

```solidity
function setRegression(uint256 _daysInTimestamp,
    int256 _buya, int256 _buyb, int256 _buyc, ...) external onlyAdmin {
    buyRegression[_daysInTimestamp].a = _buya;    // no bounds
    ...
}
```

A miscalibrated or maliciously set regression can result in:
- APR = 0, so depositors receive no yield.
- Extreme positive `markIV` producing APR overflow.
- Negative `markIV` wrapping to a massive `uint256`, causing Black-Scholes to return garbage values (`callPrice`, `putPrice` become unreliable).

#### Recommendation

1. Add bounds validation on regression coefficients:
```solidity
int256 constant MAX_COEFF = 1e28;
require(_buya >= -MAX_COEFF && _buya <= MAX_COEFF, "coeff a out of range");
```
2. Add a post-computation sanity check inside `_getImpliedVol`:
```solidity
int256 rawIV = (((regr.a * price) / priceDecimal * price) / priceDecimal)
             + (regr.b * price / priceDecimal)
             + regr.c;
if (rawIV <= 0) return (0, regr.lastUpdated);
markIV = uint256(rawIV) / 1e11;
```

---

### H-04 — Silent TWAP Fallback Allows Perpetual Oracle Degradation

**Contract:** `DALiquidityLib.sol` — `getPriceWithFallback()`  
**Severity:** High  
**Category:** Oracle Security / Silent Failure

#### Description

The oracle library silently falls back to an on-chain TWAP when the Chainlink feed is stale or unavailable:

```solidity
function getPriceWithFallback(...) public view returns (uint256 rate) {
    rate = getPrice(chainLinkFeed, maxDelay);
    if (rate == 0) {
        rate = getTWAPPrice(_v3Pool, twapDuration);  // silent fallback
    }
}
```

While this is a resilience pattern, **there is no on-chain signal that the fallback is active**, and the TWAP is manipulable over the `twapDuration` window. If the Chainlink feed is persistently stale (e.g., due to a soft-launch configuration issue or feed deprecation), the entire protocol silently runs on TWAP indefinitely with no operator alert. TWAP manipulation via sandwich attacks, especially on low-liquidity BNB Chain pools, can result in:
- Incorrect APR pricing in `DoppiOffer`.
- Incorrect strike determination at settlement.

Additionally, `getTWAPPrice` calls `revert("no twap price")` if `twapPrice == 0`, but the error does not propagate meaningfully in a `view` call chain used by Automation — it merely causes `checkUpkeep` to appear as "no upkeep needed."

#### Recommendation

Emit an event when the fallback path is taken (this requires converting to a non-`view` function, which may require architectural changes). At minimum, expose the fallback state:

```solidity
// Add a storage flag in DoppiOffer / DoppiLiquidity:
bool public usingTWAPFallback;

function refreshPrice() external {
    uint256 chainlinkPrice = getPrice(chainLinkFeed, maxDelay);
    usingTWAPFallback = (chainlinkPrice == 0);
    // ... update cached price
}
```

Operators should monitor `usingTWAPFallback` and alert if it remains `true` across multiple blocks.

---

### H-05 — `_getTotalInterestLiabilities()` Fails Silently, Understating Liabilities

**Contract:** `DoppiLiquidityRouter.sol`  
**Severity:** High  
**Category:** Silent Failure / Logic Error

#### Description

`DoppiLiquidityRouter` calculates maximum LP withdrawal capacity by fetching total interest liabilities from `DoppiCore` via a low-level `staticcall`:

```solidity
function _getTotalInterestLiabilities() internal view returns (uint256 liabilityA, uint256 liabilityB) {
    (bool success, bytes memory data) = doppiCore.staticcall(
        abi.encodeWithSignature("getInterestLiabilities()")
    );
    if (success && data.length == 64) {
        (liabilityA, liabilityB) = abi.decode(data, (uint256, uint256));
    }
    // If staticcall fails: returns (0, 0) — no revert, no event
}
```

If `doppiCore` is not set (address zero), if the call reverts, or if `data.length != 64`, the function silently returns `(0, 0)`. This means **zero liabilities are reported**, so `getWithdrawableAmount` calculates no required reserve:

```solidity
uint256 totalLiability = liabilityBInA + liabilityA;  // = 0 on failure
uint256 requiredReserve = totalLiability * 11000 / 10000; // = 0
```

LPs can withdraw the **full pool balance** even when substantial interest is owed to depositors, directly threatening the ability of `DoppiCore` to pay out interest on settlement.

#### Recommendation

Revert if the liabilities call fails rather than defaulting to zero:

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

### M-01 — Interest Calculation Performs Two Sequential Integer Divisions

**Contract:** `DoppiCore.sol` — `_depositBuy()`, `_depositSell()`  
**Severity:** Medium  
**Category:** Precision Loss

#### Description

Interest is calculated via two sequential integer divisions:

```solidity
uint256 interest = (amount * _buyOffer.apr) / BASIS_POINTS;   // division 1
interest = (interest * duration) / SECONDS_PER_YEAR;          // division 2
```

Each division floors the result. The compounded rounding error is most pronounced for small deposits near `minOrderA` (100 USDT equivalent). For a 1-day position with a 15% APR:

```
amount = 100e18
interest_step1 = (100e18 * 1500) / 10000 = 15e18   (lossless here)
interest_step2 = (15e18 * 86400) / 31536000 ≈ 41095890...  (loses ~890 wei)
```

While the absolute loss per position is small, when aggregated across thousands of positions it represents a systematic, unrecoverable under-payment to depositors.

#### Recommendation

Perform the combined multiplication before any division:

```solidity
uint256 interest = (amount * _buyOffer.apr * duration) / (BASIS_POINTS * SECONDS_PER_YEAR);
```

This eliminates the intermediate rounding step and is safe from overflow given `uint256` can hold `amount * apr * duration` for any realistic parameter range.

---

### M-02 — Profit Ratio Truncation Systematically Shortchanges the LP Pool

**Contract:** `DoppiCore.sol` — `_settleStrike()`, `_settleNoStrike()`  
**Severity:** Medium  
**Category:** Precision Loss / Financial Leakage

#### Description

LP profit attribution on already-traded positions uses integer ratio arithmetic:

```solidity
uint256 ratio = p.amount * 1e18 / swappedAmount;    // truncates
uint256 myamountOut = order.outAmount * ratio / 1e18; // truncates again
if (myamountOut >= p.payout) {
    profitLoss = myamountOut - p.payout;
    _safeTransferWithFee(payoutToken, address(doppiLP), profitLoss);
}
```

Double truncation means the LP receives slightly less profit on every in-the-money settlement. The remaining dust accumulates in the contract with no sweep mechanism. Over many settlements this becomes a material, irreversible accounting leak.

#### Recommendation

Refactor the ratio computation using `Math.mulDiv` (which performs floor-accurate 512-bit multiplication) for the combined expression:

```solidity
uint256 myamountOut = Math.mulDiv(order.outAmount, p.amount, swappedAmount);
```

---

### M-03 — `MIN_BUFFER` / `MAX_BUFFER` Ordering Not Enforced

**Contract:** `DoppiOffer.sol`  
**Severity:** Medium  
**Category:** Input Validation

#### Description

The one-day volatility buffer returned by `getOneDayBuffer` is clamped between `MIN_BUFFER` and `MAX_BUFFER`:

```solidity
onedayVol = onedaybuffer > MAX_BUFFER ? MAX_BUFFER : (onedaybuffer < MIN_BUFFER ? MIN_BUFFER : onedaybuffer);
```

The setter `setBuffer` does not validate that `_min < _max`:

```solidity
function setBuffer(uint256 _min, uint256 _max) external onlyOwner {
    MIN_BUFFER = _min;
    MAX_BUFFER = _max;   // could be < _min
}
```

If `MIN_BUFFER > MAX_BUFFER`, the ternary always returns `MIN_BUFFER`, making the clamp effectively a constant that ignores calculated volatility. Opportunity trading decisions then use a wrong buffer, exposing the LP to incorrect hedging.

#### Recommendation

```solidity
function setBuffer(uint256 _min, uint256 _max) external onlyOwner {
    require(_min < _max, "min must be less than max");
    MIN_BUFFER = _min;
    MAX_BUFFER = _max;
}
```

---

### M-04 — `supportDays` Array Accepts Duplicate Entries

**Contract:** `DoppiCore.sol`  
**Severity:** Medium  
**Category:** Logic Error

#### Description

```solidity
function addSupportDay(uint8 _day) external onlyOwner {
    supportDays.push(_day);  // no duplicate check
}
```

If the same `_day` value (e.g., `1`) is pushed twice, `getReadyAllPositions` will iterate over the same day's positions twice in a single upkeep cycle. This causes:

1. The same position IDs being queued for settlement twice in `tempPositionId`.
2. `_settle_positions` attempting to re-settle already-deleted positions (which have `amount == 0` and will fail partially silently since `delete` was already called).
3. Incorrect `nextProcessId[day]` state from the second iteration.

#### Recommendation

```solidity
function addSupportDay(uint8 _day) external onlyOwner {
    for (uint256 i = 0; i < supportDays.length; i++) {
        require(supportDays[i] != _day, "day already registered");
    }
    supportDays.push(_day);
}
```

---

### M-05 — `getAllOffers()` Uses External `this.` Call Pattern

**Contract:** `DoppiOffer.sol`  
**Severity:** Medium  
**Category:** Gas Cost / External Call Risk

#### Description

```solidity
function getAllOffers(uint8 _numDays) external view
    returns (DualAssetOffer[] memory buyoffers, DualAssetOffer[] memory selloffers)
{
    buyoffers = this.getBuyOffers(_numDays);   // external call to self
    selloffers = this.getSellOffers(_numDays); // external call to self
}
```

Using `this.foo()` triggers an external call with a full CALL opcode rather than an internal jump. This:
1. Costs ~700 additional gas per call.
2. Sends the call through the EVM message-passing mechanism, making it a potential failure point if the contract is in an unusual state.
3. Is semantically unexpected — `view` functions calling `this.` can, in edge cases, interact with proxy patterns or reentrancy guards in unintended ways.

#### Recommendation

Change `this.getBuyOffers` and `this.getSellOffers` to direct internal calls, or inline the loop body:

```solidity
function getAllOffers(uint8 _numDays) external view
    returns (DualAssetOffer[] memory buyoffers, DualAssetOffer[] memory selloffers)
{
    uint256 price = DALiquidityLib.getPriceWithFallback(chainLinkFeed, pancakeV3Pool, twapDuration, maxDelay);
    buyoffers = new DualAssetOffer[](TOTAL_OFFER);
    selloffers = new DualAssetOffer[](TOTAL_OFFER);
    for (uint8 i = 0; i < TOTAL_OFFER; ) {
        buyoffers[i] = _getOffer(true, _numDays, i, price);
        selloffers[i] = _getOffer(false, _numDays, i, price);
        unchecked { ++i; }
    }
}
```

---

## 9. Low Findings

---

### L-01 — Commented-Out Debug Imports Left in Production Files

**Contract:** `DoppiCore.sol`, `DoppiLiquidity.sol`, `DoppiOffer.sol`, `DoppiReferral.sol`, `DoppiTrader.sol`, `DoppiLiquidityRouter.sol`, `DoppiUpkeepManager.sol` (active), others  
**Severity:** Low  
**Category:** Code Quality

Multiple files contain:
```solidity
// import "forge-std/console.sol";
```
While these are harmless when commented out, their presence indicates incomplete cleanup. One instance in `DoppiUpkeepManager` is uncommented (addressed in C-01). All such lines should be removed to ensure production readiness.

---

### L-02 — Inconsistent Solidity Pragma Versions

**Severity:** Low

| Contract | Pragma |
|---|---|
| `DoppiCore`, `DoppiLiquidity`, `DoppiTrader` | `^0.8.26` |
| `DoppiOffer`, `BlackScholes` | `^0.8.20` |
| `DoppiUpkeepManager` | `^0.8.19` |

Cross-pragma version imports can introduce subtle bugs if the compiler resolves a version that satisfies all constraints but has known bugs in the intermediate range. **Recommendation:** Standardise all contracts to `^0.8.26`.

---

### L-03 — SPDX License Identifier Inconsistency

**Severity:** Low

`DoppiLiquidity`, `DoppiTrader`, `DoppiLiquidityRouter`, and `DoppiOpportunity` declare `SPDX-License-Identifier: UNLICENSED`, while core protocol contracts declare `MIT`. If the protocol is intended to be open-source, all files should declare `MIT`. If proprietary, all should be `UNLICENSED`. Mixed declarations create ambiguity for integrators.

---

### L-04 — Hardcoded USDT Address in Oracle Library

**Contract:** `DALiquidityLib.sol` — `getPancakePrice()`  
**Severity:** Low

```solidity
address usdt = address(0x55d398326f99059fF775485246999027B3197955);
```

This hard-codes a mainnet BSC address directly in library logic, making the library non-portable and fragile to USDT contract migrations. **Recommendation:** Pass the USDT address as a parameter or store it in the calling contract's configuration.

---

### L-05 — Missing Events for Critical Admin Parameter Changes

**Contracts:** `DoppiCoreAdmin.sol`, `DoppiOffer.sol`  
**Severity:** Low

The following setters modify security-critical parameters without emitting events, making off-chain monitoring and audit trails incomplete:

| Function | Missing Event |
|---|---|
| `setTreasury` | `TreasuryUpdated(address, uint24)` |
| `setAPRTolerance` | `APRToleranceUpdated(uint16)` |
| `setRegression` | `RegressionUpdated(uint256, ...)` |
| `setForwarderAddress` | `ForwarderUpdated(address)` |
| `setOpportunityBot` | `OpportunityBotUpdated(address, bool)` |

---

### L-06 — `priceDecimal` Cached at Construction, Never Refreshed

**Contract:** `DoppiCore.sol`  
**Severity:** Low

```solidity
constructor(...) {
    priceDecimal = 10 ** _doppiLP.getPriceDecimals();  // cached once
}
```

`priceDecimal` is used throughout deposit and settlement arithmetic. If `DoppiLiquidity`'s oracle feed is ever replaced with a feed of different decimal precision, `DoppiCore` will continue to use the stale multiplier, causing systematic pricing errors. **Recommendation:** Expose a `refreshPriceDecimal()` owner function that re-reads from `doppiLP.getPriceDecimals()`.

---

## 10. Informational Findings

### I-01 — `DoppiTrader.initialize()` Has Redundant Initialization Guard

The contract uses both OpenZeppelin's `initializer` modifier **and** a manual `initialized` boolean:

```solidity
bool private initialized;

function initialize(...) external initializer {
    if (initialized) revert AlreadyInitialized();  // redundant
    initialized = true;
    ...
}
```

The `initializer` modifier from OpenZeppelin already enforces single-call semantics via its own storage slot. The manual guard is redundant. **Recommendation:** Remove the manual `initialized` flag.

### I-02 — Referral Tree Has No Cycle Detection

`DoppiReferral.registerReferrer` prevents a user from self-referring and from registering if they already have direct referees:

```solidity
require(directReferees[msg.sender].length == 0, "cannot register upline");
```

However, if a referral cycle is created through collaboration (e.g., A registers B, B registers C, C attempts to register A), the third `require` would catch it only if C already has referees. In the specific case where A, B, C are fresh accounts, the cycle can be created. While this has no direct financial exploit in the current reward model (rewards are point-volume-based, not recursive), it is noted for completeness.

### I-03 — `DoppiUpkeepManager.sol` Uses `Ownable` from OpenZeppelin 0.8.19 Pragma

The contract inherits `Ownable` at pragma `^0.8.19` but other contracts use the OpenZeppelin version from the `openzeppelin-contracts` library pinned at `^0.8.26`. This inconsistency may cause compilation warnings or unexpected selector conflicts if the library is compiled at a mixed version boundary.

---

## 11. Positive Security Observations

The following security-conscious implementations were noted and are commended:

| Pattern | Where Applied |
|---|---|
| `ReentrancyGuard` on all state-modifying public functions | `DoppiCore`, `DoppiLiquidity`, `DoppiTrader`, `DoppiLiquidityRouter` |
| `SafeERC20` for all token transfers (no unchecked transfer returns) | All contracts |
| `Pausable` with `emergencyMode` circuit breakers for principal recovery | `DoppiCore`, `DoppiLiquidityRouter` |
| `immutable` asset addresses preventing post-deployment token swaps | `DoppiCore`, `DoppiLiquidity` |
| Chainlink `answeredInRound < roundId` check that catches incomplete rounds | `DALiquidityLib.getPrice()` |
| `try/catch` pattern on trader-bot unwind to prevent cascade failure | `DoppiCore._createTraderBotUnwindPosition()` |
| Interest liability tracked with underflow-safe subtraction | `DoppiCore._removeInterestLiability()` |
| Custom error types rather than string reverts (gas efficient) | `DoppiCore` |
| `initializer` modifier on proxy bot to prevent re-initialization | `DoppiTrader` |
| Separate buy/sell position mappings keyed by day, preventing cross-term contamination | `DoppiCore` |

---

## 12. Appendix — Contract Inventory

### Inheritance Graph

```
DoppiCore
  └── DoppiCoreAdmin (Ownable, Pausable)
  └── DoppiCoreView
  └── ReentrancyGuard
  └── AutomationCompatibleInterface

DoppiLiquidity
  └── ERC20
  └── Ownable
  └── Pausable
  └── IDoppiLiquidity
  └── AutomationCompatibleInterface
  └── ReentrancyGuard

DoppiLiquidityRouter
  └── Ownable
  └── Pausable
  └── ReentrancyGuard

DoppiTrader
  └── DoppiTraderAdminView (Ownable)
  └── ReentrancyGuard
  └── AutomationCompatibleInterface
  └── Initializable

DoppiOffer
  └── IDoppiOffer
  └── Ownable

DoppiReferral
  └── Ownable

DoppiUpkeepManager
  └── Ownable
```

### External Dependencies

| Dependency | Version Pinned | Usage |
|---|---|---|
| OpenZeppelin Contracts | `v5.x` | Access control, token standards, utilities |
| Chainlink Automation | `v2` | `AutomationCompatibleInterface`, `IAutomationRegistrar` |
| Uniswap V3 Core | `v1` | `IUniswapV3Pool`, `TickMath` |
| Uniswap V3 Periphery | `v1` | `IQuoterV2`, `ISwapRouter` |
| forge-std | `v1.x` | **Must be removed from production** (see C-01) |

### Token Flow Summary

```
User (assetA / assetB)
    → [deposit]  → DoppiCore (holds principal)
    ← [settle]   ← DoppiCore (returns principal + interest - fee)
                              ↓
                         Treasury (fee)

DoppiCore ← [interestGet] → DoppiLiquidity
DoppiLiquidity ← [deposit / redeem] → DoppiLiquidityRouter ← LP providers
```

---

*This report was prepared for internal review purposes. No warranty is given as to the completeness of findings; additional vulnerabilities may exist. A formal third-party audit is strongly recommended before mainnet deployment.*
