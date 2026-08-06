# Doppi Smart Contract Security Audit Report (Rounds 5 & 6)

# Doppi Protocol Security Audit (Round 5)

Date: 2026-08-06  
Auditor: Internal Smart Contract Security Review  
Focus: Fund drain risk, overflow/underflow risk, and withdrawal lock scenarios

---

## 1. Scope Reviewed

Primary contracts requested:
- src/mainnet/DoppiLiquidityRouter.sol
- src/mainnet/DoppiLiquidity.sol
- src/mainnet/DoppiCore.sol
- src/mainnet/DoppiOpportunity.sol
- src/mainnet/DoppiTrader.sol
- src/mainnet/private/DoppiGridTrader.sol
- src/mainnet/private/DoppiSimpleTrader.sol
- src/mainnet/private/PrivateAutomationHub.sol
- src/mainnet/private/PrivateDoppiGridTraderFactory.sol
- src/mainnet/private/PrivateDoppiSimpleTraderFactory.sol

Related contracts reviewed for dependency paths:
- src/mainnet/DoppiTraderAdminView.sol
- src/mainnet/DoppiCoreView.sol
- src/mainnet/DoppiCoreAdmin.sol
- src/mainnet/ERC7575.sol

---

## 2. Executive Summary

No direct, permissionless fund-drain vulnerability was found in this review scope.

However, this round identified five material risks that can block exits, settlement, bot shutdown, or bot automation under specific conditions:

1) a fee-hook hard revert path that can block trader stop/withdraw flows;  
2) a private automation billing precondition mismatch that can revert upkeep execution;  
3) a price-zero division path that can block emergency LP exits;  
4) uint8 loop-counter overflow risk on unbounded support-day arrays leading to processing DoS;  
5) private factory config-validation gaps that can brick new bot deployments.

These are operationally significant because they can lock funds until governance/owner intervention.

---

## 3. Findings (ordered by severity)

### R5-H01: Fee hook hard-revert can block bot stop and fund withdrawal
Severity: High  
Status: Fixed

Affected code:
- src/mainnet/private/DoppiGridTrader.sol:139
- src/mainnet/private/DoppiGridTrader.sol:142
- src/mainnet/private/DoppiSimpleTrader.sol:129
- src/mainnet/private/DoppiSimpleTrader.sol:132
- src/mainnet/DoppiTraderAdminView.sol:390
- src/mainnet/DoppiTraderAdminView.sol:395
- src/mainnet/DoppiTraderAdminView.sol:403

Description:
- Both private bot stop flows call `_payStopProfitFees()` before returning balances.
- `_payStopProfitFees()` calls `_payFeeAmount()`.
- `_payFeeAmount()` executes `feePool.call(onFeeReceived(...))` and reverts on failure.

Impact:
- If `feePool` is misconfigured, paused, upgraded incorrectly, or intentionally reverts in `onFeeReceived`, `stop()` can revert.
- Reverting `stop()` prevents trader from finalizing shutdown and withdrawing balances in a normal flow.
- This is a withdrawal-lock risk, not a direct theft vector.

Recommendation:
- Make fee notification best-effort in trader paths, matching the safer behavior already used in `DoppiCore`.
- Option A: keep token transfer, ignore notify failure.
- Option B: queue fee accounting locally and let fee pool pull/claim.
- Add explicit tests for: failing feePool hook, stop() should still succeed.

Validation note:
- Fixed in `DoppiTraderAdminView._payFeeAmount` by removing the hard revert when `onFeeReceived` hook fails; fee transfer proceeds without blocking stop flow.

---

### R5-H02: PrivateAutomationHub billing precondition mismatch can revert upkeep execution
Severity: High  
Status: Fixed

