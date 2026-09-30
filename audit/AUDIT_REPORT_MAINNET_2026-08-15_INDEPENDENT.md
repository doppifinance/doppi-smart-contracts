# Doppi Finance Mainnet Smart Contract Security Audit

Date: 2026-08-15  
Audited commit: `6982086d876e73215bb4bf314ead518d18bc9cd2` plus the uncommitted worktree present on 2026-08-15  
Assessment type: independent source review and targeted Foundry validation

## Scope

The review covered the Solidity contracts directly under `src/mainnet`, their non-ignored interfaces and libraries, and relevant tests. The principal contracts reviewed were:

- `DoppiCore`, `DoppiCoreAdmin`, `DoppiCoreView`, and `DoppiOpportunity`
- `DoppiLiquidity`, `DoppiLiquidityRouter`, and `ERC7575`
- `DoppiTrader`, `DoppiTraderAdminView`, and `DoppiTraderFactory`
- `DoppiGridTrader`, `DoppiSimpleTrader`, both private trader factories, and `PrivateAutomationHub`
- `DoppiFeePool`, `DoppiOffer`, `DoppiPoints`, `DoppiReferral`, and `DoppiClaim`
- `DoppiUpkeepManager`, `Swapper`, and `BlackScholes`

The `src/mainnet/private` exclusion was removed from `.copilotignore` on 2026-08-15. All six contracts in that subtree, their interfaces, factories, deployment wiring, and relevant tests were then independently reviewed. The pre-existing private audit was consulted only after this review produced its candidate findings.

## Methodology

- Traced deposits, opportunity swaps, expiry settlement, interest funding, LP redemption, and emergency withdrawal end to end.
- Traced private trader custody, stop/unwind flows, automation registration and execution, prepaid credit, points billing, and factory initialization.
- Reviewed role boundaries for owners, forwarders, opportunity bots, factories, entry points, routers, and points registrars.
- Checked reentrancy ordering, external calls, token allowances, clone initialization, arithmetic direction, rounding, stale-price behavior, queue progress, and unbounded loops.
- Compared current code against tests and ran targeted Foundry tests. Prior audit reports were consulted only after the independent review generated candidate findings.
- Rejected candidates that depended only on a malicious owner where no privilege escalation exists, or that were based on incorrect Solidity/Uniswap assumptions.

## Executive Summary

No direct, permissionless, single-call theft primitive was identified in the reviewed normal deposit path under the intended token and oracle configuration. Clone initialization is protected by same-transaction factory deployment, the implementation disables initializers, and critical custody entry points generally use role checks and reentrancy guards.

The review originally found three high-severity issues in the shared mainnet system: an incorrectly quoted payout shortfall, a settlement queue that could be blocked by selective emergency deletion, and LP emergency withdrawal without a Core-liability gate. The current worktree remediates all three. It also remediates the three medium-severity shared-mainnet findings concerning failed emergency transfers, global owner scans, and residual settlement input accounting. Targeted post-remediation validation passed, although several dedicated adversarial tests listed below are still recommended.

No independent high-severity issue was confirmed in the private subtree. The four medium-severity private findings have been remediated in the current worktree: private stop no longer depends on price availability, shared scheduler scans have an aggregate gas bound with resumable progress, dynamic points pricing validates its V3-pool source and fails safely, and billing-token migrations preserve old balances as token-specific withdraw-only credit. The two low-severity private billing findings are explicitly acknowledged and accepted without code changes.

| ID | Severity | Title | Status |
| --- | --- | --- | --- |
| H-01 | High | Struck payout shortfall uses the inverse token conversion | Remediated; strict-router regression test pending |
| H-02 | High | Selective emergency deletion can permanently block a duration queue | Remediated; dedicated queue-hole test pending |
| H-03 | High | LP emergency withdrawal is not gated on Core liabilities | Remediated; dedicated liability-gate test pending |
| M-01 | Medium | Failed emergency token transfer deletes the user's claim | Remediated by atomic revert; failure-path test pending |
| M-02 | Medium | Global position scans can make bot exit and emergency recovery run out of gas | Remediated and regression-tested |
| M-03 | Medium | Settlement DEX top-up leaves residual input outside unwind accounting | Remediated; residual-accounting test pending |
| INFO-01 | Informational | Points multiplier intentionally applies equally to users and bots | Expected behavior; no change required |
| L-02 | Low | Liquidity slippage has no configuration bound | Remediated and regression-tested |
| P-M01 | Medium | Private trader stop is blocked when the LP price is unavailable | Remediated; zero-price regression test pending |
| P-M02 | Medium | Per-target gas caps do not bound aggregate shared scheduler gas | Remediated and regression-tested |
| P-M03 | Medium | Dynamic points pricing documents a Chainlink feed but calls a V3 pool API | Remediated and regression-tested |
| P-M04 | Medium | Changing the billing token invalidates outstanding credit denomination | Remediated and regression-tested |
| P-L01 | Low | Successful jobs can be only partially billed while lifetime fees record the full charge | Acknowledged and accepted |
| P-L02 | Low | Billing trader assignment has no recovery or rotation path | Acknowledged and accepted |

