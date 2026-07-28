// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {Swapper} from "../src/test/Swapper.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {DoppiOffer} from "../src/mainnet/DoppiOffer.sol";
import {DoppiPoints} from "../src/mainnet/DoppiPoints.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiTraderFactory} from "../src/mainnet/DoppiTraderFactory.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiFeePool} from "../src/mainnet/DoppiFeePool.sol";
import {ConfigParam} from "../src/mainnet/DoppiLiquidityTypes.sol";
import {PrivateDoppiGridTraderFactory} from "../src/mainnet/private/PrivateDoppiGridTraderFactory.sol";
import {DoppiGridTrader} from "../src/mainnet/private/DoppiGridTrader.sol";
import {DoppiOpportunity} from "../src/mainnet/DoppiOpportunity.sol";
import {IPrivateAutomationHub} from "../src/Interface/IPrivateAutomationHub.sol";
import {
    RegisterPrivateBotParams,
    PrivateBotJobIds,
    PrivateAutomationModule,
    PrivateJobConfig,
    PrivateJobView,
    BotBillingState
} from "../src/mainnet/private/PrivateAutomationHubTypes.sol";
import {TestParamLib} from "../src/Library/TestParamLib.sol";

contract MockPrivateAutomationHubForGrid is IPrivateAutomationHub {
    uint256 public sharedRegisterCount;
    address public lastTrader;
    address public lastBot;
    uint32 public lastBotId;
    bool public shouldRevert;
    IERC20 public topUpToken;
    uint256 public topUpAmount;
    uint256 public creditThreshold;
    uint256 public creditBalance;
    bool public pausedForLowCredit;
    mapping(address => uint256) public depositedByBot;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setBillingConfig(IERC20 _topUpToken, uint256 _topUpAmount, bool _pausedForLowCredit) external {
        topUpToken = _topUpToken;
        topUpAmount = _topUpAmount;
        creditThreshold = _topUpAmount;
        creditBalance = _pausedForLowCredit ? 0 : _topUpAmount + 1;
        pausedForLowCredit = _pausedForLowCredit;
    }

    function setCreditBalance(uint256 _creditBalance) external {
        creditBalance = _creditBalance;
    }

    function registerPrivateBotJobs(RegisterPrivateBotParams calldata)
        external
        pure
        returns (PrivateBotJobIds memory jobIds)
    {
        return jobIds;
    }

    function registerSharedBotJob(address trader, address bot, uint32 botId) external returns (uint256 jobId) {
        if (shouldRevert) revert("mock hub revert");
        sharedRegisterCount += 1;
        lastTrader = trader;
        lastBot = bot;
        lastBotId = botId;
        return sharedRegisterCount;
    }

    function disablePrivateBotJobs(address) external pure {}

    function getJobId(address, PrivateAutomationModule) external pure returns (uint256 jobId) {
        return 0;
    }

    function getJobIdsByBot(address) external pure returns (PrivateBotJobIds memory jobIds) {
        return jobIds;
    }

    function getJob(uint256) external pure returns (PrivateJobView memory job) {
        return job;
    }

    function setJobConfig(uint256, PrivateJobConfig calldata) external pure {}

    function setJobActive(uint256, bool) external pure {}

    function checkUpkeep(bytes calldata) external pure returns (bool upkeepNeeded, bytes memory performData) {
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata) external pure {}

    function getBotBilling(address bot) external view returns (BotBillingState memory){
        return BotBillingState({
            trader: address(0),
            creditBalance: creditBalance,
            totalGasFeePaid: 0,
            lowCreditPaused: pausedForLowCredit,
            usePoint: false
        });
    }
    function deposit(address bot, uint256 amount) external {
        require(topUpToken.transferFrom(msg.sender, address(this), amount), "top up transfer failed");
        depositedByBot[bot] += amount;
    }
    function defaultTopUp() external view returns (uint256){
        return topUpAmount;
    }
    function fundToken() external view returns (IERC20){
        return topUpToken;
    }

    function minCreditThreshold() external view returns (uint256){
        return creditThreshold;
    }
}

