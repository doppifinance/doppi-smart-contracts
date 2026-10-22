# Doppi Mainnet Smart Contract Security Audit

Date: 2026-10-02  
Scope: Current `src/mainnet` tree, including all nested contracts under `src/mainnet/private`, plus directly used `src/Library` and `src/Interface` dependencies  
Review type: Source review against prior audit reports, with Foundry validation attempted

## Executive Summary

The current source contains the substantial remediations described in the 2026-08-15 independent report, but the review identified one new reward-accounting vulnerability and one live oracle-availability weakness. No permissionless direct withdrawal from Core or the LP was confirmed, and no reentrancy path that bypasses the reviewed role checks was identified.

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| M-01 | Medium | Initial shared-trader weights can over-credit trade points | Fixed |
| M-02 | Medium | Reverting primary oracle prevents configured TWAP fallback | Open |
| L-01 | Low | Strike upkeep scans remain unbounded until owners configure limits | Open operational risk |
| INFO-01 | Informational | Emergency LP redemption bypasses Core-liability check in Core emergency mode | Intentional emergency behavior; document and test the loss policy |

The fixes for the prior high/medium findings are present in source, including the settlement quote direction, deleted-position queue traversal, failed emergency transfer atomicity, bounded resumable emergency scanning, and private billing/points safeguards. Some adversarial regressions listed in the August report remain untested; code presence is not equivalent to complete behavioral validation.

The Foundry test command was invoked and began compiling 22 files, but it did not reach a test summary before the process was terminated. Tests are unverified; this report does not claim a passing full-suite run. No test was added as part of this report-only review.

## Scope and Method

Reviewed all 29 Solidity files under `src/mainnet`, including shared Core, liquidity, opportunity, trader, rewards, claims, and upkeep contracts, and all six contracts in `src/mainnet/private`. Relevant oracle/math libraries and interfaces were inspected where they control these flows. Existing audit reports in `audit/` were compared against current source. Review topics included asset custody, role boundaries, reentrancy, external calls, settlement and emergency accounting, rounding, unchecked arithmetic, oracle failure modes, cloning/initialization, and gas-bounded progress.

This is a source-state assessment, not a deployment verification. Deployed addresses, live owner/forwarder configuration, token behavior, oracle feed configuration, and production bytecode were not independently checked.

## Findings

### M-01: Initial shared-trader weights can over-credit trade points

Severity: Medium  
Affected path: `DoppiTraderFactory.deployTraderBot` → `DoppiTrader.initialize` / `_initializeOrderConfigs` → `_prepareOrders` / `_placeOrders` → `DoppiCore.bulkDeposit`

The shared trader factory accepts user-provided weights when deploying a bot. `_initializeOrderConfigs` copies nonzero entries into the bot's order configuration but does not require their sum to equal 10,000 bps. The later trader-facing `setMultipleOrderConfigs` does enforce a 10,000-bps sum, but a newly deployed bot can start trading before that setter is called.

`_prepareOrders` computes each actual order as `availableAsset * weight / 10_000` while returning `availableAsset` as the `total` supplied to Core. `_placeOrders` approves and deposits the sum of the actual order amounts, but passes the larger budget value as `total`. Core records points using that supplied total. Therefore, with initial weights whose sum is below 10,000, the bot can create much less Core principal than the trade volume credited to its valid trader. The credited volume can approach `10_000 / sum(weights)` times the deposited volume, subject to per-order minimums and available pool capacity.

A bot deployer can choose these initial weights through the public factory, so this is not limited to owner misconfiguration. If points are redeemable for a mintable reward token, the mismatch enables disproportionate reward issuance and dilutes the reward system. We did not confirm a direct withdrawal of LP/Core principal through this issue.

Recommendation:

- Validate a nonzero initial weight sum of exactly 10,000 bps in the factory or initializer before storing the configuration.
- Independently derive points volume from the sum of successfully deposited order amounts in Core; do not accept a caller-supplied total that can disagree with actual positions.
- Add a regression test deploying with underweighted initial weights and assert that credited points equal actual deposited volume, or that deployment rejects the weights.

Remediation: `_initializeOrderConfigs` now rejects weight arrays that do not sum to 10,000 bps. The trader now passes the sum of its actual order amounts through Core's existing `total` argument, rather than the larger allocation budget. Regression tests cover invalid initial weights and point volume after per-order rounding.

### M-02: Reverting primary oracle prevents configured TWAP fallback

Severity: Medium  
Affected code: `src/Library/DALiquidityLib.sol` (`getPriceWithFallback`, `getPrice`); callers include `DoppiLiquidity.getPrice`, `DoppiOffer` offer generation, Core settlement, and trader automation.