## Findings

### H-01: Struck payout shortfall uses the inverse token conversion

Severity: High  
Affected code: `src/mainnet/DoppiCore.sol:903`, `src/mainnet/DoppiLiquidity.sol:106-129`

Remediation status: Remediated in the current worktree. Core no longer passes the original position side into `interestGet`; `DoppiLiquidity.interestGet` derives the conversion from the requested interest token and its opposite input asset. A strict price-enforcing exact-output regression test is still recommended.

When a pre-traded, struck position has `totalProceeds < payout`, Core asks the LP to provide the payout-token shortfall:

```solidity
_doppiInterestGet(payoutToken, notenough, price, isBuy);
```

`DoppiLiquidity.interestGet` selects the input token from `_interestToken`, but selects the conversion formula from the original position-side flag `isBuy`. Those concepts coincide for normal interest and no-strike principal recovery, but they are opposite for a struck payout token.

For asset A as quote currency, asset B as base currency, price `P`, and scale `D`:

- Buying `x` units of B requires approximately `x * P / D` units of A.
- Buying `x` units of A requires approximately `x * D / P` units of B.

For a struck buy, the requested payout token is B but `isBuy == true`, so the code permits only `x * D / P` A instead of `x * P / D`. At a price of 100,000, the maximum is smaller than required by a factor of about 10 billion and a production exact-output router reverts. The position and every later position in the same settlement batch remain unsettled.

For a struck sell, the requested payout token is A but `isBuy == false`, so the maximum input is larger by the same factor. The exact-output call can succeed, but the intended oracle-based slippage ceiling is effectively removed, exposing LP funds to extreme adverse execution or sandwiching.

The existing `test_SettleSellStrikedTraded_EmitsSettledEvent_NotEnoughOutAmountCase` passes because `src/test/Swapper.sol` always spends `amountInMaximum` and mints the requested output without enforcing pool pricing. It therefore masks the production behavior.

Recommendation:

- Derive the quote direction from `assetIn` and `_interestToken`, not from the original position side.
- Prefer separate, typed helpers such as `_fundAssetAShortfall` and `_fundAssetBShortfall` or pass an explicit swap direction.
- Add strict-router tests for both struck buy and struck sell shortfalls, including a test that asserts the maximum input is within configured slippage of the oracle quote.

### H-02: Selective emergency deletion can permanently block a duration queue

Severity: High  
Affected code: `src/mainnet/DoppiCore.sol:336-385`, `src/mainnet/DoppiCore.sol:450-472`

Remediation status: Remediated in the current worktree. `_getReadyAllPositions` skips deleted IDs only within the assigned ID range and stops at `nextPositionId`, preventing both queue blockage and advancement into never-created tail IDs. Existing readiness and pagination tests pass; the original three-owner queue-hole sequence should still be retained as a dedicated regression test.

`emergencyWithdrawCoreOnly` scans the shared position IDs and deletes only positions owned by the caller. It advances `nextProcessId[day]` across empty IDs only when those IDs are already at the head during that call.

This permits the following sequence:

1. Position 1 belongs to Alice, position 2 to Bob, and position 3 to Carol for the same duration.
2. During emergency mode Bob withdraws. Position 2 is deleted, but position 1 still exists, so the cursor remains at 1.
3. Emergency mode is disabled and normal settlement later settles position 1, advancing the cursor to 2.
4. `_getReadyAllPositions` sees that position 2 does not exist and executes `break` instead of skipping it.
5. It returns no ready position. `checkUpkeep` cannot progress and `settleOrders` reverts with `NoPositionsToSettle`; position 3 and all later positions for that duration are stuck.

Recommendation:

