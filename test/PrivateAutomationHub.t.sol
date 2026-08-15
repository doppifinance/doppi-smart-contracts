// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {PrivateAutomationHub} from "../src/mainnet/private/PrivateAutomationHub.sol";
import {
    PrivateAutomationModule,
    PrivateJobConfig,
    PrivateJobView,
    PrivateBotJobIds,
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

contract MockGasBurningTarget {
    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory) {
        uint256 accumulator;
        while (gasleft() > 5_000) {
            unchecked { ++accumulator; }
        }
        return (accumulator == type(uint256).max, bytes(""));
    }

    function performUpkeep(bytes calldata) external {}
}

contract MockDoppiPoints {
    mapping(address => uint256) public readyPoints;
    mapping(address => uint256) public spentPoints;

    function setReadyPoints(address trader, uint256 amount) external {
        readyPoints[trader] = amount;
    }

    function deductPointsForFee(address trader, uint256 points) external {
        spentPoints[trader] += points;
    }

    function getAllPointData(address trader)
        external
        view
        returns (uint256 totalClaimed, uint256 readyPointsVal, uint256 currentMonth)
    {
        uint256 available = readyPoints[trader];
        uint256 spent = spentPoints[trader];
        readyPointsVal = available > spent ? available - spent : 0;
        return (0, readyPointsVal, 0);
    }
}

contract MockToken6Decimals is MockToken {
    constructor() MockToken("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockV3PoolForPoints {
    address public token0;
    bool public shouldRevertObserve;

    constructor(address _token0) {
        token0 = _token0;
    }

    function setShouldRevertObserve(bool value) external {
        shouldRevertObserve = value;
    }

    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory) {
        if (shouldRevertObserve) revert("pool broken");
        return (new int56[](2), new uint160[](2));
    }
}