`getPriceWithFallback` calls `getPrice` first and only tries the V3 TWAP if that call returns zero. `getPrice` directly calls `chainLinkFeed.latestRoundData()` without `try/catch`. If the feed call reverts, returns malformed ABI data, or is configured to an unusable contract, execution reverts before reaching the TWAP branch. The fallback therefore covers stale/nonpositive feed values that are returned normally, but not a feed that fails by reverting.

Price-dependent deposits, settlement, ordinary LP redemption, and keeper checks can consequently stop despite a valid configured V3 fallback. The Core emergency snapshot also calls the LP price path unless a separate emergency V3 source has been configured, so a primary-feed revert can block activation of the emergency recovery path as well. Recovery then depends on an administrator having configured a valid emergency source or repairing the feed/configuration.

Recommendation:

- Isolate the Chainlink read in an external self-call or `try/catch` wrapper and proceed to the configured TWAP on failure.
- Validate that both configured sources return a nonzero price with expected token orientation and decimals.
- Add tests where `latestRoundData` reverts while the V3 source remains valid, covering LP price, settlement, and emergency-mode activation.

### L-01: Strike upkeep scans remain unbounded until owners configure limits

Severity: Low, operational denial-of-service risk  
Affected code: `DoppiLiquidity` (`maxCheckStepsBuy`, `maxCheckStepsSell`); `DoppiOpportunity` (`maxCheckSteps`); linked-strike traversal in the shared and trader modules.

The older range scans were replaced with active-strike linked lists, which removes iteration over empty price buckets. However, the liquidity and opportunity scan limits initialize to `type(uint256).max`. Until operators call `setCheckStepLimits` and `setMaxCheckSteps`, upkeep checks and associated work still process every active strike. Active-set size and per-node insertion/removal work are not capped by protocol invariants.

A sufficiently fragmented active-strike set can make keeper simulation or execution impractical and delay hedging/unwinds. This is an operational scalability risk, not a demonstrated user-controlled one-transaction fund drain. The repository's deployment/operator configuration must actively set finite limits; the source defaults do not enable bounded mode.

Recommendation:

- Set finite scan limits as part of deployment and verify them on-chain.
- Consider safe finite constructor defaults and cursor-progress regression tests at realistic active-strike counts.

### INFO-01: Emergency LP redemption bypasses the Core-liability check in Core emergency mode

Severity: Informational / emergency-policy decision  
Affected code: `DoppiLiquidityRouter.emergencyWithdraw`; `DoppiCore.emergencyWithdrawCoreOnly` and emergency snapshot logic.

The router checks Core principal liabilities only when Core is not in emergency mode. Once Core emergency mode is active, LP holders can redeem without waiting for all position owners to process their emergency withdrawals. Core emergency withdrawals pay from a fixed pro-rata snapshot of Core-held assets and do not pay accrued interest. This appears to be a deliberate emergency loss policy, but it differs from the prior report's recommendation that LP redemption wait for Core liabilities to be cleared.

This is not reported as a confirmed LP drain: the emergency Core payout is calculated from the separately locked Core snapshot, and interest is intentionally omitted from the emergency payout. The protocol should nevertheless make explicit that enabling emergency mode authorizes unpaid interest and permits LPs to exit before all Core positions have been processed. A dedicated test should demonstrate the intended result when LP redemption occurs while other owners still have active Core positions.

## Prior Findings: Current-Source Status

The following previously reported issues were checked against current source. “Present” means the relevant remediation is visible in current code; it does not mean every adversarial test recommended by prior reports exists or passed in this review.