- Make queue traversal skip deleted IDs and persist the first existing cursor before checking expiry.
- Alternatively maintain an explicit linked list/bitmap of live IDs.
- Add a regression test with three owners where only the middle owner exits in emergency mode, emergency mode is disabled, and both surrounding positions remain settleable.

### H-03: LP emergency withdrawal is not gated on Core liabilities

Severity: High  
Affected code: `src/mainnet/DoppiLiquidityRouter.sol:62-69`, `src/mainnet/DoppiLiquidity.sol:319-346`

Remediation status: Remediated in the current worktree. `DoppiLiquidityRouter.emergencyWithdraw` now reverts with `CoreLiabilitiesOutstanding` unless both Core current-deposit values are zero. Those values include active principal and interest liabilities. Pending settlement assets are already held by Core rather than the LP, so they are not withdrawable through the LP redemption path. A direct nonzero-liability revert test is still recommended.

Once the router is paused and emergency mode is enabled, any LP can burn all shares for its pro-rata share of the LP's current token balances. Neither the router nor the LP verifies that Core has zero active positions, zero interest liabilities, and no pending settlements.

The first LPs to exit can remove assets required to fund interest, payout shortfalls, and rebalancing. Remaining LPs and Core position owners inherit the deficit. This is a bank-run ordering problem rather than a fair loss socialization mechanism. The source comment on `emergencyWithdraw` acknowledges that liabilities must first be settled, but no runtime condition enforces it.

Recommendation:

- Use a two-phase emergency state: freeze deposits and automation, settle or snapshot all Core liabilities, then enable LP redemption.
- Gate emergency LP redemption on explicit Core invariants, including all active principal, interest liabilities, and pending settlement balances.
- If immediate exits are required, reserve liabilities before calculating each LP's redeemable balances.

### M-01: Failed emergency token transfer deletes the user's claim

Severity: Medium  
Affected code: `src/mainnet/DoppiCore.sol:352-408`

Remediation status: Remediated in the current worktree by using reverting `SafeERC20.safeTransfer` calls. If either emergency payout transfer fails, the entire transaction, including position deletion and accounting changes, reverts atomically. The user can retry with a valid receiver. A receiver-blocking token test is still recommended.

Emergency withdrawal deletes each position and reduces deposit and interest-liability accounting before transferring the user's pro-rata asset A and asset B. Transfers use best-effort `_attemptDirectTransfer`. If a token rejects the receiver, pauses transfers, or blacklists the user, the function does not revert and does not create a pending settlement.

The user permanently loses the failed side of the emergency payout because the position has already been deleted and there is no retry record. A partial failure is especially problematic: one asset can be paid while the other claim disappears.

Recommendation:

- Record each failed emergency transfer in the existing pending-settlement mechanism, or retain a dedicated emergency claim balance per user and token.
- Do not treat a deleted position as fully discharged until all computed token claims are either paid or recorded.
- Test one-sided and two-sided failures with a receiver-blocking token.

### M-02: Global position scans can make bot exit and emergency recovery run out of gas

Severity: Medium  
Affected code: `src/mainnet/DoppiCoreView.sol:31-69`, `src/mainnet/DoppiCoreView.sol:125-153`, `src/mainnet/DoppiCore.sol:336-385`, `src/mainnet/DoppiTrader.sol:87-96`, `src/mainnet/DoppiTrader.sol:133-141`

Remediation status: Remediated and regression-tested in the current worktree. Per-owner counts and principal totals make bot checks and balance aggregation constant-time. Emergency recovery now limits IDs inspected, persists a per-owner cursor, and resets cursors by emergency epoch. `test_emergencyWithdraw_resumesAfterUnrelatedPosition` confirms bounded resumable progress past an unrelated position.

Position getters and counters scan every live global position for every supported duration to find positions belonging to one owner. `DoppiTrader.stop`, `DoppiTrader.emergencyWithdraw`, and `DoppiTrader.getTotalBalances` invoke these scans on-chain.

`emergencyWithdrawCoreOnly(maxPositions)` has the same structural issue: `maxPositions` limits only matching positions processed, not unrelated IDs scanned before a match. A trader with one late position can consume gas proportional to the entire system queue.

At sufficient position count these calls exceed the block gas limit. A bot can then be unable to prove it has no positions and return its locally held or LP-held funds through `stop`; emergency recovery can also become unusable exactly when needed.

Recommendation:

- Maintain owner-indexed active position IDs or per-owner active counts updated on deposit, settlement, and emergency deletion.
- Make emergency processing cursor-based per owner and bound total IDs inspected, not only matches processed.
- Add gas-invariant tests with large numbers of unrelated positions before the target owner's position.

### M-03: Settlement DEX top-up leaves residual input outside unwind accounting

Severity: Medium  
Affected code: `src/mainnet/DoppiLiquidity.sol:133-149`

Remediation status: Remediated in the current worktree. `settle` captures the exact-output router's returned `actualAmountIn` and records `_amountIn - actualAmountIn` through `_updateUnwindTarget` when positive. The conditional subtraction also avoids underflow if configured slippage causes actual input to exceed the settlement input. A dedicated partial-inventory test using the configurable exact-output mock is still recommended.

`settle` transfers the full `_amountIn` from Core. If the LP lacks enough `assetOut`, it executes an exact-output swap for the deficit. The router returns the actual input spent, but the value is ignored. The function records no unwind target in this branch.

Whenever actual input spent is less than `_amountIn`, the residual input remains in the LP and is included in share value, but is absent from `amountToBuy`/`amountToSell`. The automated strategy therefore never rebalances that residual. Repeated settlements can create persistent inventory drift and reduce the asset available for the opposite side's obligations.

Recommendation:

- Capture `actualAmountIn` from `_swapExactOutputV3`.
- Record `_amountIn - actualAmountIn` in the correct unwind bucket when nonzero.
- Test exact balance, partial inventory, and zero inventory cases against an exact-output router that refunds unused maximum input.

### INFO-01: Points multiplier intentionally applies equally to users and bots

Severity: Informational  
Affected code: `src/mainnet/DoppiPoints.sol:61-92`

`recordTrade` applies `botVolumeMultiplierNum / botVolumeMultiplierDen` to both direct users and bot-originated trades. Protocol design treats normal traders and bots equally for points, so this behavior is intentional and is not a security finding.

Recommendation:

- No code change is required.
- Optionally rename the configuration fields to `tradeVolumeMultiplierNum` and `tradeVolumeMultiplierDen` to make the intended scope explicit.

### L-02: Liquidity slippage has no configuration bound

Severity: Low  
Affected code: `src/mainnet/DoppiLiquidity.sol:237-258`, `src/mainnet/DoppiLiquidity.sol:547-574`

Remediation status: Remediated and regression-tested in the current worktree. `DoppiLiquidity.setConfig` now rejects slippage above `MAX_SLIPPAGE_BPS` (3,000 bps) before mutating configuration. Tests confirm that the exact maximum is accepted and 3,001 bps reverts with `SlippageTooHigh`. Existing Liquidity scenarios using up to 3,000 bps continue to pass.

`setConfig` does not require `config.slippage <= 10000`. A value above 10,000 makes exact-input paths revert on `10000 - config.slippage`; a very high value below 10,000 permits severe execution loss. This requires owner error or compromise, so it is classified as a configuration risk rather than a privilege-escalation vulnerability.

Recommendation:

- Enforce a conservative protocol maximum and emit granular configuration-change events.
- Use a timelock/multisig for oracle, router, slippage, treasury, forwarder, and emergency configuration.

## Private Module Findings

### P-M01: Private trader stop is blocked when the LP price is unavailable

Severity: Medium  
Affected code: `src/mainnet/private/DoppiGridTrader.sol:138-159`, `src/mainnet/private/DoppiSimpleTrader.sol:128-160`, `src/mainnet/DoppiTraderAdminView.sol:403-410`

Remediation status: Remediated in the current worktree. `_payStopProfitFees` now returns without charging a price-dependent profit fee when `doppiLP.getPrice()` returns zero. Both private `stop()` paths continue clearing strategy state and returning token balances to the trader. A dedicated zero-price stop regression test remains recommended.

Both private traders call `_payStopProfitFees()` before clearing strategy state and returning all token balances to `validTrader`. If a fee pool and nonzero profit fee are configured and an unwind bucket remains active, the helper requires `doppiLP.getPrice()` to be nonzero and reverts with `InvalidPrice` otherwise.

An outage affecting both the primary oracle and LP fallback therefore prevents the trader from calling `stop()` and recovering custody. Unlike the shared `DoppiTrader`, neither private trader has an emergency withdrawal method. The user also cannot disable fees because `setFeeConfig` is restricted to the factory-owned bot owner. Recovery requires the factory owner to set the fee to zero or restoration of the oracle path.