Affected code:
- src/mainnet/private/PrivateAutomationHub.sol:150
- src/mainnet/private/PrivateAutomationHub.sol:206
- src/mainnet/private/PrivateAutomationHub.sol:509
- src/mainnet/private/PrivateAutomationHub.sol:556
- src/mainnet/private/PrivateAutomationHub.sol:594
- src/mainnet/private/PrivateAutomationHub.sol:663
- src/mainnet/private/PrivateAutomationHub.sol:664
- src/Library/DALiquidityLib.sol:28

Description:
- Billing preconditions are now enforced before execution: upkeep eligibility returns false when `chainlinkFeed`, `fundToken`, or `treasury` are unset.
- Owner can now clear and replace `chainlinkFeed` via admin setter; while feed is zero or price is zero, jobs do not execute.
- `_chargeGasFee()` now has the same prerequisite guard, preventing fee-transfer reverts from partial billing configuration.

Impact:
- Misconfiguration no longer causes upkeep transaction reverts in billing paths.
- When feed/config is missing, jobs are intentionally skipped/paused until owner intervention restores valid billing configuration.

Recommendation:
- Keep operational runbook: if `chainlinkFeed` is cleared/invalid or oracle returns zero, owner must restore a valid feed before upkeep resumes.
- Keep regression tests for zero/cleared `chainlinkFeed`, zero `fundToken`, and zero `treasury` during upkeep.

Validation note:
- Verified guard implementation in `PrivateAutomationHub._canExecuteWithBilling` and `PrivateAutomationHub._chargeGasFee`.
- Verified owner intervention path via new `setChainlinkFeed` admin method.

---

### R5-M01: Price==0 path can block emergency LP withdrawal checks
Severity: Medium  
Status: Fixed

Affected code:
- src/mainnet/DoppiCoreView.sol:82
- src/mainnet/DoppiCoreView.sol:91
- src/mainnet/DoppiCoreView.sol:92
- src/mainnet/DoppiLiquidityRouter.sol:68
- src/mainnet/DoppiLiquidityRouter.sol:72
- src/mainnet/DoppiLiquidityRouter.sol:165
- src/mainnet/DoppiLiquidityRouter.sol:166
- src/mainnet/DoppiLiquidityRouter.sol:167
- src/mainnet/DoppiLiquidityRouter.sol:179

Description:
- `DoppiCoreView.getCurrentDeposits(false)` divides by `price` with no guard.
- If oracle path returns `price == 0`, this can revert.
- `DoppiLiquidityRouter.emergencyWithdraw()` relies on `_isPending()`, which calls `_getCurrentDeposits(true/false)` via `staticcall` and requires success.

Current implementation status:
- A `price == 0` guard was added in `getCurrentDeposits`, preventing division-by-zero reverts.
- `DoppiLiquidityRouter._isPending()` now treats `doppiLP.getPrice() == 0` as pending (`true`), so emergency withdraw remains blocked until oracle/feed config is restored.

Impact:
- During severe oracle outage / zero-price conditions, emergency withdraw precheck can revert, blocking emergency redemption even when pause+emergency mode is enabled.
- This is a temporary lock condition tied to price feed health.

Residual impact:
- Emergency withdraw is intentionally unavailable while price is zero. This is an operational dependency: owner must repair oracle/feed configuration before users can continue emergency withdrawals.

Recommendation:
- Keep explicit runbook and monitoring for feed health so owner intervention is prompt.
- Add tests where LP `getPrice()` returns 0 and verify: `emergencyWithdraw()` reverts with pending-orders guard; after valid feed restoration, withdraw path resumes.

---

### R5-M02: uint8 loop-counter overflow risk on unbounded supportDays can DoS settlement paths
Severity: Medium  
Status: Open

Affected code:
- src/mainnet/DoppiCore.sol:330
- src/mainnet/DoppiCore.sol:487
- src/mainnet/DoppiCoreView.sol:38
- src/mainnet/DoppiCoreView.sol:59
- src/mainnet/DoppiCoreView.sol:133
- src/mainnet/DoppiCoreView.sol:147
- src/mainnet/DoppiTraderAdminView.sol:173