contract PrivateDoppiGridTraderTest is Test {
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    Swapper swapper;
    BlackScholes blackScholes;
    DoppiOffer impliedVol;
    DoppiPoints doppiPoints;

    DoppiLiquidity sharedLP;
    DoppiFeePool feePoolContract;
    DoppiCore sharedCore;
    DoppiTraderFactory sharedFactory;
    DoppiOpportunity sharedOpportunity;
    ConfigParam configLP;

    DoppiCore coreImplementation;
    DoppiGridTrader traderImplementation;
    DoppiOpportunity opportunityImplementation;
    PrivateDoppiGridTraderFactory privateFactory;
    MockPrivateAutomationHubForGrid mockHub;

    address owner = address(0x1);
    address trader = address(0x2);
    address forwarder = address(0x3);
    address feePoolReceiver = address(0x4);

    uint24[] weights;

    struct EpochZoneInfo {
        uint8 zone;
        uint256 buyStrike;
        uint256 sellStrike;
        uint256 originalBuyAmount;
        uint256 originalSellAmount;
        uint256 remainingBuyOpportunity;
        uint256 remainingSellOpportunity;
    }

    function setUp() public {
        vm.startPrank(owner);
        vm.warp(1735689600);

        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(int256(100_000 * 1e8), 8);

        swapper = new Swapper(usdt, btc);
        swapper.setOracle(oracle);

        blackScholes = new BlackScholes();
        impliedVol = new DoppiOffer(blackScholes, address(oracle), 500);
        _setRegression(impliedVol);
        doppiPoints = new DoppiPoints();

        configLP = TestParamLib.get_configLP();
        configLP.chainLinkFeed = address(oracle);
        configLP.router = address(swapper);
        configLP.v3Pool = address(swapper);

        sharedLP = new DoppiLiquidity("Shared LP", "DALP", address(IERC20(usdt)), address(IERC20(btc)));
        sharedLP.setConfig(configLP);
        sharedLP.approveRouter();
        feePoolContract = new DoppiFeePool(address(sharedLP), feePoolReceiver, 3000);

        sharedCore = new DoppiCore(address(usdt), address(btc), sharedLP, impliedVol, address(doppiPoints));
        doppiPoints.setDoppiCore(address(sharedCore), true);

        sharedFactory = new DoppiTraderFactory(
            IERC20(usdt),
            IERC20(btc),
            address(sharedCore),
            address(sharedLP),
            address(0),
            address(impliedVol),
            address(doppiPoints)
        );
        sharedLP.setDoppiTraderFactory(address(sharedFactory));
        sharedCore.setDoppiTraderFactory(sharedFactory);

        sharedOpportunity = new DoppiOpportunity(address(sharedCore), address(sharedLP));
        sharedCore.setOpportunityBot(address(sharedOpportunity), true);

        coreImplementation = new DoppiCore(address(usdt), address(btc), sharedLP, impliedVol, address(doppiPoints));
        traderImplementation = new DoppiGridTrader();
        opportunityImplementation = new DoppiOpportunity(address(0), address(0));

        privateFactory = new PrivateDoppiGridTraderFactory(
            IERC20(usdt),
            IERC20(btc),
            address(sharedLP),
            address(impliedVol),
            address(doppiPoints),
            address(traderImplementation)
        );
        doppiPoints.setCoreRegistrar(address(privateFactory), true);
        privateFactory.setDefaultPrivateTreasury(feePoolReceiver, 2000);

        mockHub = new MockPrivateAutomationHubForGrid();
        sharedLP.setTraderFactoryAllowed(address(privateFactory), true);

        for (uint256 i = 0; i < 5; ) {
            weights.push(2000);
            unchecked {
                ++i;
            }
        }

        usdt.mint(trader, 10_000_000 ether);
        btc.mint(trader, 100 ether);
        vm.stopPrank();
    }

    function test_startPlacesExpectedBuyAndSellLadders() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);
        uint256 p = 1e8;

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        usdt.approve(address(bot), type(uint256).max);
        btc.approve(address(bot), type(uint256).max);
        oracle.setPrice(int256(99_600 * 1e8));
        bot.start(100_000 ether, 1 ether);
        vm.stopPrank();

        // Buy: 99,500 / 99,000 / 98,500 / 98,000 / 97,500 with 4,000 USDT each.
        assertEq(bot.getOpportunityInfo(true, 99_500 * p), 4_000 ether);
        assertEq(bot.getOpportunityInfo(true, 99_000 * p), 4_000 ether);
        assertEq(bot.getOpportunityInfo(true, 98_500 * p), 4_000 ether);
        assertEq(bot.getOpportunityInfo(true, 98_000 * p), 4_000 ether);
        assertEq(bot.getOpportunityInfo(true, 97_500 * p), 4_000 ether);

        // Sell: 100,000 / 100,500 / 101,000 / 101,500 / 102,000 with 0.04 BTC each.
        assertEq(bot.getOpportunityInfo(false, 100_000 * p), 0.04 ether);
        assertEq(bot.getOpportunityInfo(false, 100_500 * p), 0.04 ether);
        assertEq(bot.getOpportunityInfo(false, 101_000 * p), 0.04 ether);
        assertEq(bot.getOpportunityInfo(false, 101_500 * p), 0.04 ether);
        assertEq(bot.getOpportunityInfo(false, 102_000 * p), 0.04 ether);
    }

    function test_startWithHubDoesNotTopUpWhenCreditIsActive() public {
        uint256 p = 1e8;
        mockHub.setBillingConfig(IERC20(usdt), 10 ether, false);
        vm.prank(owner);
        privateFactory.setPrivateAutomationHub(address(mockHub));

        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        assertEq(mockHub.depositedByBot(address(bot)), 0);
        assertEq(usdt.balanceOf(address(mockHub)), 0);
        assertEq(bot.getOpportunityInfo(true, 100_000 * p), 4_000 ether);
    }

    function test_startWithHubTopUpWhenCreditPausedUsesRemainingCapital() public {
        uint256 p = 1e8;
        uint256 defaultTopUp = 10 ether;
        mockHub.setBillingConfig(IERC20(usdt), defaultTopUp, true);
        vm.prank(owner);
        privateFactory.setPrivateAutomationHub(address(mockHub));

        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        uint256 expectedOrderAmount = (((100_000 ether - defaultTopUp) / 5) * 2000) / 10000;
        assertEq(mockHub.depositedByBot(address(bot)), defaultTopUp);
        assertEq(usdt.balanceOf(address(mockHub)), defaultTopUp);
        assertEq(bot.getOpportunityInfo(true, 100_000 * p), expectedOrderAmount);
    }

    function test_startWithHubTopUpRevertsWhenFundTokenDepositIsInsufficient() public {
        mockHub.setBillingConfig(IERC20(usdt), 10 ether, true);
        vm.prank(owner);
        privateFactory.setPrivateAutomationHub(address(mockHub));

        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        vm.expectRevert(bytes4(keccak256("InsufficientTopUpAmount()")));
        bot.start(5 ether, 0);
        vm.stopPrank();
    }

    function test_startWithHubUnsupportedFundTokenLeavesCapitalUnchanged() public {
        uint256 p = 1e8;
        MockToken otherToken = new MockToken("Other", "OTHER");
        mockHub.setBillingConfig(IERC20(otherToken), 10 ether, true);
        vm.prank(owner);
        privateFactory.setPrivateAutomationHub(address(mockHub));

        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        assertEq(mockHub.depositedByBot(address(bot)), 0);
        assertEq(bot.getOpportunityInfo(true, 100_000 * p), 4_000 ether);
    }

    function test_performUpkeepMovesOpportunityToUnwind() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);
        uint256 p = 1e8;

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0); // force zero effective buffer for deterministic trigger tests
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        // Trigger buy zone0 strike 100,000.
        vm.prank(owner);
        oracle.setPrice(int256(99_900 * 1e8));

        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        if(upkeepNeeded){
            vm.prank(forwarder);
            bot.performUpkeep(performData);
        }

        // Opportunity should move to unwind bucket near rounded+gap.
        assertEq(bot.getOpportunityInfo(true, 100_000 * p), 0);
        assertGt(bot.getUnwindInfo(true, 100_000 * p), 0);
    }

    function test_unwindPaysFeeInProfitToken() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);

        vm.startPrank(owner);
        feePoolContract.setAuthorizedCore(address(bot), true);
        privateFactory.setFeeConfig(address(bot), address(feePoolContract), 1000);
        vm.stopPrank();

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        // Buy trigger at lower price.
        vm.prank(owner);
        oracle.setPrice(int256(99_900 * 1e8));
        
        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        if(upkeepNeeded){
            vm.prank(forwarder);
            bot.performUpkeep(performData);
        }
        
        uint256 receiverBefore = usdt.balanceOf(feePoolReceiver);
        uint256 sharedLpBefore = usdt.balanceOf(address(sharedLP));

        // Unwind trigger at higher price (profit realized in assetA/usdt).
        vm.prank(owner);
        oracle.setPrice(int256(130_000 * 1e8));
        (upkeepNeeded, performData) = bot.checkUpkeep("");
        if(upkeepNeeded){
            vm.prank(forwarder);
            bot.performUpkeep(performData);
        }

        uint256 receiverAfter = usdt.balanceOf(feePoolReceiver);
        uint256 sharedLpAfter = usdt.balanceOf(address(sharedLP));
        assertGt(receiverAfter, receiverBefore);
        assertGt(sharedLpAfter, sharedLpBefore);
    }

    function test_stopPaysBuyUnwindProfitFeeInAssetB() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);
        uint256 p = 1e8;
        uint256 strike = 100_000 * p;

        vm.prank(owner);
        privateFactory.setFeeConfig(address(bot), feePoolReceiver, 1000);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        vm.prank(owner);
        oracle.setPrice(int256(99_900 * 1e8));

        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(forwarder);
        bot.performUpkeep(performData);

        uint256 unwindAmountB = bot.getUnwindInfo(true, strike);
        uint256 entryValueA = bot.unWindBuyCostA(strike);
        uint256 stopPrice = 130_000 * p;
        uint256 priceDecimals = 10 ** sharedLP.getPriceDecimals();
        uint256 currentValueA = (unwindAmountB * stopPrice) / priceDecimals;
        uint256 profitA = currentValueA - entryValueA;
        uint256 expectedFeeB = ((profitA * 1000) / 10_000) * priceDecimals / stopPrice;

        vm.prank(owner);
        oracle.setPrice(int256(stopPrice));

        uint256 receiverBefore = btc.balanceOf(feePoolReceiver);
        vm.prank(trader);
        bot.stop();

        assertEq(btc.balanceOf(feePoolReceiver) - receiverBefore, expectedFeeB);
    }

    function test_stopPaysSellUnwindProfitFeeInAssetA() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);
        uint256 p = 1e8;
        uint256 strike = 100_500 * p;

        vm.prank(owner);
        privateFactory.setFeeConfig(address(bot), feePoolReceiver, 1000);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        btc.approve(address(bot), type(uint256).max);
        bot.start(0, 1 ether);
        vm.stopPrank();

        vm.prank(owner);
        oracle.setPrice(int256(100_600 * 1e8));

        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(forwarder);
        bot.performUpkeep(performData);

        uint256 unwindAmountA = bot.getUnwindInfo(false, strike);
        uint256 entryValueB = bot.unWindSellCostB(strike);
        uint256 stopPrice = 80_000 * p;
        uint256 priceDecimals = 10 ** sharedLP.getPriceDecimals();
        uint256 currentValueB = (unwindAmountA * priceDecimals) / stopPrice;
        uint256 profitB = currentValueB - entryValueB;
        uint256 expectedFeeA = ((profitB * 1000) / 10_000) * stopPrice / priceDecimals;

        vm.prank(owner);
        oracle.setPrice(int256(stopPrice));

        uint256 receiverBefore = usdt.balanceOf(feePoolReceiver);
        vm.prank(trader);
        bot.stop();

        assertEq(usdt.balanceOf(feePoolReceiver) - receiverBefore, expectedFeeA);
    }

    function test_partialUnwindReopensOnlyConsumedBuyCost() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);
        uint256 p = 1e8;
        uint256 strike = 100_000 * p;
        uint256 originalCostA = 4_000 ether;

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        vm.prank(owner);
        oracle.setPrice(int256(99_900 * 1e8));

        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(forwarder);
        bot.performUpkeep(performData);

        uint256 unwindAmount = bot.getUnwindInfo(true, strike);
        assertGt(unwindAmount, 0);
        assertEq(bot.getOpportunityInfo(true, strike), 0);

        uint256 priceDecimals = 10 ** sharedLP.getPriceDecimals();

    (DoppiGridTrader.StrikePnLView[] memory items, int256 totalPnl, uint256 currentPrice) = bot.getStrikePnL(true);
    assertEq(items.length, 1);
    assertEq(items[0].strikePrice, strike);
    assertEq(items[0].unwindAmount, unwindAmount);
    assertEq(items[0].entryValue, originalCostA);
    assertEq(items[0].averageCost, (originalCostA * priceDecimals) / unwindAmount);
    assertEq(items[0].currentValue, (unwindAmount * currentPrice) / priceDecimals);
    assertEq(totalPnl, int256(items[0].currentValue) - int256(originalCostA));

        uint256 unwindPrice = 130_000 * p;
        uint256 halfUnwind = unwindAmount / 2;
        uint256 maxSwapA = (halfUnwind * unwindPrice) / priceDecimals;
        uint256 expectedUsed = (maxSwapA * priceDecimals) / unwindPrice;
        uint256 expectedReopened = (originalCostA * expectedUsed) / unwindAmount;

        vm.startPrank(trader);
        bot.setMaxSwap(maxSwapA);
        vm.stopPrank();

        vm.prank(owner);
        oracle.setPrice(int256(unwindPrice));

        (upkeepNeeded, performData) = bot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(forwarder);
        bot.performUpkeep(performData);

        assertEq(bot.getOpportunityInfo(true, strike), expectedReopened);
        assertEq(bot.unWindBuyCostA(strike), originalCostA - expectedReopened);
        assertLt(bot.getOpportunityInfo(true, strike), originalCostA);
    }

    function test_getStrikePnLUsesTrackedSellExecutionCost() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);
        uint256 p = 1e8;
        uint256 strike = 100_500 * p;
        uint256 originalCostB = 0.04 ether;

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        btc.approve(address(bot), type(uint256).max);
        bot.start(0, 1 ether);
        vm.stopPrank();

        vm.prank(owner);
        oracle.setPrice(int256(100_600 * 1e8));

        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(forwarder);
        bot.performUpkeep(performData);

        uint256 unwindAmount = bot.getUnwindInfo(false, strike);
        assertGt(unwindAmount, 0);
        assertEq(bot.getOpportunityInfo(false, strike), 0);

        uint256 priceDecimals = 10 ** sharedLP.getPriceDecimals();
        (DoppiGridTrader.StrikePnLView[] memory items, int256 totalPnl, uint256 currentPrice) = bot.getStrikePnL(false);
        assertEq(items.length, 1);
        assertEq(items[0].strikePrice, strike);
        assertEq(items[0].unwindAmount, unwindAmount);
        assertEq(items[0].entryValue, originalCostB);
        assertEq(items[0].averageCost, (unwindAmount * priceDecimals) / originalCostB);
        assertEq(items[0].currentValue, (unwindAmount * priceDecimals) / currentPrice);
        assertEq(totalPnl, int256(items[0].currentValue) - int256(originalCostB));
    }

    function test_epochResetAfter24HoursReanchorsOrders() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);
        uint256 p = 1e8;

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(0, 2000);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        (, uint64 expiryBefore, uint256 anchorBefore) = bot.getEpochInfo();
        assertEq(anchorBefore, 100_000 * p);

        vm.warp(uint256(expiryBefore) + 1);
        vm.prank(owner);
        oracle.setPrice(int256(98_200 * 1e8));

        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        if(upkeepNeeded){
            vm.prank(forwarder);
            bot.performUpkeep(performData);
        }

        (, uint64 expiryAfter, uint256 anchorAfter) = bot.getEpochInfo();
        assertGt(expiryAfter, expiryBefore);
        assertEq(anchorAfter, 98_000 * p);
        assertEq(bot.getOpportunityInfo(true, 98_000 * p), 4_000 ether);
    }

    function test_deployPrivateBot_registersHubAndSetsForwarder() public {
        vm.prank(owner);
        privateFactory.setPrivateAutomationHub(address(mockHub));

        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);

        assertEq(mockHub.sharedRegisterCount(), 1);
        assertEq(mockHub.lastTrader(), trader);
        assertEq(mockHub.lastBot(), botAddr);
        assertEq(bot.s_forwarderAddress(), address(mockHub));
    }

    function test_pointsRecordedOnOpportunityAndUnwindSwaps() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        usdt.approve(address(bot), type(uint256).max);
        btc.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        uint24 monthId = doppiPoints.getCurrentMonthId();
        uint256 volumeBefore = doppiPoints.getMonthlyVolume(trader, monthId);

        vm.prank(owner);
        oracle.setPrice(int256(99_900 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        if (upkeepNeeded) {
            vm.prank(forwarder);
            bot.performUpkeep(performData);
        }

        uint256 volumeAfterOpportunity = doppiPoints.getMonthlyVolume(trader, monthId);
        assertGt(volumeAfterOpportunity, volumeBefore);

        vm.prank(owner);
        oracle.setPrice(int256(130_000 * 1e8));
        (upkeepNeeded, performData) = bot.checkUpkeep("");
        if (upkeepNeeded) {
            vm.prank(forwarder);
            bot.performUpkeep(performData);
        }

        uint256 volumeAfterUnwind = doppiPoints.getMonthlyVolume(trader, monthId);
        assertGt(volumeAfterUnwind, volumeAfterOpportunity);
    }

    function test_pointsNotRecordedWhenDoppiPointsPaused() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        uint24 monthId = doppiPoints.getCurrentMonthId();
        uint256 volumeBefore = doppiPoints.getMonthlyVolume(trader, monthId);

        vm.prank(owner);
        doppiPoints.setPause();

        vm.prank(owner);
        oracle.setPrice(int256(99_900 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        if (upkeepNeeded) {
            vm.prank(forwarder);
            bot.performUpkeep(performData);
        }

        uint256 volumeAfter = doppiPoints.getMonthlyVolume(trader, monthId);
        assertEq(volumeAfter, volumeBefore);
    }

    function test_logBudgetBehaviorAcrossEpochs_afterThreePercentDrops() public {
        uint24[] memory customWeights = new uint24[](3);
        customWeights[0] = 2000; // zone[1] = 20%
        customWeights[1] = 4000; // zone[2] = 40%
        customWeights[2] = 4000; // zone[3] = 40%

        (address botAddr,,,,) = _deployAndCaptureWithWeights(trader, customWeights);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        // Force deterministic triggers at exact 3% moves.
        bot.setOpportunityBufferParams(10000, 0);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(20_000 ether, 0);
        vm.stopPrank();

        uint256 rounds = 15;
        for (uint256 i = 0; i < rounds; ) {
            (, uint64 expiryBefore, uint256 anchorBefore) = bot.getEpochInfo();

            // Step 2: price down 3% and execute opportunity orders.
            uint256 downPrice = (anchorBefore * 97) / 100;
            vm.prank(owner);
            oracle.setPrice(int256(downPrice));
            _performIfNeeded(bot);

            // Step 3: fast-forward to new epoch.
            vm.warp(uint256(expiryBefore) + 1);
            _performIfNeeded(bot);

            // Step 4: log the new budget for this epoch.
            uint256 epochBuyBudget = _sumEpochOriginalBuyBudget(bot);
            uint256 availableA = usdt.balanceOf(address(bot));
            (, uint64 expiryAfter, uint256 anchorAfter) = bot.getEpochInfo();

            emit log_named_uint("round", i + 1);
            // emit log_named_uint("anchorBefore", anchorBefore / 1e8);
            // emit log_named_uint("downPrice", downPrice / 1e8);
            // emit log_named_uint("newAnchor", anchorAfter / 1e8);
            emit log_named_uint("newEpochBuyBudget", epochBuyBudget / 1e18);
            emit log_named_uint("availableA", availableA / 1e18);
            // emit log_named_uint("nextExpiry", expiryAfter);

            unchecked {
                ++i;
            }
        }
    }

    function _deployAndCapture(address _trader) internal returns (
        address bot,
        address core,
        address opp,
        address privLP,
        address privRouter
    ) {
        vm.recordLogs();
        vm.prank(_trader);
        privateFactory.deployPrivateBot(weights);

        

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("GridBotDeployed(address,address,uint32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                bot = address(uint160(uint256(logs[i].topics[2])));
                core = address(0);
                opp = address(0);
                privLP = address(sharedLP);
                privRouter = address(0);
                DoppiGridTrader botInstance = DoppiGridTrader(bot);
                vm.startPrank(_trader);
                botInstance.setBudgetRampParams(10000, 0, 10000);
                vm.stopPrank();
                return (bot, core, opp, privLP, privRouter);
            }
        }
        revert("GridBotDeployed event not found");
    }

    function _deployAndCaptureWithWeights(address _trader, uint24[] memory _weights) internal returns (
        address bot,
        address core,
        address opp,
        address privLP,
        address privRouter
    ) {
        vm.recordLogs();
        vm.prank(_trader);
        privateFactory.deployPrivateBot(_weights);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("GridBotDeployed(address,address,uint32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                bot = address(uint160(uint256(logs[i].topics[2])));
                core = address(0);
                opp = address(0);
                privLP = address(sharedLP);
                privRouter = address(0);
                return (bot, core, opp, privLP, privRouter);
            }
        }
        revert("GridBotDeployed event not found");
    }

    function _performIfNeeded(DoppiGridTrader bot) internal {
        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        if (upkeepNeeded) {
            vm.prank(forwarder);
            bot.performUpkeep(performData);
        }
    }

    function _sumEpochOriginalBuyBudget(DoppiGridTrader bot) internal view returns (uint256 totalBuyBudget) {
        DoppiGridTrader.EpochZoneInfo[] memory zones = bot.getEpochZoneInfo();
        for (uint256 i = 0; i < zones.length; ) {
            totalBuyBudget += zones[i].originalBuyAmount;
            unchecked {
                ++i;
            }
        }
    }

    function _setRegression(DoppiOffer _iv) internal {
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;
        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;
        _iv.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
    }
}