Recommendation:

- Add a trader-accessible emergency exit that returns the bot's current token balances without requiring price-based profit realization.
- Alternatively record deferred fee claims when price is unavailable rather than blocking principal withdrawal.
- Test `stop()` with active buy and sell buckets while both LP price sources return zero.

### P-M02: Per-target gas caps do not bound aggregate shared scheduler gas

Severity: Medium  
Affected code: `src/mainnet/private/PrivateAutomationHub.sol:441-484`

Remediation status: Remediated and regression-tested in the current worktree. `checkUpkeep` enforces `maxAggregateCheckGas`, reserves gas for return-data construction, and clips each target call to the remaining aggregate allowance. Partial or gas-exhausted scans return cursor-only upkeep data, which the existing `performUpkeep` path persists. Tests confirm both ordinary partial-scan pagination and progress past an expensive false-returning target.

`checkUpkeep` caps each target `staticcall` at `maxCheckUpkeepCallGas`, currently up to 5,000,000 gas, but may scan `checkScanLimit` jobs in one call. There is no aggregate gas budget. With the mainnet-style configuration of one selected job and a scan limit of 64, many due jobs that return false or exhaust their individual allowance can consume far beyond a practical simulation or block gas limit before a useful job is found.

A private grid bot can naturally accumulate enough active strike state to make its check expensive; a tenant can amplify the problem by deploying and funding many bots. One tenant can therefore degrade upkeep discovery for every bot sharing the hub even though each individual call is capped.

Recommendation:

- Stop scanning once an aggregate gas budget is reached and persist the next cursor.
- Apply lower module-specific check gas limits and quarantine repeatedly failing or expensive jobs.
- Add a stress test with many funded, due targets that consume their entire check allowance and return false.

### P-M03: Dynamic points pricing documents a Chainlink feed but calls a V3 pool API

Severity: Medium  
Affected code: `src/mainnet/private/PrivateAutomationHub.sol:267-272`, `src/mainnet/private/PrivateAutomationHub.sol:351-360`, `src/mainnet/private/PrivateAutomationHub.sol:610-639`, `src/Library/DALiquidityLib.sol:49-94`

Remediation status: Remediated and regression-tested in the current worktree. The setter now explicitly accepts a Doppi/native V3 pool and rejects addresses that do not expose the pool interface. Dynamic TWAP reads use a failure-isolated external wrapper; pool failures conservatively value points at zero, allowing fund-token billing and shared scheduling to continue. Tests cover non-pool rejection, valid-pool acceptance, and runtime pool failure.

`setDoppiPointsPriceFeed` documents `_feed` as a Doppi/BNB or Doppi/USD Chainlink feed. Dynamic valuation instead passes the address to `DALiquidityLib.getTWAPPrice`, which calls the Uniswap/Pancake V3 pool methods `observe`, `token0`, and token `decimals`.

Supplying the documented Chainlink aggregator makes dynamic point valuation revert. For a points-enabled bot, `_canExecuteWithBilling` invokes this path during shared `checkUpkeep`, so the revert can disrupt the scheduler rather than simply treating points as unavailable. No interface or code-shape validation occurs when the feed is configured. The V3 helper also hardcodes the BSC USDT address, making other quote pools or chains unsafe without additional validation.

Recommendation:

- Split Chainlink and V3 pool configuration into typed, explicitly validated modes.
- Catch price-source failures and conservatively value points at zero so fund-token billing remains available.
- Validate pool tokens, quote direction, observation capacity, and expected decimals.

### P-M04: Changing the billing token invalidates outstanding credit denomination

Severity: Medium  
Affected code: `src/mainnet/private/PrivateAutomationHub.sol:206-209`, `src/mainnet/private/PrivateAutomationHub.sol:279-318`

Remediation status: Remediated and regression-tested in the current worktree. Each bot's active credit is bound to its fund token. On migration, stale credit is lazily moved into a token-specific, withdraw-only legacy balance and cannot satisfy current billing. New deposits and charges use the new token. `setBillingAssetConfig` atomically changes the token, native/token feed, token-denominated threshold, and default top-up, with decimal normalization for gas and points accounting. Tests cover legacy withdrawal, billing isolation, and a six-decimal replacement token.