Description:
- `supportDays` is dynamic and can be appended by owner (`addSupportDay`) with no hard cap.
- Multiple loops iterate with `uint8` counters against `supportDays.length`.
- If array length exceeds 255, uint8 counters can wrap and cause non-terminating loops / out-of-gas behavior.

Impact:
- Can break position enumeration, counts, and settlement processing.
- Secondary effect: dependent flows that call these views/checks (including stop logic that checks position counts) may fail, causing operational fund lock.
- Requires owner misconfiguration but is still protocol-critical.

Recommendation:
- Use `uint256` loop counters consistently for dynamic arrays.
- Add explicit cap in `addSupportDay` (for example, max 32 or max 64 supported durations).
- Add invariant test: adding many support days should not break checkUpkeep/view calls.

---

### R5-L01: Private factory configuration validation gaps can brick new bot deployments
Severity: Low  
Status: Open

Affected code:
- src/mainnet/private/PrivateDoppiGridTraderFactory.sol:69
- src/mainnet/private/PrivateDoppiGridTraderFactory.sol:80
- src/mainnet/private/PrivateDoppiGridTraderFactory.sol:89
- src/mainnet/private/PrivateDoppiSimpleTraderFactory.sol:70
- src/mainnet/private/PrivateDoppiSimpleTraderFactory.sol:80
- src/mainnet/private/PrivateDoppiSimpleTraderFactory.sol:89
- src/mainnet/private/DoppiGridTrader.sol:290
- src/mainnet/private/DoppiGridTrader.sol:291
- src/mainnet/private/DoppiSimpleTrader.sol:217
- src/mainnet/private/DoppiSimpleTrader.sol:218

Description:
- Factories do not validate implementation code address (`updateImplementation`) and do not validate default private treasury fee bounds (`setDefaultPrivateTreasury`).
- During deployment, factories call bot `setFeeConfig(...)`, while bot contracts enforce `_profitFeeBps <= 3000`.
- If factory owner sets an invalid default fee (or invalid implementation), `deployPrivateBot` can revert, preventing new bot creation.

Impact:
- Deployment DoS for new private bots until owner corrects configuration.
- No direct fund drain from existing bots, but can block operational recovery/migration workflows.

Recommendation:
- Validate `newImplementation.code.length > 0` and `newImplementation != address(0)`.
- Validate `_treasuryFee <= 3000` in both private factories to align with bot constraints.
- Add events/tests for rejected invalid factory config.

---

## 4. Additional Notes (Informational)

- No arithmetic underflow/overflow bugs were found in core arithmetic paths where Solidity 0.8 checks are active and subtract operations are mostly guarded.
- No new permissionless path was identified for direct pool drain via `deposit/redeem/swap` entry points.
- External dependency trust remains a major risk surface (oracle, router, fee pool, automation components).

---

## 5. Suggested Priority Order

1) Fix R5-H02 first (automation execution should never revert from partial billing config).  
2) Fix R5-M02 second (hardening against owner misconfig/array growth DoS).  
3) Fix R5-L01 third (prevent avoidable deployment-time configuration DoS).

---

## 6. Build/Validation Notes

- Repository compile command was executed with Foundry (`forge build`).
- Current build failed due to test/mock interface drift unrelated to this report's findings (`IPrivateAutomationHub` mock missing function implementation), not due to the audited production contracts in this scope.


---

# Doppi Smart Contracts Audit Report (Round 6)

Date: 2026-08-06  
Scope: DoppiClaim, DoppiPoints, DoppiReferral  
Focus: fund-drain vectors, arithmetic underflow/overflow, and conditions that can block user reward withdrawal/claim

## 1) Scope

Reviewed contracts:
- src/mainnet/DoppiClaim.sol
- src/mainnet/DoppiPoints.sol
- src/mainnet/DoppiReferral.sol