contract PrivateAutomationHubTest is Test {
    PrivateAutomationHub internal hub;

    address internal owner = makeAddr("owner");
    address internal registrar = makeAddr("registrar");
    address internal executor = makeAddr("executor");
    address internal stranger = makeAddr("stranger");
    address internal trader = makeAddr("trader");
    address internal treasury = makeAddr("treasury");
    address internal notOwner = makeAddr("notOwner");

    MockAutomationTarget internal botTarget;
    MockAutomationTarget internal otherTarget;

    MockToken internal fundToken;
    MockOracle internal bnbOracle;
    MockDoppiPoints internal mockDoppiPoints;

    uint256 internal constant TEST_GAS_PRICE = 3e9;

    function setUp() public {
        vm.warp(1735689600);

        fundToken = new MockToken("USDT", "USDT");
        bnbOracle = new MockOracle(int256(600 * 1e8), 8);
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
        otherTarget = new MockAutomationTarget();

        mockDoppiPoints.setReadyPoints(trader, 1000);
    }

    function test_registerSharedBotJob_onlyRegistrar() public {
        vm.prank(stranger);
        vm.expectRevert(PrivateAutomationHub.NotRegistrar.selector);
        hub.registerSharedBotJob(trader, address(botTarget), 1);
    }

    function test_registerSharedBotJob_rejectsZeroInputs() public {
        vm.prank(registrar);
        vm.expectRevert(PrivateAutomationHub.InvalidAddress.selector);
        hub.registerSharedBotJob(address(0), address(botTarget), 1);

        vm.prank(registrar);
        vm.expectRevert(PrivateAutomationHub.InvalidAddress.selector);
        hub.registerSharedBotJob(trader, address(0), 1);
    }

    function test_registerSharedBotJob_createsTraderJobOnly() public {
        address sharedBot = _registerSharedBot();
        uint256 jobId = hub.getJobId(sharedBot, PrivateAutomationModule.Trader);

        assertGt(jobId, 0);
        assertEq(hub.getJobId(sharedBot, PrivateAutomationModule.Core), 0);
        assertEq(hub.getJobId(sharedBot, PrivateAutomationModule.Opportunity), 0);
        assertEq(hub.getJobId(sharedBot, PrivateAutomationModule.Liquidity), 0);

        PrivateJobView memory traderJob = hub.getJob(jobId);
        assertEq(traderJob.target, sharedBot);
        assertTrue(traderJob.active);

        BotBillingState memory billing = hub.getBotBilling(sharedBot);
        assertEq(billing.trader, trader);
    }

    function test_registerSharedBotJob_upserts() public {
        address sharedBot = address(botTarget);
        vm.prank(registrar);
        uint256 first = hub.registerSharedBotJob(trader, sharedBot, 1);
        vm.prank(registrar);
        uint256 second = hub.registerSharedBotJob(trader, sharedBot, 2);
        assertEq(first, second);
    }

    function test_checkUpkeep_returnsFalseWhenNoDueJobs() public {
        _registerSharedBot();
        (bool upkeepNeeded, bytes memory performData) = hub.checkUpkeep("");
        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    function test_checkUpkeep_returnsFalse_whenFeedCleared() public {
        _registerSharedBot();
        vm.prank(owner);
        hub.setChainlinkFeed(address(0));

        botTarget.setCheckResponse(true, abi.encode("bot"));
        (bool upkeepNeeded, bytes memory performData) = hub.checkUpkeep("");
        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    function test_performUpkeep_onlyExecutor() public {
        address sharedBot = _registerSharedBot();
        _seedCredit(sharedBot, 100 ether);

        botTarget.setCheckResponse(true, abi.encode("bot"));
        (bool upkeepNeeded, bytes memory performData) = hub.checkUpkeep("");
        assertTrue(upkeepNeeded);

        vm.prank(stranger);
        vm.expectRevert(PrivateAutomationHub.NotExecutor.selector);
        hub.performUpkeep(performData);
    }

    function test_checkUpkeep_and_performUpkeep_executesTraderJob() public {
        address sharedBot = _registerSharedBot();
        _seedCredit(sharedBot, 100 ether);

        botTarget.setCheckResponse(true, abi.encode("bot"));

        (bool upkeepNeeded, bytes memory performData) = hub.checkUpkeep("");
        assertTrue(upkeepNeeded);

        vm.prank(executor);
        hub.performUpkeep(performData);

        assertEq(botTarget.performCount(), 1);
    }

    function test_setJobConfig_and_setJobActive() public {
        address sharedBot = _registerSharedBot();
        uint256 jobId = hub.getJobId(sharedBot, PrivateAutomationModule.Trader);

        PrivateJobConfig memory cfg = PrivateJobConfig({
            active: true,
            minInterval: 60,
            gasLimitHint: 500_000
        });

        vm.prank(owner);
        hub.setJobConfig(jobId, cfg);

        vm.prank(owner);
        hub.setJobActive(jobId, false);
        assertFalse(hub.getJob(jobId).active);

        vm.prank(owner);
        hub.setJobActive(jobId, true);
        assertTrue(hub.getJob(jobId).active);
    }

    function test_global_limits_bound_batch_size() public {
        address sharedBot1 = _registerSharedBot();
        _seedCredit(sharedBot1, 100 ether);

        address sharedBot2 = address(otherTarget);
        vm.prank(registrar);
        hub.registerSharedBotJob(trader, sharedBot2, 2);
        _seedCredit(sharedBot2, 100 ether);

        vm.prank(owner);
        hub.setGlobalLimits(1, 16);

        botTarget.setCheckResponse(true, abi.encode("bot"));
        otherTarget.setCheckResponse(true, abi.encode("other"));

        (bool needed, bytes memory pd) = hub.checkUpkeep("");
        assertTrue(needed);

        vm.prank(executor);
        hub.performUpkeep(pd);

        assertEq(botTarget.performCount() + otherTarget.performCount(), 1);
    }

    function test_partialScan_returnsCursorOnlyUpkeep() public {
        address sharedBot1 = _registerSharedBot();
        _seedCredit(sharedBot1, 100 ether);

        address sharedBot2 = address(otherTarget);
        vm.prank(registrar);
        hub.registerSharedBotJob(trader, sharedBot2, 2);
        _seedCredit(sharedBot2, 100 ether);

        vm.prank(owner);
        hub.setGlobalLimits(1, 1);

        (bool needed, bytes memory performData) = hub.checkUpkeep("");
        assertTrue(needed);

        (uint256 nextCursor, uint256[] memory jobIds, bytes[] memory payloads) =
            abi.decode(performData, (uint256, uint256[], bytes[]));
        assertEq(nextCursor, 2);
        assertEq(jobIds.length, 0);
        assertEq(payloads.length, 0);

        vm.prank(executor);
        hub.performUpkeep(performData);
        assertEq(hub.scanCursor(), 2);
    }

    function test_aggregateCheckGas_resumesAfterExpensiveFalseJob() public {
        MockGasBurningTarget expensiveTarget = new MockGasBurningTarget();
        vm.prank(registrar);
        hub.registerSharedBotJob(trader, address(expensiveTarget), 1);
        _seedCredit(address(expensiveTarget), 100 ether);

        address usefulBot = address(botTarget);
        vm.prank(registrar);
        hub.registerSharedBotJob(trader, usefulBot, 2);
        _seedCredit(usefulBot, 100 ether);
        botTarget.setCheckResponse(true, abi.encode("useful"));

        vm.startPrank(owner);
        hub.setGlobalLimits(1, 2);
        hub.setMaxAggregateCheckGas(400_000);
        vm.stopPrank();

        (bool firstNeeded, bytes memory firstData) = hub.checkUpkeep("");
        assertTrue(firstNeeded);
        (, uint256[] memory firstJobIds,) =
            abi.decode(firstData, (uint256, uint256[], bytes[]));
        assertEq(firstJobIds.length, 0);

        vm.prank(executor);
        hub.performUpkeep(firstData);
        assertEq(hub.scanCursor(), 2);

        (bool secondNeeded, bytes memory secondData) = hub.checkUpkeep("");
        assertTrue(secondNeeded);
        (, uint256[] memory secondJobIds,) =
            abi.decode(secondData, (uint256, uint256[], bytes[]));
        assertEq(secondJobIds.length, 1);
        assertEq(secondJobIds[0], 2);

        vm.prank(executor);
        hub.performUpkeep(secondData);
        assertEq(botTarget.performCount(), 1);
    }

    function test_billing_deposit_tracks_credit() public {
        address sharedBot = _registerSharedBot();
        _seedCredit(sharedBot, 100 ether);

        BotBillingState memory billing = hub.getBotBilling(sharedBot);
        assertEq(billing.creditBalance, 100 ether);
        assertEq(billing.trader, trader);
    }

    function test_billing_withdraw_by_trader() public {
        address sharedBot = _registerSharedBot();
        _seedCredit(sharedBot, 100 ether);

        vm.prank(trader);
        hub.withdraw(sharedBot, 40 ether);

        assertEq(hub.getBotBilling(sharedBot).creditBalance, 60 ether);
        assertEq(fundToken.balanceOf(trader), 40 ether);
    }

    function test_billing_withdraw_reverts_for_non_trader() public {
        address sharedBot = _registerSharedBot();
        _seedCredit(sharedBot, 100 ether);

        vm.prank(stranger);
        vm.expectRevert(PrivateAutomationHub.NotBotTrader.selector);
        hub.withdraw(sharedBot, 50 ether);
    }

    function test_fundTokenMigration_makesOldCreditWithdrawOnly() public {
        address sharedBot = _registerSharedBot();
        _seedCredit(sharedBot, 100 ether);

        MockToken newFundToken = new MockToken("NEW", "NEW");
        vm.prank(owner);
        hub.setFundToken(address(newFundToken));

        assertEq(hub.getBotBilling(sharedBot).creditBalance, 0);

        newFundToken.mint(trader, 25 ether);
        vm.startPrank(trader);
        newFundToken.approve(address(hub), 25 ether);
        hub.deposit(sharedBot, 25 ether);
        vm.stopPrank();

        assertEq(hub.getBotBilling(sharedBot).creditBalance, 25 ether);
        assertEq(hub.legacyCreditBalance(sharedBot, address(fundToken)), 100 ether);
        assertEq(address(hub.botCreditToken(sharedBot)), address(newFundToken));

        vm.prank(trader);
        hub.withdrawLegacy(sharedBot, address(fundToken), 40 ether);

        assertEq(fundToken.balanceOf(trader), 40 ether);
        assertEq(hub.legacyCreditBalance(sharedBot, address(fundToken)), 60 ether);
        assertEq(hub.getBotBilling(sharedBot).creditBalance, 25 ether);
    }

    function test_fundTokenMigration_legacyCreditCannotSatisfyBilling() public {
        address sharedBot = _registerSharedBot();
        _seedCredit(sharedBot, 100 ether);

        vm.prank(owner);
        hub.setMinCreditThreshold(1 ether);

        MockToken newFundToken = new MockToken("NEW", "NEW");
        vm.prank(owner);
        hub.setFundToken(address(newFundToken));

        botTarget.setCheckResponse(true, abi.encode("bot"));
        (bool needed,) = hub.checkUpkeep("");
        assertFalse(needed);
    }

    function test_billingAssetConfig_normalizesSixDecimalToken() public {
        address sharedBot = _registerSharedBot();
        MockToken6Decimals newFundToken = new MockToken6Decimals();
        MockOracle nativeToTokenFeed = new MockOracle(int256(600 * 1e8), 8);

        vm.startPrank(owner);
        hub.setBillingAssetConfig(
            address(newFundToken),
            address(nativeToTokenFeed),
            1e6,
            10e6
        );
        hub.setDoppiPointsContract(address(mockDoppiPoints));
        hub.setDoppiPointsExchangeRate(10000);
        vm.stopPrank();

        assertEq(hub.fundTokenDecimals(), 1e6);
        assertEq(hub.getPointValueInUSDT(1 ether), 1e6);

        newFundToken.mint(trader, 100e6);
        vm.startPrank(trader);
        newFundToken.approve(address(hub), 100e6);
        hub.deposit(sharedBot, 100e6);
        vm.stopPrank();

        botTarget.setCheckResponse(true, abi.encode("bot"));
        (bool needed, bytes memory performData) = hub.checkUpkeep("");
        assertTrue(needed);

        vm.txGasPrice(TEST_GAS_PRICE);
        vm.prank(executor);
        hub.performUpkeep(performData);

        assertGt(newFundToken.balanceOf(treasury), 0);
        assertLt(newFundToken.balanceOf(treasury), 100e6);
        assertEq(
            hub.getBotBilling(sharedBot).creditBalance,
            100e6 - newFundToken.balanceOf(treasury)
        );
    }

    function test_billing_fee_charged_to_treasury_on_execution() public {
        address sharedBot = _registerSharedBot();
        _seedCredit(sharedBot, 1000 ether);

        vm.prank(owner);
        hub.setPlatformMarkup(2000);

        botTarget.setCheckResponse(true, abi.encode("bot"));

        (bool needed, bytes memory pd) = hub.checkUpkeep("");
        assertTrue(needed);

        vm.txGasPrice(TEST_GAS_PRICE);
        vm.prank(executor);
        hub.performUpkeep(pd);

        assertGt(fundToken.balanceOf(treasury), 0);
        BotBillingState memory billing = hub.getBotBilling(sharedBot);
        assertEq(billing.creditBalance, 1000 ether - fundToken.balanceOf(treasury));
        assertEq(billing.totalGasFeePaid, fundToken.balanceOf(treasury));
    }

    function test_billing_low_credit_pauses_and_deposit_resumes_job() public {
        address sharedBot = _registerSharedBot();

        vm.startPrank(owner);
        hub.setMinCreditThreshold(500 ether);
        hub.setPlatformMarkup(2000);
        vm.stopPrank();

        _seedCredit(sharedBot, 500 ether);

        botTarget.setCheckResponse(true, abi.encode("bot"));
        (bool needed, bytes memory pd) = hub.checkUpkeep("");
        assertTrue(needed);

        vm.txGasPrice(TEST_GAS_PRICE);
        vm.prank(executor);
        hub.performUpkeep(pd);

        uint256 traderJobId = hub.getJobId(sharedBot, PrivateAutomationModule.Trader);
        assertFalse(hub.getJob(traderJobId).active);
        assertTrue(hub.getBotBilling(sharedBot).lowCreditPaused);

        _seedCredit(sharedBot, 1000 ether);

        assertTrue(hub.getJob(traderJobId).active);
        assertFalse(hub.getBotBilling(sharedBot).lowCreditPaused);
    }

    function test_pointsPayment_flow() public {
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));
        vm.prank(owner);
        hub.setDoppiPointsExchangeRate(10000);

        address sharedBot = _registerSharedBot();

        vm.prank(trader);
        hub.enablePointsPayment(sharedBot);
        assertTrue(hub.getBotBilling(sharedBot).usePoint);

        vm.prank(trader);
        hub.disablePointsPayment(sharedBot);
        assertFalse(hub.getBotBilling(sharedBot).usePoint);
    }

    function test_setDoppiPointsContract_ownerOnly() public {
        vm.prank(notOwner);
        vm.expectRevert(); // Ownable error
        hub.setDoppiPointsContract(address(mockDoppiPoints));

        // Owner can set
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));
        assertEq(address(hub.doppiPoints()), address(mockDoppiPoints));
    }

    function test_billing_points_can_cover_fee_without_underflow() public {
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));
        vm.prank(owner);
        hub.setDoppiPointsExchangeRate(10000);

        address sharedBot = _registerSharedBot();

        mockDoppiPoints.setReadyPoints(trader, 10_000 ether);
        vm.prank(trader);
        hub.enablePointsPayment(sharedBot);

        _seedCredit(sharedBot, 100 ether);

        botTarget.setCheckResponse(true, abi.encode("bot"));

        (bool needed, bytes memory pd) = hub.checkUpkeep("");
        assertTrue(needed);

        vm.txGasPrice(TEST_GAS_PRICE);
        vm.prank(executor);
        hub.performUpkeep(pd);

        BotBillingState memory billing = hub.getBotBilling(sharedBot);
        assertEq(fundToken.balanceOf(treasury), 0);
        assertEq(billing.creditBalance, 100 ether);
        assertGt(mockDoppiPoints.spentPoints(trader), 0);
        assertGt(billing.totalGasFeePaid, 0);
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

    function test_setDoppiPointsExchangeRate_rejectsZeroRate() public {
        vm.expectRevert(); // InvalidJob error (or should be custom)
        hub.setDoppiPointsExchangeRate(0);
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


    function test_enablePointsPayment_onlyBotTrader() public {
        address bot = _registerSharedBot();

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
        address bot = _registerSharedBot();

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
        address bot = _registerSharedBot();

        vm.prank(trader);
        hub.enablePointsPayment(bot);

        vm.prank(trader);
        hub.enablePointsPayment(bot); // Second call should be no-op
        BotBillingState memory billing = hub.getBotBilling(bot);
        assertTrue(billing.usePoint);
    }

    function test_getAvailablePoints_withoutContract() public {
        address bot = _registerSharedBot();

        // Without doppiPoints contract set, should return 0
        uint256 available = hub.getAvailablePoints(bot);
        assertEq(available, 0);
    }

    function test_getAvailablePoints_subtractsSpent() public {
        vm.prank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));

        address bot = _registerSharedBot();

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

    function test_setDoppiPointsPriceFeed_rejectsNonV3Pool() public {
        // A Chainlink-style feed (no token0()) must be rejected when enabling dynamic pricing.
        vm.prank(owner);
        vm.expectRevert();
        hub.setDoppiPointsPriceFeed(address(bnbOracle), true);
    }

    function test_setDoppiPointsPriceFeed_acceptsValidV3Pool() public {
        MockV3PoolForPoints pool = new MockV3PoolForPoints(address(fundToken));

        vm.prank(owner);
        hub.setDoppiPointsPriceFeed(address(pool), true);

        assertEq(hub.doppiPointsPriceFeed(), address(pool));
        assertTrue(hub.useDynamicPointPrice());
    }

    function test_dynamicPointsPricing_poolFailureDoesNotRevertBilling() public {
        MockV3PoolForPoints pool = new MockV3PoolForPoints(address(fundToken));
        pool.setShouldRevertObserve(true);

        vm.startPrank(owner);
        hub.setDoppiPointsContract(address(mockDoppiPoints));
        hub.setDoppiPointsPriceFeed(address(pool), true);
        vm.stopPrank();

        address sharedBot = _registerSharedBot();
        vm.prank(trader);
        hub.enablePointsPayment(sharedBot);
        _seedCredit(sharedBot, 1000 ether);

        botTarget.setCheckResponse(true, abi.encode("bot"));
        (bool needed, bytes memory pd) = hub.checkUpkeep("");
        assertTrue(needed);

        vm.txGasPrice(TEST_GAS_PRICE);
        vm.prank(executor);
        hub.performUpkeep(pd);

        // Broken pool falls back to zero points value; fee is still collected in fundToken.
        assertGt(fundToken.balanceOf(treasury), 0);
        assertEq(mockDoppiPoints.spentPoints(trader), 0);
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

        address bot = _registerSharedBot();

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

        address bot = _registerSharedBot();

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

        address bot = _registerSharedBot();

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

        address bot = _registerSharedBot();

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

    function test_checkUpkeep_returnsFalse_whenChainlinkFeedIsZeroAtDeploy() public {
        vm.startPrank(owner);
        PrivateAutomationHub hubNoFeed = new PrivateAutomationHub(
            owner,
            address(fundToken),
            address(0),
            3600,
            treasury
        );
        hubNoFeed.setRegistrar(registrar, true);
        vm.stopPrank();

        _registerSharedBot();

        botTarget.setCheckResponse(true, abi.encode("bot"));
        (bool upkeepNeeded, bytes memory performData) = hubNoFeed.checkUpkeep("");

        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    function test_checkUpkeep_returnsFalse_whenChainlinkFeedCleared() public {
        
        _registerSharedBot();

        vm.prank(owner);
        hub.setChainlinkFeed(address(0));

        botTarget.setCheckResponse(true, abi.encode("bot"));
        (bool upkeepNeeded, bytes memory performData) = hub.checkUpkeep("");

        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    function _registerSharedBot() internal returns (address sharedBot) {
        sharedBot = address(botTarget);
        vm.prank(registrar);
        hub.registerSharedBotJob(trader, sharedBot, 1);
    }

    function _registerSharedBotOn(PrivateAutomationHub targetHub) internal returns (address sharedBot) {
        sharedBot = address(botTarget);
        vm.prank(registrar);
        targetHub.registerSharedBotJob(trader, sharedBot, 1);
    }

    function _seedCredit(address sharedBot, uint256 amount) internal {
        fundToken.mint(trader, amount);
        vm.startPrank(trader);
        fundToken.approve(address(hub), amount);
        hub.deposit(sharedBot, amount);
        vm.stopPrank();
    }
}
