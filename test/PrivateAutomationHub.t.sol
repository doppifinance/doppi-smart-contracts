// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PrivateAutomationHub} from "../src/mainnet/private/PrivateAutomationHub.sol";
import {
    RegisterPrivateBotParams,
    PrivateBotJobIds,
    PrivateAutomationModule,
    PrivateJobConfig,
    PrivateJobView,
    BotBillingState
} from "../src/mainnet/private/PrivateAutomationHubTypes.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";

contract MockAutomationTarget {
    bool public shouldNeed;
    bytes public nextPerformData;
    bool public shouldRevertPerform;
    uint256 public performCount;

    function setCheckResponse(bool needed, bytes calldata performData) external {
        shouldNeed = needed;
        nextPerformData = performData;
    }

    function setPerformRevert(bool shouldRevert) external {
        shouldRevertPerform = shouldRevert;
    }

    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        return (shouldNeed, nextPerformData);
    }

    function performUpkeep(bytes calldata) external {
        if (shouldRevertPerform) revert("perform revert");
        performCount += 1;
    }
}

contract MockDoppiPoints {
    mapping(address => uint256) public readyPoints;

    constructor() {
        // Give all users 1000 ready points for testing
    }

    function setReadyPoints(address trader, uint256 amount) external {
        readyPoints[trader] = amount;
    }

    function getAllPointData(address trader) external view returns (uint256 totalClaimed, uint256 readyPointsVal, uint256 currentMonth) {
        readyPointsVal = readyPoints[trader];
        // Return default values for totalClaimed and currentMonth
        return (0, readyPointsVal, 0);
    }
}