Reviewed tests:
- test/DoppiClaim.t.sol
- test/DoppiPoints.t.sol
- test/DoppiPoints_MonthId.t.sol
- test/DoppiReferral.t.sol
- test/DoppiReferralExt.t.sol

Method:
- Manual static analysis of state transitions and claim flows
- Cross-check against existing tests for covered and uncovered edge cases

---

## 2) Executive Summary

- No direct unauthorized token transfer drain primitive was identified in this scope.
- One arithmetic underflow edge exists in DoppiReferral month handling, but with the configured `startTimestamp` it is time-bound and not currently exploitable in production time.
- The DoppiPoints multiplier behavior was clarified as intentional (same policy for EOA and bots), so it is not treated as a security issue.

---

## 3) Findings

### R6-H01: Month-0 arithmetic underflow can DoS referral registration and reward calculations
Severity: Low (time-bound)  
Status: Accepted Risk (not currently exploitable)

Affected code:
- src/mainnet/DoppiReferral.sol:117
- src/mainnet/DoppiReferral.sol:295
- src/mainnet/DoppiReferral.sol:296

Description:
- In registerReferralCode, claimedMonthId is initialized as _currentMonthId() - 1.
- If currentMonthId == 0, this underflows and reverts in Solidity 0.8+.
- In _getTotalReferralRewards, endMonthId is computed as currentMonthId - 1, which also underflows at month 0.
- These paths can block referral onboarding or reward querying at boundary conditions, resulting in claim flow interruption.

Impact:
- Referral registration can become unavailable in month 0.
- Referral reward reads/reset paths can revert in month 0.
- Operationally, users cannot proceed with referral claim-related actions until time advances beyond the underflow boundary.

Current-time assessment:
- With `startTimestamp = 1735689600` (Jan 1, 2025), current monthId is already greater than 0 in production time.
- Therefore this condition is not currently reachable unless running a chain/testing environment at month 0 relative to the configured epoch.

Recommendation:
- Guard month arithmetic explicitly.
- Use safe branch logic:
  - if currentMonthId == 0, initialize claimedMonthId to 0 (or a dedicated sentinel).
  - in reward loops, return zero early when currentMonthId == 0.
- Add dedicated tests for month 0 boundaries:
  - registerReferralCode at month 0
  - getTotalReferralRewards at month 0

---

### R6-M01: Bot/EOA multiplier policy is uniformly applied
Severity: Informational  
Status: Closed (by design)

Affected code:
- src/mainnet/DoppiPoints.sol:64
- src/mainnet/DoppiPoints.sol:66
- src/mainnet/DoppiPoints.sol:67
- src/mainnet/DoppiPoints.sol:228

Description:
- recordTrade computes effectivePoints using botVolumeMultiplierNum/botVolumeMultiplierDen for all trades.
- The configured multiplier is intentionally applied to both EOA and bot-attributed volume.
- The team confirmed this uniform treatment is intended tokenomics behavior.

Impact:
- No security impact under the stated policy.
- This is a tokenomics/governance parameter choice, not an access-control or arithmetic safety flaw.

Recommendation:
- Keep clear documentation that multiplier applies uniformly to all traders.
- Maintain governance controls and monitoring around multiplier changes to avoid unintended economic shifts.
- No security remediation required.

---

## 4) Additional Notes

- Claimability liveness appears generally robust under normal month progression, but depends on DoppiClaim/DoppiReferral month arithmetic behaving safely for boundary months.
- Owner-controlled parameters (rate schedules, min-volume schedules, multiplier) can materially change economics; governance and operational controls should be documented and monitored.

---

## 5) Suggested Priority

1) Keep R6-H01 documented as a boundary invariant; fix when touching referral month logic next.

---

## 6) Suggested Tests To Add

- Referral month-0 tests:
  - registerReferralCode succeeds at month 0
  - getTotalReferralRewards returns zero (no revert) at month 0
- Policy-consistency tests:
  - EOA and bot both receive the configured multiplier effect