| Prior issue | Current assessment |
| --- | --- |
| Inverse quote for struck payout shortfall (2026-08 H-01) | Remediation present: `interestGet` derives conversion direction from the requested interest token. Strict-price exact-output tests for both directions remain recommended. |
| Deleted-position holes blocking settlement queues (2026-08 H-02) | Remediation present: ready-position traversal skips deleted IDs only within assigned IDs and stops at the tail. Dedicated three-owner queue-hole test remains recommended. |
| LP emergency withdrawal without a Core-liability gate (2026-08 H-03) | Gate is enforced outside Core emergency mode; emergency-mode bypass remains and is described in INFO-01. |
| Failed emergency token transfer deleting a claim (2026-08 M-01) | Remediation present: emergency payouts use reverting safe transfers, so a failed transfer reverts deletions and accounting atomically. Receiver-blocking retry test remains recommended. |
| Global owner-position scans / unbounded emergency recovery (2026-08 M-02) | Remediation present: per-owner aggregates and resumable, inspected-ID-bounded emergency cursor. Large-scale gas invariant test remains recommended. |
| Settlement top-up residual omitted from unwind accounting (2026-08 M-03) | Remediation present: actual exact-output input is captured and positive residual input is registered for unwind. Partial-inventory regression test remains recommended. |
| Liquidity slippage lacked a configuration ceiling | Remediation present: `MAX_SLIPPAGE_BPS` limits configuration to 3,000 bps. |
| Private stop blocked by zero price (P-M01) | Remediation present: stop-fee valuation returns without charging when price is zero. Zero-price stop test remains recommended. |
| Private scheduler aggregate check gas (P-M02) | Remediation present: aggregate budget and cursor-only progress are enforced. Larger stress test remains recommended. |
| Private dynamic-points source mismatch / source failure (P-M03) | Remediation present in the private hub: pool source is validated and TWAP failure is isolated. The shared `DALiquidityLib` primary-feed revert issue in M-02 is separate. |
| Private billing-token denomination migration (P-M04) | Remediation present: old credit rolls into token-specific withdraw-only balances. |
| Fee-hook stop blockage and private billing precondition mismatch (Rounds 5 H-01/H-02) | Remediation present: hook failures are best effort and billing prerequisites are checked before execution. |
| Private factory implementation/default-fee validation (Rounds 5 L-01) | Remediation present in both private factories. The shared `DoppiTraderFactory.updateImplementation` still lacks code-address validation; this is an owner-only deployment-bricking risk and is not treated as a fund-loss finding. |
| Support-day `uint8` loop-counter overflow (Rounds 5 M-02) | Dynamic support-day loops inspected use `uint256` counters. No current 255-item wraparound issue was confirmed. |
| Referral month-zero underflow (Rounds 6 R6-H01) | The arithmetic remains, but month zero is before the configured 2025 epoch and is not reachable at the current date. It is a test/epoch-boundary robustness issue, not an active production finding. |
| Permissionless liquidity unwind-map clearing / stale user-supplied bulk offers | Access control and fresh offer reconstruction are present in current source. |
| Emergency token-failure handling and fee-pool notification behavior | Best-effort notification does not roll back fee transfers; emergency direct transfers retain the claim atomically on failure. |

## Security Assessment by Topic

- **Reentrancy:** Core deposits/settlement/claims/emergency withdrawal and liquidity swaps/redemptions use reentrancy guards. Private trader start/stop/upkeep and hub credit/perform paths also use guards. The fee-pool notification is a low-level external callback after the fee token transfer; failures are ignored and the calling fund-moving path is guarded. No reentrancy-based unauthorized withdrawal was confirmed.
- **Custody and authorization:** User deposits and claims are owner-scoped; LP share mint/burn is restricted to configured entry points; liquidity swaps are restricted to Core or registered trader bots; opportunity storage mutation is Core-only; private automation execution is executor-only. These controls depend on correct, trusted owner/factory/forwarder configuration.
- **Arithmetic and rounding:** Solidity checked arithmetic is used for normal arithmetic; reviewed `unchecked` blocks primarily increment bounded loop/cursor values. Pro-rata and per-order calculations round down. Rounding dust can remain in inventory/accounting, but no standalone permissionless drain was confirmed. The points volume mismatch in M-01 is a semantic accounting error, not an integer overflow.
- **Initialization and proxies:** Shared and private trader implementations disable initializers. Factory clone creation and initialization occur in the same transaction. No clone initialization front-run was identified. The shared factory's implementation setter can still be set to an unusable address by its owner, bricking future deployments but not existing clones.
- **Ownership and key compromise:** Owners can alter oracle, router, slippage, treasury, factory, feed, implementation, and emergency configuration. These powers can halt operations or redirect economic flows. Use multisig/timelock controls and monitor changes. No unauthenticated owner takeover or privilege escalation was confirmed.
- **Funds stuck:** Oracle call reverts can block normal price-dependent flows (M-02). Bounded-scan limits must be configured to avoid future gas pressure (L-01). Private user stop and emergency claim paths are materially improved, but emergency withdrawals do not pay interest.

## Recommended Actions

1. Fix M-01 and add a regression test proving points volume is derived from actual deposited position amounts.
2. Make the Chainlink-to-TWAP fallback failure-isolated and test reverting/malformed oracle behavior.
3. Configure finite scan bounds in deployment and operations; verify the settings after deployment.
4. Document the emergency haircut and LP-exit policy, and test LP exit before all Core emergency claims are processed.
5. Add the remaining adversarial regressions from the 2026-08 report before production reliance, especially strict exact-output settlement, queue holes, failed emergency transfers, residual settlement accounting, and zero-price private stops.
6. Validate the shared trader factory's replacement implementation has code before accepting it, to prevent owner misconfiguration from bricking new deployments.

## Conclusion

The current source reflects meaningful fixes across settlement accounting, queue progress, emergency transfer atomicity, private automation gas limits, billing denomination, and clone initialization. The principal new security issue is under-accounted actual trading paired with over-recorded points volume for newly deployed shared trader bots. The other live concerns are oracle failure isolation and deployment-dependent gas bounding. Production risk remains materially dependent on privileged configuration and on closing the recommended adversarial-test gaps.