`setFundToken` can replace the token globally while every `creditBalance` remains an untyped integer. Existing balances deposited in the old token are immediately interpreted as balances of the new token. Old tokens become stranded in the hub, and holders of old credit can withdraw or spend the same numeric amount of the new token if the hub receives new-token liquidity.

This requires an owner action, but an operational token migration or compromised owner can make the hub insolvent across users. The setter also accepts zero addresses and contracts with incompatible decimals or transfer behavior.

Recommendation:

- Make the billing token immutable, or implement a paused migration that settles all old credits before activating a new denomination.
- At minimum require zero outstanding aggregate credit, validate code and decimals, and emit migration-specific accounting events.

### P-L01: Successful jobs can be only partially billed while lifetime fees record the full charge

Severity: Low  
Affected code: `src/mainnet/private/PrivateAutomationHub.sol:540-592`

Risk decision: Acknowledged and accepted. The protocol accepts possible fee under-recovery when actual execution cost exceeds available prepaid credit and accepts that `totalGasFeePaid` represents assessed rather than necessarily collected fees.

Execution is pre-gated only by `minCreditThreshold`, not by a conservative estimate of the selected job's maximum fee. If realized gas cost plus markup exceeds available fund-token and points value, `_chargeGasFee` clips the token deduction to `creditBalance` after the successful job has run. It then adds the full theoretical `totalFee` to `totalGasFeePaid`, even though the treasury received less.

The threshold limits repeat abuse when correctly calibrated, so this is residual economic/configuration risk rather than unconditional free execution. It also makes `totalGasFeePaid` unsuitable as a collected-revenue metric.

Recommendation:

- Calibrate or enforce a per-job prepaid maximum before execution and separately track `feeAssessed` and `feeCollected`.
- Add tests where realized fee exceeds credit plus available point value.

### P-L02: Billing trader assignment has no recovery or rotation path

Severity: Low  
Affected code: `src/mainnet/private/PrivateAutomationHub.sol:370-381`, `src/mainnet/private/PrivateAutomationHub.sol:306-318`

Risk decision: Acknowledged and accepted. The protocol accepts immutable first-registration trader assignment and the associated operational risk of key loss or incorrect registration.

The first registrar to register a bot fixes `botBilling[bot].trader`; later upserts do not update it. Only that address can withdraw credit or change points-payment mode. A registrar mistake, trader-key loss, or legitimate account migration can therefore strand prepaid credit indefinitely.

Recommendation:

- Add a two-step trader rotation accepted by both the current and proposed trader, with a timelocked owner recovery path for lost keys.
- Ensure factory registration asserts that the stored trader matches the bot's `validTrader`.

## Reentrancy, Arithmetic, and Initialization Assessment

- No confirmed reentrancy exploit was found in the reviewed custody flows. Core deposits and settlements, LP settlement/swap, router deposit/redeem, trader entry/exit, and fee distribution generally use `nonReentrant`; state is burned or deleted before token transfers where appropriate in normal flows.
- Solidity 0.8 checked arithmetic prevents silent integer wraparound. The semantic direction issue originally reported as H-01 is remediated in the current worktree.
- `DoppiTrader`'s implementation constructor calls `_disableInitializers`, and factory clones are initialized in the same transaction in which they are created. No clone initialization front-run was identified.
- Both private trader implementations use the same protected initializer pattern. Same-transaction clone creation and initialization cannot be mempool-front-run.
- `updateImplementation` affects newly created clones, not existing clone storage. It should still validate `code.length`, interface compatibility, and ideally use a delayed two-step update to avoid deployment bricking.
- The reviewed contracts are not general delegatecall upgradeable proxies, so proxy storage collision and implementation self-destruction were not applicable to this scope.

## Centralization and Key-Compromise Impact

Owner and forwarder roles remain highly privileged. Depending on the contract, a compromised role can change price sources, DEX router/slippage, factory allowlists, fee destinations, implementation used for future bots, automation callers, or emergency state. These are expected trust assumptions, not permissionless exploits, but compromise can cause loss or prolonged denial of service.

Production controls should include multisig ownership, timelocks for economic configuration, separate emergency and routine-operation keys, on-chain monitoring, and tested role-revocation procedures. Entry points should be locked only after deployment wiring is verified.

## Rejected or Downgraded Candidates