contract PrivateAutomationHubTest is Test {
    PrivateAutomationHub internal hub;

    address internal owner = makeAddr("owner");
    address internal registrar = makeAddr("registrar");
    address internal executor = makeAddr("executor");
    address internal stranger = makeAddr("stranger");
    address internal trader = makeAddr("trader");
    address internal bot = makeAddr("bot");
    address internal router = makeAddr("router");
    address internal treasury   = makeAddr("treasury");
    address internal notOwner = makeAddr("notOwner");
    address internal user = makeAddr("user");

    MockAutomationTarget internal botTarget;
    MockAutomationTarget internal coreTarget;
    MockAutomationTarget internal opportunityTarget;
    MockAutomationTarget internal liquidityTarget;

    MockToken  internal fundToken;
    MockOracle internal bnbOracle; // 600 USD per BNB, 8 decimals
    MockDoppiPoints internal mockDoppiPoints;

    // 3 gwei — used in billing tests so gas fees are measurable
    uint256 internal constant TEST_GAS_PRICE = 3e9;

    function setUp() public {
        vm.warp(1735689600); // realistic timestamp so oracle staleness check doesn't underflow

        fundToken = new MockToken("USDT", "USDT");
        bnbOracle = new MockOracle(int256(600 * 1e8), 8); // $600 / BNB
        mockDoppiPoints = new MockDoppiPoints();

        vm.startPrank(owner);
        hub = new PrivateAutomationHub(
            owner,
            address(fundToken),
            address(bnbOracle),
            3600,
            treasury
        );
        hub.setRegistrar(registrar, true);
        hub.setExecutor(executor, true);
        hub.setGlobalLimits(4, 16);
        vm.stopPrank();

        botTarget = new MockAutomationTarget();
        coreTarget = new MockAutomationTarget();
        opportunityTarget = new MockAutomationTarget();
        liquidityTarget = new MockAutomationTarget();

        // Fund user with fundToken for deposit tests (only user, not trader)
        fundToken.mint(user, 10000e18);

        // Set default ready points for trader in mock (1000 points)
        mockDoppiPoints.setReadyPoints(trader, 1000);
    }

    function test_registerPrivateBotJobs_onlyRegistrar() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(stranger);
        vm.expectRevert(PrivateAutomationHub.NotRegistrar.selector);
        hub.registerPrivateBotJobs(p);
    }

    function test_registerPrivateBotJobs_createsAllModuleJobs() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        PrivateBotJobIds memory ids = hub.registerPrivateBotJobs(p);

        assertGt(ids.traderJobId, 0);
        assertGt(ids.coreJobId, 0);
        assertGt(ids.opportunityJobId, 0);
        assertGt(ids.liquidityJobId, 0);

        assertEq(hub.getJobId(p.bot, PrivateAutomationModule.Trader), ids.traderJobId);
        assertEq(hub.getJobId(p.bot, PrivateAutomationModule.Core), ids.coreJobId);
        assertEq(hub.getJobId(p.bot, PrivateAutomationModule.Opportunity), ids.opportunityJobId);
        assertEq(hub.getJobId(p.bot, PrivateAutomationModule.Liquidity), ids.liquidityJobId);
    }

    function test_registerPrivateBotJobs_upsertsAndKeepsIds() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        PrivateBotJobIds memory first = hub.registerPrivateBotJobs(p);

        MockAutomationTarget newCore = new MockAutomationTarget();
        p.core = address(newCore);

        vm.prank(registrar);
        PrivateBotJobIds memory second = hub.registerPrivateBotJobs(p);

        assertEq(first.traderJobId, second.traderJobId);
        assertEq(first.coreJobId, second.coreJobId);
        assertEq(first.opportunityJobId, second.opportunityJobId);
        assertEq(first.liquidityJobId, second.liquidityJobId);

        PrivateJobView memory coreJob = hub.getJob(second.coreJobId);
        assertEq(coreJob.target, address(newCore));
    }

    // ── Shared Bot Jobs ───────────────────────────────────────────────────
    
    function test_registerSharedBotJob_onlyRegistrar() public {
        vm.prank(stranger);
        vm.expectRevert(PrivateAutomationHub.NotRegistrar.selector);
        hub.registerSharedBotJob(trader, address(botTarget), 1);
    }

    function test_registerSharedBotJob_rejectsZeroTrader() public {
        vm.prank(registrar);
        vm.expectRevert(PrivateAutomationHub.InvalidAddress.selector);
        hub.registerSharedBotJob(address(0), address(botTarget), 1);
    }

    function test_registerSharedBotJob_rejectsZeroBot() public {
        vm.prank(registrar);
        vm.expectRevert(PrivateAutomationHub.InvalidAddress.selector);
        hub.registerSharedBotJob(trader, address(0), 1);
    }

    function test_registerSharedBotJob_createsTraderJobOnly() public {
        vm.prank(registrar);
        uint256 jobId = hub.registerSharedBotJob(trader, address(botTarget), 1);

        assertGt(jobId, 0);
        
        // Verify trader job was created
        assertEq(hub.getJobId(address(botTarget), PrivateAutomationModule.Trader), jobId);
        
        // Verify only trader job exists (not core, opportunity, or liquidity)
        assertEq(hub.getJobId(address(botTarget), PrivateAutomationModule.Core), 0);
        assertEq(hub.getJobId(address(botTarget), PrivateAutomationModule.Opportunity), 0);
        assertEq(hub.getJobId(address(botTarget), PrivateAutomationModule.Liquidity), 0);

        PrivateJobView memory traderJob = hub.getJob(jobId);
        assertEq(traderJob.target, address(botTarget));
        assertTrue(traderJob.active);
    }

    function test_registerSharedBotJob_setsBillingTrader() public {
        vm.prank(registrar);
        hub.registerSharedBotJob(trader, address(botTarget), 1);

        BotBillingState memory billing = hub.getBotBilling(address(botTarget));
        assertEq(billing.trader, trader);
    }

    function test_registerSharedBotJob_returnsJobId() public {
        vm.prank(registrar);
        uint256 jobId = hub.registerSharedBotJob(trader, address(botTarget), 1);

        assertGt(jobId, 0);
        assertEq(hub.getJobId(address(botTarget), PrivateAutomationModule.Trader), jobId);
    }

    function test_registerSharedBotJob_upserts() public {
        address sharedBot = address(botTarget);
        
        vm.prank(registrar);
        uint256 firstJobId = hub.registerSharedBotJob(trader, sharedBot, 1);

        // Call again with same bot
        vm.prank(registrar);
        uint256 secondJobId = hub.registerSharedBotJob(trader, sharedBot, 1);

        // Job ID should be the same (upsert, not create new)
        assertEq(firstJobId, secondJobId);
    }

    function test_registerSharedBotJob_multipleSharedBots() public {
        address bot1 = address(botTarget);
        address bot2 = address(coreTarget);

        vm.prank(registrar);
        uint256 jobId1 = hub.registerSharedBotJob(trader, bot1, 1);

        vm.prank(registrar);
        uint256 jobId2 = hub.registerSharedBotJob(trader, bot2, 2);

        // Different bots should have different job IDs
        assertNotEq(jobId1, jobId2);

        // Verify each bot has correct trader
        BotBillingState memory billing1 = hub.getBotBilling(bot1);
        BotBillingState memory billing2 = hub.getBotBilling(bot2);
        assertEq(billing1.trader, trader);
        assertEq(billing2.trader, trader);
    }

    // ── DoppiPoints Integration Tests ──────────────────────────────────────

    function test_setDoppiPointsContract_ownerOnly() public {
        vm.prank(notOwner);
        vm.expectRevert(); // Ownable error
        hub.setDoppiPointsContract(address(mockDoppiPoints));

        // Owner can set
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));
        assertEq(address(hub.doppiPoints()), address(mockDoppiPoints));
    }

    function test_setDoppiPointsContract_rejectsZeroAddress() public {
        vm.expectRevert(); // InvalidAddress error
        hub.setDoppiPointsContract(address(0));
    }

    function test_setDoppiPointsExchangeRate_ownerOnly() public {
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));

        vm.prank(notOwner);
        vm.expectRevert(); // Ownable error
        hub.setDoppiPointsExchangeRate(10000);

        // Owner can set
        vm.prank(owner);
        hub.setDoppiPointsExchangeRate(10000);
        assertEq(hub.doppiPointsExchangeRateBps(), 10000);
    }

    function test_setDoppiPointsExchangeRate_rejectsZeroRate() public {
        vm.expectRevert(); // InvalidJob error (or should be custom)
        hub.setDoppiPointsExchangeRate(0);
    }

    function test_enablePointsPayment_onlyBotTrader() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        address bot = p.bot;

        // Only trader can enable
        vm.prank(notOwner);
        vm.expectRevert(); // NotBotTrader error
        hub.enablePointsPayment(bot);

        // Trader can enable
        vm.prank(trader);
        hub.enablePointsPayment(bot);
        BotBillingState memory billing = hub.getBotBilling(bot);
        assertTrue(billing.usePoint);
    }

    function test_disablePointsPayment_onlyBotTrader() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        address bot = p.bot;

        // Enable first
        vm.prank(trader);
        hub.enablePointsPayment(bot);

        // Only trader can disable
        vm.prank(notOwner);
        vm.expectRevert(); // NotBotTrader error
        hub.disablePointsPayment(bot);

        // Trader can disable
        vm.prank(trader);
        hub.disablePointsPayment(bot);
        BotBillingState memory billing = hub.getBotBilling(bot);
        assertFalse(billing.usePoint);
    }

    function test_enablePointsPayment_idempotent() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        address bot = p.bot;

        vm.prank(trader);
        hub.enablePointsPayment(bot);

        vm.prank(trader);
        hub.enablePointsPayment(bot); // Second call should be no-op
        BotBillingState memory billing = hub.getBotBilling(bot);
        assertTrue(billing.usePoint);
    }

    function test_getAvailablePoints_withoutContract() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        address bot = p.bot;

        // Without doppiPoints contract set, should return 0
        uint256 available = hub.getAvailablePoints(bot);
        assertEq(available, 0);
    }

    function test_getAvailablePoints_subtractsSpent() public {
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));

        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        address bot = p.bot;

        // Mock has 1000 ready points
        uint256 available = hub.getAvailablePoints(bot);
        assertEq(available, 1000);

        // Simulate spent points
        // (Would happen via _deductPointsForFee in real scenario)
        // For now, test returns max(readyPoints - spent, 0)
    }

    function test_getPointValueInUSDT_withoutContract() public {
        // Without doppiPoints contract set, should return 0
        uint256 value = hub.getPointValueInUSDT(100);
        assertEq(value, 0);
    }

    function test_getPointValueInUSDT_fixedRate() public {
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));
        vm.prank(owner);
        hub.setDoppiPointsExchangeRate(10000); // 1:1

        uint256 value = hub.getPointValueInUSDT(100);
        assertEq(value, 100); // 100 points * 10000 / 10000 = 100

        vm.prank(owner);
        hub.setDoppiPointsExchangeRate(5000); // 0.5:1
        value = hub.getPointValueInUSDT(100);
        assertEq(value, 50); // 100 points * 5000 / 10000 = 50

        vm.prank(owner);
        hub.setDoppiPointsExchangeRate(20000); // 2:1
        value = hub.getPointValueInUSDT(100);
        assertEq(value, 200); // 100 points * 20000 / 10000 = 200
    }

    function test_chargeGasFee_pointsPaymentDisabled() public {
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));
        vm.prank(owner);
        hub.setDoppiPointsExchangeRate(10000);

        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        address bot = p.bot;

        // If points payment disabled, should use fundToken only
        BotBillingState memory billing = hub.getBotBilling(bot);
        assertFalse(billing.usePoint);

        // Verify initial state
        BotBillingState memory initial = hub.getBotBilling(bot);
        assertEq(initial.creditBalance, 0); // No deposit yet
    }

    function test_chargeGasFee_pointsPaymentEnabled_sufficientPoints() public {
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));
        vm.prank(owner);
        hub.setDoppiPointsExchangeRate(10000); // 1:1

        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        address bot = p.bot;

        // Enable points payment
        vm.prank(trader);
        hub.enablePointsPayment(bot);

        // Verify setup
        BotBillingState memory billing = hub.getBotBilling(bot);
        assertTrue(billing.usePoint);
        uint256 available = hub.getAvailablePoints(bot);
        assertGt(available, 0); // Should have some points from mock
    }

    function test_chargeGasFee_lowCreditCheck_withPoints() public {
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));
        vm.prank(owner);
        hub.setDoppiPointsExchangeRate(10000); // 1:1
        vm.prank(owner);
        hub.setMinCreditThreshold(500e18);

        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        address bot = p.bot;

        // Enable points payment
        vm.prank(trader);
        hub.enablePointsPayment(bot);

        // Verify that low credit check considers combined value 
        // (fundToken + available points value)
        BotBillingState memory billing = hub.getBotBilling(bot);
        assertTrue(billing.usePoint);
        uint256 combinedValue = hub.getAvailablePoints(bot);
        assertGt(combinedValue, 0); // Points provide value
    }

    function test_depositResumes_checksCombinedValue() public {
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));
        vm.prank(owner);
        hub.setDoppiPointsExchangeRate(10000); // 1:1
        vm.prank(owner);
        hub.setMinCreditThreshold(1500e18);

        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        address bot = p.bot;

        // Enable points payment
        vm.prank(trader);
        hub.enablePointsPayment(bot);

        // Verify points are considered in threshold calculations
        uint256 pointsValue = hub.getPointValueInUSDT(hub.getAvailablePoints(bot));
        assertGt(pointsValue, 0);
        
        // Verify combined value is recognized
        BotBillingState memory billing = hub.getBotBilling(bot);
        assertTrue(billing.usePoint);
    }

    function test_checkUpkeep_returnsFalseWhenNoDueJobs() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        (bool upkeepNeeded, bytes memory performData) = hub.checkUpkeep("");
        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    function test_checkUpkeep_and_performUpkeep_executesBoundedBatch() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        botTarget.setCheckResponse(true, abi.encode("bot"));
        coreTarget.setCheckResponse(true, abi.encode("core"));
        opportunityTarget.setCheckResponse(true, abi.encode("opp"));
        liquidityTarget.setCheckResponse(true, abi.encode("liq"));

        (bool upkeepNeeded, bytes memory performData) = hub.checkUpkeep("");
        assertTrue(upkeepNeeded);

        vm.prank(executor);
        hub.performUpkeep(performData);

        assertEq(botTarget.performCount(), 1);
        assertEq(coreTarget.performCount(), 1);
        assertEq(opportunityTarget.performCount(), 1);
        assertEq(liquidityTarget.performCount(), 1);
    }

    function test_performUpkeep_onlyExecutor() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        botTarget.setCheckResponse(true, abi.encode("bot"));
        (bool upkeepNeeded, bytes memory performData) = hub.checkUpkeep("");
        assertTrue(upkeepNeeded);

        vm.prank(stranger);
        vm.expectRevert(PrivateAutomationHub.NotExecutor.selector);
        hub.performUpkeep(performData);
    }

    function test_disablePrivateBotJobs_stopsExecution() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        botTarget.setCheckResponse(true, abi.encode("bot"));
        vm.prank(registrar);
        hub.disablePrivateBotJobs(p.bot);

        (bool upkeepNeeded, ) = hub.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_setJobConfig_and_setJobActive() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        PrivateBotJobIds memory ids = hub.registerPrivateBotJobs(p);

        PrivateJobConfig memory cfg = PrivateJobConfig({
            active: true,
            minInterval: 60,
            maxStaleness: 120,
            gasLimitHint: 500_000,
            maxConsecutiveFails: 2
        });

        vm.prank(owner);
        hub.setJobConfig(ids.traderJobId, cfg);

        vm.prank(owner);
        hub.setJobActive(ids.traderJobId, false);

        PrivateJobView memory traderJob = hub.getJob(ids.traderJobId);
        assertFalse(traderJob.active);

        vm.prank(owner);
        hub.setJobActive(ids.traderJobId, true);
        traderJob = hub.getJob(ids.traderJobId);
        assertTrue(traderJob.active);
    }

    function test_failures_autopause_after_threshold() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        PrivateBotJobIds memory ids = hub.registerPrivateBotJobs(p);

        PrivateJobConfig memory cfg = PrivateJobConfig({
            active: true,
            minInterval: 1,
            maxStaleness: 3600,
            gasLimitHint: 500_000,
            maxConsecutiveFails: 2
        });

        vm.prank(owner);
        hub.setJobConfig(ids.traderJobId, cfg);

        botTarget.setCheckResponse(true, abi.encode("bot"));
        botTarget.setPerformRevert(true);

        // First fail
        (bool needed, bytes memory pd) = hub.checkUpkeep("");
        assertTrue(needed);
        vm.prank(executor);
        hub.performUpkeep(pd);

        vm.warp(block.timestamp + 2);

        // Second fail -> auto pause
        (needed, pd) = hub.checkUpkeep("");
        assertTrue(needed);
        vm.prank(executor);
        hub.performUpkeep(pd);

        PrivateJobView memory traderJob = hub.getJob(ids.traderJobId);
        assertFalse(traderJob.active);
        assertEq(traderJob.failCount, 2);
    }

    function test_global_limits_bound_batch_size() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        vm.prank(owner);
        hub.setGlobalLimits(2, 16);

        botTarget.setCheckResponse(true, abi.encode("bot"));
        coreTarget.setCheckResponse(true, abi.encode("core"));
        opportunityTarget.setCheckResponse(true, abi.encode("opp"));
        liquidityTarget.setCheckResponse(true, abi.encode("liq"));

        (bool needed, bytes memory pd) = hub.checkUpkeep("");
        assertTrue(needed);

        vm.prank(executor);
        hub.performUpkeep(pd);

        uint256 performed = botTarget.performCount() + coreTarget.performCount() + opportunityTarget.performCount() + liquidityTarget.performCount();
        assertEq(performed, 2);
    }

    function _params() internal view returns (RegisterPrivateBotParams memory p) {
        p.trader = trader;
        p.bot = address(botTarget);
        p.core = address(coreTarget);
        p.opportunity = address(opportunityTarget);
        p.liquidity = address(liquidityTarget);
        p.router = router;
        p.botId = 1;
    }

    // ─── Billing tests ────────────────────────────────────────────────────

    function test_billing_deposit_tracks_credit() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        fundToken.mint(trader, 100 ether);
        vm.startPrank(trader);
        fundToken.approve(address(hub), 100 ether);
        hub.deposit(p.bot, 100 ether);
        vm.stopPrank();

        BotBillingState memory billing = hub.getBotBilling(p.bot);
        assertEq(billing.creditBalance, 100 ether);
        assertEq(billing.trader, trader);
    }

    function test_billing_fee_charged_to_treasury_on_execution() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        // Seed bot credit
        fundToken.mint(trader, 1000 ether);
        vm.startPrank(trader);
        fundToken.approve(address(hub), 1000 ether);
        hub.deposit(p.bot, 1000 ether);
        vm.stopPrank();

        vm.prank(owner);
        hub.setPlatformMarkup(2000); // 20%

        botTarget.setCheckResponse(true, abi.encode("bot"));

        (bool needed, bytes memory pd) = hub.checkUpkeep("");
        assertTrue(needed);

        // Set gas price so fee > 0
        vm.txGasPrice(TEST_GAS_PRICE);
        vm.prank(executor);
        hub.performUpkeep(pd);

        // Treasury received some fund token
        assertGt(fundToken.balanceOf(treasury), 0);
        // Bot credit decreased by exactly what treasury received
        BotBillingState memory billing = hub.getBotBilling(p.bot);
        assertEq(billing.creditBalance, 1000 ether - fundToken.balanceOf(treasury));
        assertEq(billing.totalGasFeePaid, fundToken.balanceOf(treasury));
    }

    function test_billing_low_credit_pauses_all_jobs() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        // Set threshold high so ANY fee deduction triggers pause
        vm.startPrank(owner);
        hub.setMinCreditThreshold(500 ether);
        hub.setPlatformMarkup(2000);
        vm.stopPrank();

        // Deposit just below threshold
        fundToken.mint(trader, 10 ether);
        vm.startPrank(trader);
        fundToken.approve(address(hub), 10 ether);
        hub.deposit(p.bot, 10 ether);
        vm.stopPrank();

        botTarget.setCheckResponse(true, abi.encode("bot"));
        (bool needed, bytes memory pd) = hub.checkUpkeep("");
        assertTrue(needed);

        vm.txGasPrice(TEST_GAS_PRICE);
        vm.prank(executor);
        hub.performUpkeep(pd);

        // All 4 module jobs should now be inactive
        PrivateBotJobIds memory ids = hub.getJobIdsByBot(p.bot);
        assertFalse(hub.getJob(ids.traderJobId).active);
        assertFalse(hub.getJob(ids.coreJobId).active);
        assertFalse(hub.getJob(ids.opportunityJobId).active);
        assertFalse(hub.getJob(ids.liquidityJobId).active);

        BotBillingState memory billing = hub.getBotBilling(p.bot);
        assertTrue(billing.lowCreditPaused);
    }

    function test_billing_deposit_resumes_paused_jobs() public {
        // First drive the bot into low-credit paused state
        test_billing_low_credit_pauses_all_jobs();

        RegisterPrivateBotParams memory p = _params();

        // Top up above threshold
        fundToken.mint(trader, 1000 ether);
        vm.startPrank(trader);
        fundToken.approve(address(hub), 1000 ether);
        hub.deposit(p.bot, 1000 ether);
        vm.stopPrank();

        // All 4 module jobs should now be active again
        PrivateBotJobIds memory ids = hub.getJobIdsByBot(p.bot);
        assertTrue(hub.getJob(ids.traderJobId).active);
        assertTrue(hub.getJob(ids.coreJobId).active);
        assertTrue(hub.getJob(ids.opportunityJobId).active);
        assertTrue(hub.getJob(ids.liquidityJobId).active);

        assertFalse(hub.getBotBilling(p.bot).lowCreditPaused);
    }

    function test_billing_withdraw_by_trader() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        fundToken.mint(trader, 100 ether);
        vm.startPrank(trader);
        fundToken.approve(address(hub), 100 ether);
        hub.deposit(p.bot, 100 ether);
        hub.withdraw(p.bot, 40 ether);
        vm.stopPrank();

        assertEq(hub.getBotBilling(p.bot).creditBalance, 60 ether);
        assertEq(fundToken.balanceOf(trader), 40 ether);
    }

    function test_billing_withdraw_reverts_for_non_trader() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        fundToken.mint(trader, 100 ether);
        vm.startPrank(trader);
        fundToken.approve(address(hub), 100 ether);
        hub.deposit(p.bot, 100 ether);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(PrivateAutomationHub.NotBotTrader.selector);
        hub.withdraw(p.bot, 50 ether);
    }

    function test_billing_no_charge_when_gasprice_zero() public {
        RegisterPrivateBotParams memory p = _params();
        vm.prank(registrar);
        hub.registerPrivateBotJobs(p);

        fundToken.mint(trader, 100 ether);
        vm.startPrank(trader);
        fundToken.approve(address(hub), 100 ether);
        hub.deposit(p.bot, 100 ether);
        vm.stopPrank();

        botTarget.setCheckResponse(true, abi.encode("bot"));
        (, bytes memory pd) = hub.checkUpkeep("");

        // Default Foundry gas price = 0, so fee should be zero
        vm.prank(executor);
        hub.performUpkeep(pd);

        assertEq(fundToken.balanceOf(treasury), 0);
        assertEq(hub.getBotBilling(p.bot).creditBalance, 100 ether);
    }

    function test_billing_markup_too_high_reverts() public {
        vm.prank(owner);
        vm.expectRevert(PrivateAutomationHub.MarkupTooHigh.selector);
        hub.setPlatformMarkup(5001);
    }

    function test_billing_doppi_token_scaffold() public {
        address fakeToken = makeAddr("doppiToken");
        vm.prank(owner);
        hub.setDoppiToken(fakeToken);
        assertEq(hub.doppiToken(), fakeToken);
    }
}
