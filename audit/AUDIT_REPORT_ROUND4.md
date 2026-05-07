# Doppi Protocol — Security Review Round 4
## Reward, Incentive & Automation Subsystem: DoppiOpportunity · DoppiReferral · DoppiPoints · DoppiClaim · DoppiUpkeepManager

---

|                          |                                                                    |
|--------------------------|--------------------------------------------------------------------|  
| **Project**              | Doppi Protocol                                                     |
| **Scope**                | `DoppiOpportunity.sol` · `DoppiReferral.sol` · `DoppiPoints.sol` · `DoppiClaim.sol` · `DoppiUpkeepManager.sol` |
| **Auditor**              | Internal Security Review                                           |
| **Previous Reports**     | `AUDIT_REPORT_FINAL.md` (rounds 1–3)                              |
| **Status**               | Draft — Pending Developer Response                                 |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Scope & Contract Summary](#2-scope--contract-summary)
3. [Findings Summary](#3-findings-summary)
4. [Medium Findings](#4-medium-findings)
5. [Low Findings](#5-low-findings)
6. [Informational Findings](#6-informational-findings)
7. [Positive Security Observations](#7-positive-security-observations)
8. [Recommended Remediations](#8-recommended-remediations)

---

## 1. Executive Summary

This fourth review covers the reward, incentive, and automation subsystem: `DoppiOpportunity`, `DoppiReferral`, `DoppiPoints`, `DoppiClaim`, and `DoppiUpkeepManager` (Chainlink Automation fee manager / LINK swap escrow).

No Critical or High findings were identified. Since the initial Round 4 review, the developer has fully fixed **R-01**, **R-02**, **R-03**, **R-04**, **R-05**, **U-01**, **U-04**, **U-05**, and **U-06**, and partially addressed **U-02** and **U-03**. Remaining security-relevant issues are now low severity.

**Current Risk for this subsystem: LOW**

| Severity      | Count  | Status                    |
|---------------|--------|---------------------------|
| Critical      | 0      | —                         |
| High          | 0      | —                         |
| Medium        | 3      | 3 fixed, 0 open           |
| Low           | 10     | 6 fixed, 2 partial, 2 open |
| Informational | 3      | ❌ Open                   |
| **Total**     | **16** | 9 fixed, 2 partial, 5 open |

---

## 2. Scope & Contract Summary

### `DoppiClaim.sol`

Single-purpose minting gateway. Reads accrued points from `DoppiPoints` and accrued referral volume from `DoppiReferral`, mints the protocol token proportionally, and resets the user's state. Protected by `nonReentrant` and `whenNotPaused`.

### `DoppiReferral.sol`

Multi-level (L1/L2/L3) referral tracking. Users register a unique `bytes32` code once and invite others. Volume is aggregated monthly in `DoppiPoints`. Reward computation iterates over unclaimed months and applies minimum-volume gates for L2/L3. State reset is gated to `onlyDoppiClaim`.

### `DoppiPoints.sol`

Monthly trading-volume ledger. `recordTrade` is callable only by registered `DoppiCore` instances. Attributes volume to the actual human trader (resolving TraderBot proxies via `DoppiTraderFactory`). Caches the referral upline chain at record time. Reset is gated to `onlyDoppiClaim`.

### `DoppiOpportunity.sol`

Chainlink Automation upkeep that drives `DoppiCore.performOpportunity`. `checkUpkeep` performs a lightweight existence check, while `performUpkeep` re-computes current hedge targets at execution time and only then calls `DoppiCore.performOpportunity`. Access gated by `onlyForwarder`.

### `DoppiUpkeepManager.sol`

Chainlink Automation fee manager and LINK swap escrow. Handles upkeep registration, periodic LINK top-up, and fee charging in `fundToken` (USDT). Swaps `fundToken` → LINK via PancakeSwap V3 multi-hop and bridges ERC20 LINK to ERC677 LINK via `IPegSwap`. Access gated by `onlyOwner` (admin), `onlyTrader` (per-upkeep trader), and `onlyForwarder` (Chainlink node).

---

| ID   | Title                                                                              | Contract              | Severity   | Status  |
|------|------------------------------------------------------------------------------------|-----------------------|------------|---------|
| R-01 | Points burned for zero tokens when `tokensPerPoint` rounds or is set to zero      | `DoppiClaim`          | Medium     | ✅ Fixed |
| R-02 | `performUpkeep` executes stale hedge targets without re-validating current price   | `DoppiOpportunity`    | Medium     | ✅ Fixed |
| U-01 | `performTopUpkeep` accepts unvalidated `TopUpInfo` — caller can inflate fee drain  | `DoppiUpkeepManager`  | Medium     | ✅ Fixed |
| R-03 | `resetClaims` uses `this.getTotalReferralRewards` external self-call               | `DoppiReferral`       | Low        | ✅ Fixed |
| R-04 | `resetPoint` uses `this.getAllPointData` external self-call                        | `DoppiPoints`         | Low        | ✅ Fixed |
| R-05 | `setForwarderAddress` accepts zero address, permanently locking `performUpkeep`    | `DoppiOpportunity`    | Low        | ✅ Fixed |
| R-06 | `getTotalReferralRewards` unbounded month loop — future OOG risk                   | `DoppiReferral`       | Low        | ❌ Open |
| R-07 | `registerReferralCode` susceptible to front-running grief                          | `DoppiReferral`       | Low        | ❌ Open |
| U-02 | Multiple bare `transfer`/`transferFrom` calls bypass `SafeERC20`                  | `DoppiUpkeepManager`  | Low        | ⚠️ Partial |
| U-03 | `setTresury` missing zero-address guard (and typo in function name)                | `DoppiUpkeepManager`  | Low        | ⚠️ Partial |
| U-04 | `_getUnPaidDoppiFee` uses `this.getUpkeep` external self-call                     | `DoppiUpkeepManager`  | Low        | ✅ Fixed |
| U-05 | `setDoppiBotFee` has no upper-bound — fee > linkAmount causes `fundUpkeep` DoS    | `DoppiUpkeepManager`  | Low        | ✅ Fixed |
| U-06 | `setSlippage` has no upper-bound — high value weakens swap sandwich protection     | `DoppiUpkeepManager`  | Low        | ✅ Fixed |
| I-01 | `doppiReferral` zero at trade time silently skips referral volume recording        | `DoppiPoints`         | Info       | ❌ Open |
| I-02 | `setRates` allows total referral BP sum up to 100%                                 | `DoppiReferral`       | Info       | ❌ Open |
| U-07 | Constructor grants `type(uint256).max` approvals to immutable `router` and `pegSwap` | `DoppiUpkeepManager` | Info      | ❌ Open |

---

## 4. Medium Findings

---

### R-01 — Points Burned for Zero Tokens When `tokensPerPoint` Rounds to Zero

**Contract:** `DoppiClaim.sol` · **Severity:** Medium · **Status:** ✅ Fixed

#### Fix Applied

The claim paths now enforce non-zero mint output before state reset, and `setTokensPerPoint` rejects zero rates:

```solidity
require(mintAmount > 0, "mint amount too small");
require(_tokensPerPoint > 0, "invalid rate");
```

Additionally, `tokensPerPoint` changes are now scheduled to become effective from the next month (`currentMonthId + 1`), and claim conversion is computed month-by-month using historical rate checkpoints. This prevents retroactive repricing of already-earned points.

---

### R-02 — `performUpkeep` Executes Stale Hedge Targets Without Re-Validating Current Market Conditions

**Contract:** `DoppiOpportunity.sol` · **Severity:** Medium · **Status:** ✅ Fixed

#### Original Finding

The original implementation encoded hedge targets and amounts into `performData` during `checkUpkeep`, then decoded and executed those values later in `performUpkeep`. That created a stale-data window between check and execution.

#### Fix Applied

The implementation now performs only a lightweight existence check in `checkUpkeep`, and re-computes the actual target arrays and amounts inside `performUpkeep` using the current LP price:

```solidity
function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
    if(paused()) return (false, bytes(""));

    uint256 price = doppiLP.getPrice();
    (uint256[] memory targetPrices, uint256[] memory targetPricesUnwind, ,) = doppiCore.checkOpportunity(price, true);
    (uint256[] memory targetPricesSell, uint256[] memory targetPricesSellUnwind, ,) = doppiCore.checkOpportunity(price, false);

    upkeepNeeded = (targetPrices.length > 0 || targetPricesUnwind.length > 0 || targetPricesSell.length > 0 || targetPricesSellUnwind.length > 0);
    if (upkeepNeeded) {
        return (true, bytes(""));
    }
    return (upkeepNeeded, bytes(""));
}

function performUpkeep(bytes calldata performData) external override onlyForwarder {
    if(paused()) return;
    uint256 price = doppiLP.getPrice();
    (...) = doppiCore.checkOpportunity(price, true);
    (...) = doppiCore.checkOpportunity(price, false);
    ...
}
```

This is stronger than the original recommendation because it eliminates stale `performData` entirely rather than merely rejecting it when price drift exceeds a threshold.

---

### U-01 — `performTopUpkeep` Accepts Unvalidated `TopUpInfo` — Caller Can Inflate Fee Drain

**Contract:** `DoppiUpkeepManager.sol` → `performTopUpkeep()` · **Severity:** Medium · **Status:** ✅ Fixed

#### Original Finding

The original function accepted a caller-supplied `TopUpInfo` struct and trusted its fee and amount split, allowing a compromised trader bot to manipulate how much `fundToken` was sent to treasury versus actually swapped into LINK.

#### Fix Applied

The external interface now removes the caller-supplied `TopUpInfo` argument entirely. `performTopUpkeep` derives the current top-up parameters on-chain via `_getTopUpInfo(upkeepId)` and requires that a top-up is currently needed:

```solidity
function performTopUpkeep(uint256 upkeepId) external validUpkeepId(upkeepId) {
    require(doppiTraderFactory.isTraderBot(msg.sender), "only traderbot can call");
    (TopUpInfo memory topUpInfo, bool needTopUp) = _getTopUpInfo(upkeepId);

    require(needTopUp == true, "no need to top up");
    uint256 bal = fundToken.balanceOf(address(this));
    require(bal >= topUpInfo.totalInfundToken, "balance not enough");

    uint256 linkOut = _swapToLinkERC677(topUpInfo.topUpAmountInfundToken);
    _fundUpkeep(upkeepId, uint96(linkOut));
    fundToken.safeTransfer(treasury, topUpInfo.feeInfundToken);
    ...
}
```

`DoppiTrader` and `IDoppiUpkeepManager` were updated consistently so the top-up data is no longer passed through `performData` or supplied by the caller.

---

## 5. Low Findings

---

### R-03 — `resetClaims` Uses `this.getTotalReferralRewards` External Self-Call

**Contract:** `DoppiReferral.sol` → `resetClaims()` · **Severity:** Low · **Status:** ✅ Fixed

#### Fix Applied

`resetClaims` now calls the internal helper directly:

```solidity
(uint256 totalL1, uint256 totalL2, uint256 totalL3, , , ) = _getTotalReferralRewards(referrer);
```

This removes the unnecessary external self-call path.

---

### R-04 — `resetPoint` Uses `this.getAllPointData` External Self-Call

**Contract:** `DoppiPoints.sol` → `resetPoint()` · **Severity:** Low · **Status:** ✅ Fixed

#### Fix Applied

`resetPoint` now calls the internal helper directly:

```solidity
(,uint256 readyPoint, ) = _getAllPointData(trader);
```

This removes the self-call overhead and failure propagation path.

---

### R-05 — `setForwarderAddress` Accepts Zero Address

**Contract:** `DoppiOpportunity.sol` · **Severity:** Low · **Status:** ✅ Fixed

#### Original Finding

```solidity
function setForwarderAddress(address forwarderAddress) external onlyOwner {
    s_forwarderAddress = forwarderAddress; // no zero-address check
}
```

The `onlyForwarder` modifier requires `msg.sender == s_forwarderAddress`. If the owner accidentally sets `s_forwarderAddress = address(0)`, `performUpkeep` becomes permanently inaccessible (no address can equal `address(0)` as `msg.sender`). LP rebalancing halts indefinitely.

The same vulnerability was identified and noted in `DoppiCoreAdmin.setForwarderAddress` (L-05 in main report). `DoppiOpportunity` has its own independent forwarder address with the same issue.

#### Fix Applied

```solidity
function setForwarderAddress(address forwarderAddress) external onlyOwner {
    require(forwarderAddress != address(0), "zero forwarder");
    s_forwarderAddress = forwarderAddress;
}
```

---

### R-06 — `getTotalReferralRewards` Unbounded Month Loop — Future OOG Risk

**Contract:** `DoppiReferral.sol` · **Severity:** Low · **Status:** ❌ Open

#### Description

```solidity
for (uint24 monthId = startMonthId; monthId <= endMonthId; monthId++) {
    (uint256 l1v, uint256 l2v, uint256 l3v) = doppiPoints.getReferralVolumeByMonth(trader, monthId);
    ...
}
```

The loop iterates over every unclaimed month, so a user who has not claimed for a long period causes on-chain iteration proportional to the number of elapsed months.

At 30-day months, the loop is bounded to ~12 iterations per year. After ~8–10 years of non-claiming, a single `claimReferralPoint` call could consume enough gas to fail or approach block limits — permanently locking that user's referral rewards.

While not an immediate concern, it should be addressed before the protocol runs for extended periods or before protocol-managed accounts (e.g., team wallets) accumulate many months of idle rewards.

#### Recommendation

Add a `maxMonths` parameter to `resetClaims` allowing partial batch claiming:

```solidity
function resetClaims(address referrer, uint24 maxMonths) external onlyDoppiClaim {
    ...
    uint24 endMonthId = uint24(Math.min(startMonthId + maxMonths - 1, currentMonthId - 1));
    for (uint24 monthId = startMonthId; monthId <= endMonthId; monthId++) { ... }
    ref.claimedMonthId = endMonthId;
}
```

`DoppiClaim.claimReferralPoint` would then call this in a loop until all months are claimed, or the UI handles batching off-chain.

---

### R-07 — `registerReferralCode` Susceptible to Front-Running Grief

**Contract:** `DoppiReferral.sol` · **Severity:** Low · **Status:** ❌ Open

#### Description

```solidity
function registerReferralCode(bytes32 code) external {
    require(code != bytes32(0), "invalid code");
    require(referralCodeToAddress[code] == address(0), "code already used");
    require(addressToReferralCode[msg.sender] == bytes32(0), "already registered");
    referralCodeToAddress[code] = msg.sender;
    ...
}
```

A user generates their desired referral code off-chain (e.g., `keccak256("ALICE_INVITE")`) and broadcasts the transaction. An attacker watches the mempool, extracts the `code` value, and front-runs with a higher gas fee to register the same code for themselves. The original user's transaction reverts with "code already used".

**Impact**: Grief attack only — the user can simply choose a different code. No funds are at risk. Moderate nuisance on congested networks or during promotional periods when specific vanity codes are desirable.

#### Recommendation

Use a commit-reveal scheme for code registration, or accept the operational risk given that code collisions are a minor UX inconvenience rather than a security issue. A simpler mitigation: allow users to register codes whose hash matches `keccak256(abi.encodePacked(msg.sender, salt))`, ensuring only the intended address can claim their own codes.

---

### U-02 — Multiple Bare `transfer`/`transferFrom` Calls Bypass `SafeERC20`

**Contract:** `DoppiUpkeepManager.sol` · **Severity:** Low · **Status:** ⚠️ Partially Fixed

#### Current State

Most of the originally identified bare transfers have been corrected:

- `fundUpkeep` now uses `fundToken.safeTransferFrom(...)`
- `fundUpkeep` now uses `IERC20(address(linkToken)).safeTransfer(...)`
- `performTopUpkeep` now uses `fundToken.safeTransfer(...)`
- `stopWithdraw` now uses `fundToken.safeTransfer(...)` for the trader refund

One unchecked raw transfer remains in `stopWithdraw`:

```solidity
if(finalBal >= fee) linkToken.transfer(treasury, fee);
```

That remaining call still bypasses `SafeERC20` and ignores the return value.

#### Recommendation

Replace the final remaining raw LINK transfer as well:

```solidity
if(finalBal >= fee) IERC20(address(linkToken)).safeTransfer(treasury, fee);
```

---

### U-03 — `setTresury` Missing Zero-Address Guard (and Typo)

**Contract:** `DoppiUpkeepManager.sol` · **Severity:** Low · **Status:** ⚠️ Partially Fixed

#### Current State

The security-relevant part of the finding is fixed. The setter now rejects the zero address:

```solidity
function setTresury(address _treasury) external onlyOwner {
    require(_treasury != address(0), "zero treasury");
    treasury = _treasury;
}
```

The function name typo remains (`setTresury` instead of `setTreasury`). That is now a naming / integration clarity issue rather than a material security issue.

#### Recommendation

Optional cleanup only: rename the function to `setTreasury` for consistency across the codebase and deployment tooling.

---

### U-04 — `_getUnPaidDoppiFee` Uses `this.getUpkeep` External Self-Call

**Contract:** `DoppiUpkeepManager.sol` · **Severity:** Low · **Status:** ✅ Fixed

#### Fix Applied

`_getUnPaidDoppiFee` now calls the registry directly:

```solidity
function _getUnPaidDoppiFee(uint256 _upkeepId) internal view returns (uint96 fee, address trader) {
    IAutomationRegistryConsumer.UpkeepInfo memory result = registryConsumer.getUpkeep(_upkeepId);
    ...
}
```

This removes the unnecessary external self-call path.

---

### U-05 — `setDoppiBotFee` No Upper-Bound — Fee Overflow Causes `fundUpkeep` DoS

**Contract:** `DoppiUpkeepManager.sol` · **Severity:** Low · **Status:** ✅ Fixed

#### Fix Applied

The setter now enforces an upper bound:

```solidity
function setDoppiBotFee(uint24 _doppiBotFee) external onlyOwner {
    require(_doppiBotFee <= 3000, "fee exceeds 30%");
    doppiBotFee = _doppiBotFee;
}
```

This removes the original permanent-misconfiguration case where `doppiBotFee > 10000` could make every manual top-up revert.

---

### U-06 — `setSlippage` No Upper-Bound — High Value Weakens Sandwich Protection

**Contract:** `DoppiUpkeepManager.sol` · **Severity:** Low · **Status:** ✅ Fixed

#### Fix Applied

An explicit maximum slippage cap is now enforced:

```solidity
uint24 public constant MAX_SLIPPAGE = 500;  // 5%

function setSlippage(uint24 _slippage) external onlyOwner {
    require(_slippage <= MAX_SLIPPAGE, "slippage too high");
    slippage = _slippage;
}
```

This removes the high-slippage misconfiguration path.

---

## 6. Informational Findings

---

### I-01 — `doppiReferral` Zero at Trade Time Silently Drops Referral Volume

**Contract:** `DoppiPoints.sol` → `recordTrade()` · **Severity:** Informational

#### Description

```solidity
if (address(doppiReferral) != address(0)) {
    (address l1, address l2, address l3) = doppiReferral.getUplineChain(actualTrader);
    ...
}
```

If `setDoppiReferral` is called after users have already begun trading, all trade volume recorded before the `doppiReferral` address was configured is permanently lost from the referral ledger. Referrers who referred those traders earn nothing for that historical period. There is no backfill mechanism.

**Recommendation**: Ensure `doppiReferral` is set before any `DoppiCore` is registered in `setDoppiCore`. Document this operational dependency in deployment scripts.

---

### U-07 — Constructor Grants `type(uint256).max` Approvals to Immutable `router` and `pegSwap`

**Contract:** `DoppiUpkeepManager.sol` · **Severity:** Informational

#### Description

```solidity
IERC20(fundToken).approve(router, type(uint256).max);
IERC20(link).approve(address(pegSwap), type(uint256).max);
linkToken.approve(address(pegSwap), type(uint256).max);
link.approve(address(router), type(uint256).max);
```

Both `router` and `pegSwap` are `immutable` — they can never be changed after deployment. If either contract is compromised or contains a bug, the unlimited approval can never be revoked. All `fundToken`, `link`, and `linkToken` held by `DoppiUpkeepManager` are permanently at risk from those two addresses.

This is commonly accepted in production DeFi (e.g., approving Uniswap router once), but the risk is worth documenting. Consider adding an `revokeApproval(address token, address spender)` owner function as an emergency escape hatch.

---

### I-02 — `setRates` Allows Total Referral BP Up to 100%

**Contract:** `DoppiReferral.sol` · **Severity:** Informational

#### Description

```solidity
function setRates(uint16 _level1Bps, uint16 _level2Bps, uint16 _level3Bps) external onlyOwner {
    require(_level1Bps + _level2Bps + _level3Bps <= BP_DENOMINATOR, "bps sum too large");
    ...
}
```

`BP_DENOMINATOR = 10000`. The guard permits a combined referral rate of up to 100% of trade volume. At 100%, the referral system mints tokens equal to the full trade volume for every trade, regardless of protocol fee revenue. Since minting is unbounded by any treasury balance (tokens are minted, not transferred from reserves), very high rates inflate the token supply rapidly.

**Recommendation**: Consider capping the combined BP sum at a business-aligned maximum (e.g., 500 bps = 5% total) to give the owner meaningful range while preventing catastrophic misconfiguration:

```solidity
uint16 public constant MAX_TOTAL_REWARD_BP = 500;

function setRates(...) external onlyOwner {
    require(_level1Bps + _level2Bps + _level3Bps <= MAX_TOTAL_REWARD_BP, "exceeds max reward rate");
    ...
}
```

---

## 7. Positive Security Observations

| Pattern                                                                            | Assessment              |
|------------------------------------------------------------------------------------|-------------------------|
| `nonReentrant` on all state-modifying claim functions in `DoppiClaim`              | ✅ Correct              |
| `onlyDoppiClaim` guards on `resetPoint` and `resetClaims`                          | ✅ Correct              |
| `onlyDoppiCore` guard on `DoppiPoints.recordTrade` (mapping-based, supports multi-core) | ✅ Correct         |
| `refereeToReferrer` is immutable after first set — prevents upline switching        | ✅ Correct              |
| Circular referral prevention: `directReferees[msg.sender].length == 0` guard       | ✅ Correct              |
| Self-referral prevention: `require(referrer != msg.sender)`                        | ✅ Correct              |
| Bot proxy resolution in `_getActualTrader` — volume attributed to human, not clone | ✅ Correct              |
| Month boundary protection: `require(currentMonthId > ref.claimedMonthId + 1)`     | ✅ Correct              |
| Double-claim protection: `claimedMonthId` reset after each claim                   | ✅ Correct              |
| `onlyForwarder` restricts `performUpkeep` to registered Chainlink node             | ✅ Correct              |
| `maxSwap` cap enforced during `checkOpportunity` — bounds per-execution exposure   | ✅ Correct              |
| `_getActualTrader` gracefully falls back to `positionOwner` if factory not set     | ✅ Correct              |
| `require(_l1Bps + _l2Bps + _l3Bps <= BP_DENOMINATOR)` constructor guard           | ✅ Correct              |
| `DoppiClaim` constructor validates all three dependency addresses non-zero         | ✅ Correct              |
| `onlyTrader` and `validUpkeepId` modifiers guard all trader-facing upkeep functions | ✅ Correct            |
| Oracle price zero-guard (`require(price > 0)`) in `_swapToLinkERC677` / `_swapERC677ToFundToken` | ✅ Correct |
| `setForwarderAddress` zero-address guard in `DoppiUpkeepManager`                   | ✅ Correct              |
| `require(amountOutMinimum > 0)` prevents zero-output swaps in all swap helpers     | ✅ Correct              |
| `require(linkOut > 0)` / `require(fundTokenOut > 0)` validate swap outputs         | ✅ Correct              |

---

## 8. Recommended Remediations

Listed in priority order.

### Tier 1 — Fix Before Mainnet

No Tier 1 items remain.

### Tier 2 — Strongly Recommended

| ID    | Action                                                                                                                           |
|-------|----------------------------------------------------------------------------------------------------------------------------------|
| **U-02** | Replace the remaining raw `linkToken.transfer(treasury, fee)` in `stopWithdraw` with a `SafeERC20` transfer.             |
| **U-03** | Optional cleanup: rename `setTresury` to `setTreasury` for consistency with scripts and tooling.                           |
| **R-06** | Add `maxMonths` parameter to `resetClaims` to allow partial batch claiming and prevent future OOG.                           |

### Tier 3 — Nice to Have

| ID    | Action                                                                                                    |
|-------|-----------------------------------------------------------------------------------------------------------|
| **R-07** | Document referral code front-running as a known UX risk; optionally implement commit-reveal.           |
| **I-01** | Enforce deployment ordering: `doppiReferral` must be set before `DoppiCore` registration.              |
| **I-02** | Consider capping combined referral BP at a business-aligned maximum (e.g., 500 bps).                   |
| **U-07** | Add `revokeApproval(address token, address spender)` owner function as emergency escape hatch.        |

---

*This document covers Round 4 of the Doppi Protocol internal security review. It is intended to be read alongside `AUDIT_REPORT_FINAL.md` which supersedes rounds 1–3. A formal third-party audit covering all four rounds is strongly recommended before mainnet deployment.*