- `getTotalBalances` uses named return variables; the absence of an explicit `return` does not make it return zeros.
- Uniswap V3 exact-output swaps either deliver the requested output or revert; they do not silently return less output. The relevant issue is the incorrect maximum input in H-01.
- OpenZeppelin's `+1` virtual asset/share terms in `ERC7575` are deliberate inflation-attack mitigation and were not treated as a vulnerability by themselves.
- Factory ownership of bots does not expose a generic call path by which the factory owner can invoke every bot's `onlyOwner` method. The factory can configure those methods only through code paths it actually implements.
- Rounding in sequential opportunity allocation assigns the residual to the final position because remaining output and remaining swapped amount are updated together; no orphaned-output exploit was confirmed.
- Grid sell-unwind comparison `strike >= price` is correct: the bot previously sold B for A and buys B back when market price falls below the entry strike.
- Private grid cost-bucket division can leave sub-wei rounding dust, but the final full-bucket consumption removes the remaining tracked cost; no compounding drain was demonstrated.
- The former grid `uint8` loop-overflow issue is fixed by `uint256` iteration and an explicit 256-zone cap in the current worktree.
- Private factory update setters now reject zero/non-contract implementations and out-of-range default fees. Constructor-time implementation validation is still recommended, but a bad initial implementation bricks deployment rather than exposing already funded bots.

## Validation and Test Gaps

Targeted validation performed during this review:

- Existing struck-sell shortfall test passed, confirming that the current mock masks production exact-output pricing behavior.
- Full Foundry run after report creation: 351 tests passed, 0 failed, 0 skipped across 30 suites.
- Focused private-module run after expanding scope: 65 tests passed, 0 failed, 0 skipped across 3 suites.
- Post-remediation Core, Core extension, Liquidity, Liquidity Router, and Trader run: 123 tests passed, 0 failed, 0 skipped across 6 suites.
- `test_emergencyWithdraw_resumesAfterUnrelatedPosition` passed and confirms that an emergency scan bounded to one inspected ID resumes on the next call without deleting another owner's position.
- Post-private-remediation run: 73 tests passed, 0 failed, 0 skipped across the Automation Hub, private simple trader, and private grid trader suites.
- Aggregate scheduler tests confirm cursor-only pagination and progress past an expensive target that consumes its allowance and returns false.
- Dynamic-points tests confirm non-V3 source rejection and fail-safe continuation of fund-token billing when the configured pool reverts.
- Billing-token migration tests confirm legacy-credit isolation and withdrawal, plus correct gas and points accounting for a six-decimal replacement token.
- Slippage-bound validation and affected Liquidity suites: 45 tests passed, 0 failed, including exact-boundary acceptance and over-bound rejection.

Priority tests to add:

1. Strict exact-output router tests for both directions of struck payout shortfall.
2. Three-owner emergency queue-hole regression test that settles both surviving positions.
3. LP emergency exit reverting with nonzero Core principal and interest liabilities.
4. Emergency transfer failure followed by retry with another receiver.
5. Gas tests with thousands of unrelated positions preceding a bot's position; bounded cursor behavior is already covered at small scale.
6. Settlement top-up tests asserting partial residual input enters unwind accounting and zero residual creates no target.
7. Private trader stop with unavailable primary and fallback prices.
8. A larger aggregate scheduler stress test with many consecutively expensive targets; bounded progress is already covered at small scale.
9. Fee-assessed-versus-collected tests if the accepted P-L01 accounting semantics are later changed.

## Remediation Priority

1. Add the remaining adversarial regression tests for remediated H-01, H-02, H-03, M-01, and M-03 before relying on the changed paths in production.
2. Add the remaining zero-price private-stop regression test for remediated P-M01.
3. Monitor the explicitly accepted P-L01 fee under-recovery and P-L02 immutable trader-assignment risks operationally.
4. Optionally lower the 3,000 bps hard slippage ceiling as production liquidity improves.
5. Optionally rename the points multiplier fields to clarify their intentionally global scope.

## Conclusion

The current worktree remediates all confirmed high- and medium-severity findings in both the shared mainnet and private-module paths, as well as L-02. Targeted post-remediation suites pass, including bounded resumable emergency scanning, aggregate scheduler gas bounds, failure-isolated dynamic points pricing, denomination-safe billing-token migration, and bounded liquidity slippage. Several adversarial tests remain recommended before production reliance, especially strict-router settlement, queue-hole, liability-gate, failed-transfer, residual-accounting, and zero-price private-stop cases. P-L01 and P-L02 are acknowledged and accepted without code changes.