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
import {ConfigParam} from "../src/mainnet/DoppiLiquidityTypes.sol";
import {PrivateDoppiSimpleTraderFactory} from "../src/mainnet/private/PrivateDoppiSimpleTraderFactory.sol";
import {DoppiSimpleTrader} from "../src/mainnet/private/DoppiSimpleTrader.sol";
import {TestParamLib} from "../src/Library/TestParamLib.sol";
import {MockPrivateAutomationHubForSimple} from "./PrivateDoppiSimpleTraderTopUpMock.sol";

contract PrivateDoppiSimpleTraderTest is Test {
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    Swapper swapper;
    BlackScholes blackScholes;
    DoppiOffer impliedVol;
    DoppiPoints doppiPoints;

    DoppiLiquidity sharedLP;
    DoppiCore sharedCore;
    DoppiTraderFactory sharedFactory;
    ConfigParam configLP;

    DoppiSimpleTrader traderImplementation;
    PrivateDoppiSimpleTraderFactory privateFactory;
    MockPrivateAutomationHubForSimple mockHub;

    address owner = address(0x1);
    address trader = address(0x2);
    address forwarder = address(0x3);
    address feePoolReceiver = address(0x4);

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

        traderImplementation = new DoppiSimpleTrader();

        privateFactory = new PrivateDoppiSimpleTraderFactory(
            IERC20(usdt),
            IERC20(btc),
            address(sharedLP),
            address(impliedVol),
            address(doppiPoints),
            address(traderImplementation)
        );
        doppiPoints.setCoreRegistrar(address(privateFactory), true);
        sharedLP.setTraderFactoryAllowed(address(privateFactory), true);
        mockHub = new MockPrivateAutomationHubForSimple();

        usdt.mint(trader, 10_000_000 ether);
        btc.mint(trader, 100 ether);

        vm.stopPrank();
    }

    function test_startInitializesBidirectionalTriggers() public {
        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0); // use zero buffer for deterministic trigger checks
        usdt.approve(address(bot), type(uint256).max);
        btc.approve(address(bot), type(uint256).max);
        oracle.setPrice(int256(65_000 * 1e8));
        bot.start(100_000 ether, 1 ether);
        vm.stopPrank();

        assertEq(bot.nextBuyTriggerPrice(), 65_000 * 1e8);
        assertEq(bot.nextSellTriggerPrice(), 65_000 * 1e8);
    }

    function test_startWithHubDoesNotTopUpWhenCreditIsActive() public {
        mockHub.setBillingConfig(IERC20(usdt), 10 ether, false);
        vm.prank(owner);
        privateFactory.setPrivateAutomationHub(address(mockHub));

        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        oracle.setPrice(int256(65_000 * 1e8));
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        assertEq(mockHub.depositedByBot(address(bot)), 0);
        assertEq(usdt.balanceOf(address(mockHub)), 0);
        assertEq(usdt.balanceOf(address(bot)), 100_000 ether);
    }

    function test_startWithHubTopUpWhenCreditPausedUsesRemainingCapital() public {
        uint256 defaultTopUp = 10 ether;
        mockHub.setBillingConfig(IERC20(usdt), defaultTopUp, true);
        vm.prank(owner);
        privateFactory.setPrivateAutomationHub(address(mockHub));

        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        oracle.setPrice(int256(65_000 * 1e8));
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        assertEq(mockHub.depositedByBot(address(bot)), defaultTopUp);
        assertEq(usdt.balanceOf(address(mockHub)), defaultTopUp);
        assertEq(usdt.balanceOf(address(bot)), 100_000 ether - defaultTopUp);
    }

    function test_startWithHubTopUpRevertsWhenFundTokenDepositIsInsufficient() public {
        mockHub.setBillingConfig(IERC20(usdt), 10 ether, true);
        vm.prank(owner);
        privateFactory.setPrivateAutomationHub(address(mockHub));

        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        oracle.setPrice(int256(65_000 * 1e8));
        vm.expectRevert(bytes4(keccak256("InsufficientTopUpAmount()")));
        bot.start(5 ether, 0);
        vm.stopPrank();
    }

    function test_startWithHubUnsupportedFundTokenLeavesCapitalUnchanged() public {
        MockToken otherToken = new MockToken("Other", "OTHER");
        mockHub.setBillingConfig(IERC20(otherToken), 10 ether, true);
        vm.prank(owner);
        privateFactory.setPrivateAutomationHub(address(mockHub));

        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        oracle.setPrice(int256(65_000 * 1e8));
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        assertEq(mockHub.depositedByBot(address(bot)), 0);
        assertEq(usdt.balanceOf(address(bot)), 100_000 ether);
    }

    function test_consecutiveOrdersAdvanceFromLastExecutionPrice() public {
        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0); // zero buffer to keep trigger equal to execution price
        bot.setMaxOrderPerRound(10_000 ether, 0.1 ether);
        usdt.approve(address(bot), type(uint256).max);
        btc.approve(address(bot), type(uint256).max);
        oracle.setPrice(int256(65_000 * 1e8));
        bot.start(200_000 ether, 2 ether);
        vm.stopPrank();

        // Disable sell-side capital so only buy branch is testable.
        vm.prank(trader);
        bot.setMaxOrderPerRound(10_000 ether, 0);

        vm.prank(owner);
        oracle.setPrice(int256(64_500 * 1e8)); // <= 65,000 buy trigger

        (bool needed, bytes memory data) = bot.checkUpkeep("");
        assertTrue(needed);
        vm.prank(forwarder);
        bot.performUpkeep(data);

        assertEq(bot.lastBuyPlacedPrice(), 64_500 * 1e8);
        assertEq(bot.nextBuyTriggerPrice(), 64_500 * 1e8);

        // Disable buy-side capital so only sell branch is testable.
        vm.prank(trader);
        bot.setMaxOrderPerRound(0, 0.1 ether);

        vm.prank(owner);
        oracle.setPrice(int256(66_000 * 1e8)); // >= 65,000 sell trigger

        (needed, data) = bot.checkUpkeep("");
        assertTrue(needed);
        vm.prank(forwarder);
        bot.performUpkeep(data);

        assertEq(bot.lastSellPlacedPrice(), 66_000 * 1e8);
        assertEq(bot.nextSellTriggerPrice(), 66_000 * 1e8);
    }

    function test_startTriggerMathMatchesOfferBufferWithCutAndMin() public {
        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(3000, 100); // match strategy defaults explicitly
        usdt.approve(address(bot), type(uint256).max);
        btc.approve(address(bot), type(uint256).max);

        uint256 price = 65_000 * 1e8;
        oracle.setPrice(int256(price));
        bot.start(100_000 ether, 1 ether);
        vm.stopPrank();

        uint256 rawBuyBps = impliedVol.getOneDayBuffer(price, true);
        uint256 rawSellBps = impliedVol.getOneDayBuffer(price, false);

        uint256 effBuyBps = (rawBuyBps * (10_000 - 3000)) / 10_000;
        if (effBuyBps < 100) effBuyBps = 100;

        uint256 effSellBps = (rawSellBps * (10_000 - 3000)) / 10_000;
        if (effSellBps < 100) effSellBps = 100;

        uint256 expectedBuyTrigger = price - ((price * effBuyBps) / 10_000);
        uint256 expectedSellTrigger = price + ((price * effSellBps) / 10_000);

        assertEq(bot.nextBuyTriggerPrice(), expectedBuyTrigger);
        assertEq(bot.nextSellTriggerPrice(), expectedSellTrigger);
    }

    function test_autoBudgetUsesFiveWaySplitAndHonorsMinOrder() public {
        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        bot.setMaxOrderPerRound(0, 0);
        bot.setMinOrder(50 ether, 0.0005 ether);
        bot.setAutoBudgetAggressive(7500, 2000);
        bot.setMaxSwap(100000 ether);

        usdt.approve(address(bot), type(uint256).max);
        btc.approve(address(bot), type(uint256).max);

        oracle.setPrice(int256(65_000 * 1e8));
        bot.start(1_000 ether, 0);
        vm.stopPrank();

        (bool needed, bytes memory data) = bot.checkUpkeep("");
        assertTrue(needed);

        vm.prank(forwarder);
        bot.performUpkeep(data);

        assertEq(bot.buyCostAOutstanding(), 150 ether);
    }

    function test_getPositionInfoReportsCurrentState() public {
        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        bot.setMaxOrderPerRound(10_000 ether, 0);
        usdt.approve(address(bot), type(uint256).max);
        btc.approve(address(bot), type(uint256).max);

        oracle.setPrice(int256(65_000 * 1e8));
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        DoppiSimpleTrader.PositionInfo memory beforeInfo = bot.getPositionInfo();
        assertTrue(beforeInfo.engineStarted);
        assertEq(beforeInfo.currentBuyPosition, 0);
        assertEq(beforeInfo.currentSellPosition, 0);
        assertEq(beforeInfo.pendingUnwindBuy, 0);
        assertEq(beforeInfo.pendingUnwindSell, 0);
        assertEq(beforeInfo.nextBuyPrice, 65_000 * 1e8);
        assertEq(beforeInfo.nextSellPrice, 65_000 * 1e8);

        vm.prank(owner);
        oracle.setPrice(int256(64_500 * 1e8));
        (bool needed, bytes memory data) = bot.checkUpkeep("");
        assertTrue(needed);
        vm.prank(forwarder);
        bot.performUpkeep(data);

        DoppiSimpleTrader.PositionInfo memory afterInfo = bot.getPositionInfo();
        assertGt(afterInfo.currentBuyPosition, 0);
        assertGt(afterInfo.pendingUnwindBuy, 0);
        assertEq(afterInfo.currentSellPosition, 0);
        assertEq(afterInfo.pendingUnwindSell, 0);
        assertGt(afterInfo.averageBuyPrice, 0);
        assertEq(afterInfo.averageSellPrice, 0);
        assertEq(afterInfo.nextBuyPrice, 64_500 * 1e8);
    }

    function test_averageCostUnwindTriggersAndClearsBuckets() public {
        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);

        vm.startPrank(trader);
        bot.setMaxSwap(50000 * 1e18);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0); // zero buffer so unwind trigger equals average entry
        bot.setMaxOrderPerRound(10_000 ether, 0.1 ether);
        usdt.approve(address(bot), type(uint256).max);
        btc.approve(address(bot), type(uint256).max);
        oracle.setPrice(int256(65_000 * 1e8));
        bot.start(300_000 ether, 3 ether);
        vm.stopPrank();

        vm.prank(trader);
        bot.setMaxOrderPerRound(10_000 ether, 0); // keep test focused on buy inventory and buy unwind

        // Build buy-side inventory at two lower prices to establish avg cost.
        vm.prank(owner);
        oracle.setPrice(int256(64_500 * 1e8));
        (bool needed, bytes memory data) = bot.checkUpkeep("");
        vm.prank(forwarder);
        bot.performUpkeep(data);

        vm.prank(owner);
        oracle.setPrice(int256(63_500 * 1e8));
        (needed, data) = bot.checkUpkeep("");
        vm.prank(forwarder);
        bot.performUpkeep(data);

        (uint256 avgBuy, uint256 avgSell) = bot.getAveragePrices();
        assertGt(avgBuy, 0);
        assertEq(avgSell, 0);

        (uint256 buyUnwindTrigger,) = bot.getUnwindTriggerPrices();
        assertEq(buyUnwindTrigger, avgBuy);

        // Move price to average trigger to unwind.
        vm.prank(owner);
        oracle.setPrice(int256(int256(buyUnwindTrigger)));

        (needed, data) = bot.checkUpkeep("");
        assertTrue(needed);
        vm.prank(forwarder);
        bot.performUpkeep(data);

        // Buy-side unwind inventory should be consumed.
        (avgBuy, avgSell) = bot.getAveragePrices();
        assertEq(avgBuy, 0);
        assertEq(avgSell, 0);
    }

    function test_stopPaysBuyUnwindProfitFeeInAssetB() public {
        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);
        uint256 p = 1e8;

        vm.prank(owner);
        privateFactory.setFeeConfig(address(bot), feePoolReceiver, 1000);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        bot.setMaxOrderPerRound(10_000 ether, 0);
        usdt.approve(address(bot), type(uint256).max);
        oracle.setPrice(int256(65_000 * 1e8));
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        uint256 buyPrice = 64_500 * p;
        vm.prank(owner);
        oracle.setPrice(int256(buyPrice));

        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(forwarder);
        bot.performUpkeep(performData);

        uint256 unwindAmountB = bot.getUnwindInfo(true, buyPrice);
        uint256 entryValueA = bot.unWindBuyCostA(buyPrice);
        uint256 stopPrice = 70_000 * p;
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
        address botAddr = _deployAndCapture(trader);
        DoppiSimpleTrader bot = DoppiSimpleTrader(botAddr);
        uint256 p = 1e8;

        vm.prank(owner);
        privateFactory.setFeeConfig(address(bot), feePoolReceiver, 1000);

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        bot.setMaxOrderPerRound(0, 0.1 ether);
        btc.approve(address(bot), type(uint256).max);
        oracle.setPrice(int256(65_000 * 1e8));
        bot.start(0, 1 ether);
        vm.stopPrank();

        uint256 sellPrice = 66_000 * p;
        vm.prank(owner);
        oracle.setPrice(int256(sellPrice));

        (bool upkeepNeeded, bytes memory performData) = bot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(forwarder);
        bot.performUpkeep(performData);

        uint256 unwindAmountA = bot.getUnwindInfo(false, sellPrice);
        uint256 entryValueB = bot.unWindSellCostB(sellPrice);
        uint256 stopPrice = 60_000 * p;
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

    function _deployAndCapture(address _trader) internal returns (address bot) {
        vm.recordLogs();
        vm.prank(_trader);
        privateFactory.deployPrivateBot(new uint24[](0));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SimpleBotDeployed(address,address,uint32)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                bot = address(uint160(uint256(logs[i].topics[2])));
                return bot;
            }
        }
        revert("SimpleBotDeployed event not found");
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
