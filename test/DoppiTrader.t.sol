// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiTraderFactory} from "../src/mainnet/DoppiTraderFactory.sol";
import {DoppiTrader} from "../src/mainnet/DoppiTrader.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiCorePositionLens} from "../src/mainnet/DoppiCorePositionLens.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {DoppiOffer} from "../src/mainnet/DoppiOffer.sol";
import {DoppiPoints} from "../src/mainnet/DoppiPoints.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {MockDoppiUpKeepManager} from "../src/test/MockDoppiUpkeepManager.sol";
import {DoppiOpportunity} from "../src/mainnet/DoppiOpportunity.sol";
import {Swapper} from "../src/test/Swapper.sol";
import "../src/mainnet/DoppiTraderTypes.sol";
import "../src/mainnet/DoppiCoreTypes.sol";
import {TestParamLib} from "../src/Library/TestParamLib.sol";
import "../src/mainnet/DoppiLiquidityTypes.sol";
import {MockPrivateAutomationHubForSimple} from "./PrivateDoppiSimpleTraderTopUpMock.sol";

contract DoppiTraderV2Mock is DoppiTrader {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract DoppiTraderTest is Test {
    DoppiTraderFactory doppiFactory;
    DoppiTrader doppiTrader;
    DoppiCore doppiCore;
    DoppiCorePositionLens positionLens;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    BlackScholes blackScholes;
    DoppiOffer impliedVol;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    MockDoppiUpKeepManager mockDoppiUpKeepManager;
    MockPrivateAutomationHubForSimple mockPrivateAutomationHub;
    DoppiOpportunity opportunityBot;
    Swapper swapper;
    DoppiPoints doppiPoints;
    ConfigParam configLP;

    address owner = address(0x1);
    address treasury = address(0x3);
    address admin = address(0x4);
    address mockForwarder = address(0x5);
    address trader = address(0x6);
    // address owner2 = address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496);

    uint24[] defaultweights;

    event BulkDeposited(address indexed trader, uint256 totalAmount, bool isBuy);
    event UnwindPerformed(address indexed trader, bool isBuy, uint256 amountIn, uint256 amountOut);

    function setUp() public {
        vm.warp(1735689600); 
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;

        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(int256(100_000 * 1e8), 8);

        blackScholes = new BlackScholes();
        impliedVol = new DoppiOffer(blackScholes, address(oracle), 500);
        impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);

        doppiPoints = new DoppiPoints();

        mockDoppiUpKeepManager = new MockDoppiUpKeepManager(mockForwarder);
        mockPrivateAutomationHub = new MockPrivateAutomationHubForSimple();

        // Deploy Swapper that will act as both router and pool
        swapper = new Swapper(MockToken(usdt), MockToken(btc));
        swapper.setOracle(MockOracle(oracle));    
        
        doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", address(IERC20(usdt)), address(IERC20(btc)));
        
        configLP = TestParamLib.get_configLP();
        configLP.chainLinkFeed = address(oracle);
        configLP.router = address(swapper);
        doppiLP.setConfig(configLP);
        doppiLP.approveRouter();

        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol, address(doppiPoints));
        positionLens = new DoppiCorePositionLens(address(doppiCore));
        doppiPoints.setDoppiCore(address(doppiCore), true);

        opportunityBot = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiCore.setOpportunityBot(address(opportunityBot), true);
        doppiCore.setForwarderAddress(mockForwarder);
        doppiCore.setTreasury(treasury, 1000);
        
        opportunityBot.setForwarderAddress(mockForwarder);
        doppiLP.setDoppiCore(address(doppiCore));

        defaultweights.push(500);
        defaultweights.push(1000);
        defaultweights.push(1500);
        defaultweights.push(2500);
        defaultweights.push(4500);

        // Create router and set entry points
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiRouter.setDoppiCore(address(doppiCore));
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        doppiLP.setDoppiLiquidityRouter(address(doppiRouter));

        doppiFactory =
            new DoppiTraderFactory(IERC20(usdt), IERC20(btc), address(doppiCore), address(doppiLP), address(doppiRouter), address(impliedVol), address(doppiPoints));
        doppiLP.setDoppiTraderFactory(address(doppiFactory));
        doppiCore.setDoppiTraderFactory(doppiFactory);
        doppiFactory.setDoppiUpKeepManager(address(mockDoppiUpKeepManager));

        vm.prank(trader);
        uint32 id = doppiFactory.deployTraderBot(defaultweights);
        vm.stopPrank();
        doppiTrader = DoppiTrader(doppiFactory.traderBots(id));
        vm.prank(trader);
        doppiTrader.setForwarderAddress(mockForwarder);
        vm.prank(trader);
        doppiTrader.setMaxOrderPerRound(type(uint256).max, type(uint256).max);
        vm.stopPrank();
        
        usdt.mint(trader, 10_000_000 ether);
        btc.mint(trader, 100 ether);

        usdt.mint(owner, 10_000_000 ether);
        btc.mint(owner, 100 ether);

        usdt.mint(admin, 1_000_000 ether);
        btc.mint(admin, 20 ether);
        
    }

    function test_constructor() public view {
        assertEq(doppiTrader.owner(), address(doppiFactory));
        assertEq(doppiTrader.validTrader(), address(trader));
        assertEq(address(doppiTrader.assetA()), address(usdt));
        assertEq(address(doppiTrader.assetB()), address(btc));
        assertEq(address(doppiTrader.doppiLP()), address(doppiLP));
        assertEq(address(doppiTrader.doppiCore()), address(doppiCore));
    }

    function test_updateImplementation_onlyAffectsNewBots() public {
        address oldBot = address(doppiTrader);
        address oldImplementation = doppiFactory.traderBotImplementation();

        DoppiTraderV2Mock newImplementation = new DoppiTraderV2Mock();
        doppiFactory.updateImplementation(address(newImplementation));

        assertEq(doppiFactory.traderBotImplementation(), address(newImplementation));
        assertTrue(oldImplementation != address(newImplementation));

        vm.prank(trader);
        uint32 newId = doppiFactory.deployTraderBot(defaultweights);
        address newBot = doppiFactory.traderBots(newId);

        // Old clone still points to old implementation, so version() should not exist.
        (bool okOld, ) = oldBot.staticcall(abi.encodeWithSignature("version()"));
        assertFalse(okOld);

        // New clone points to V2 implementation and exposes version().
        (bool okNew, bytes memory dataNew) = newBot.staticcall(abi.encodeWithSignature("version()"));
        assertTrue(okNew);
        assertEq(abi.decode(dataNew, (uint256)), 2);
    }

    function test_getTotalBalances() public {
        _start();
        (uint256 totalAssetA, uint256 totalAssetB, uint256 price) = doppiTrader.getTotalBalances();
        console.log(totalAssetA, totalAssetB, price);
    }
    
    function test_start() public {
        _start();

        DualAssetPosition[] memory positions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(positions.length, 5);

        // total of USDT 50k in trader bot, 50% in liquidity
        assertEq(positions[4].amount, 2500 ether); // 5%
        assertEq(positions[3].amount, 5000 ether); // 10%
        assertEq(positions[2].amount, 7500 ether); // 15%
        assertEq(positions[1].amount, 12500 ether); // 25%
        assertEq(positions[0].amount, 22500 ether); // 45%

        // total of BTC 0.50 in trader bot, 0.50 in liquidity
        positions = positionLens.getPositionsSell(address(doppiTrader));
        assertEq(positions.length, 5);
        assertEq(positions[4].amount, 0.025 ether); // 5%
        assertEq(positions[3].amount, 0.05 ether); // 10%
        assertEq(positions[2].amount, 0.075 ether); // 15%
        assertEq(positions[1].amount, 0.125 ether); // 25%
        assertEq(positions[0].amount, 0.225 ether); // 45%

        // Check BTC balance decreased
        assertEq(btc.balanceOf(address(trader)), 99 ether);
        assertEq(usdt.balanceOf(address(trader)), 9_900_000 ether);

    }

    function test_start_tracksCostBasisAndUnitsB_withBothAssets() public {
        uint256 amountUSDT = 100_000 ether;
        uint256 amountBTC = 1 ether;

        uint256 price = doppiLP.getPrice();
        uint256 priceDecimals = 10 ** doppiLP.getPriceDecimals();

        uint256 expectedA = amountUSDT + (amountBTC * price) / priceDecimals;
        uint256 expectedB = amountBTC + (amountUSDT * priceDecimals) / price;

        vm.startPrank(trader);
        usdt.approve(address(doppiTrader), 10_000_000 ether);
        btc.approve(address(doppiTrader), 100 ether);
        doppiTrader.start(amountUSDT, amountBTC);
        vm.stopPrank();

        assertEq(doppiTrader.totalUnits(), expectedA);
        assertEq(doppiTrader.costBasis(), amountUSDT);
        assertEq(doppiTrader.totalUnitsB(), expectedB);
        assertEq(doppiTrader.costBasisB(), amountBTC);
    }

    function test_start_less_order() public {
        
        // Set multiple configs at once
        uint8[] memory strikeZones = new uint8[](3);
        uint24[] memory weights = new uint24[](3);
        strikeZones[0] = 0;
        weights[0] = 6000;        
        strikeZones[1] = 2;
        weights[1] = 3000;
        strikeZones[2] = 4;
        weights[2] = 1000;
        
        vm.startPrank(trader);
        doppiTrader.setMultipleOrderConfigs(strikeZones, weights);
        vm.stopPrank();

        _start();

        DualAssetPosition[] memory positions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(positions.length, 3);

        // total of BTC 0.50 in trader bot, 0.50 in liquidity
        positions = positionLens.getPositionsSell(address(doppiTrader));
        assertEq(positions.length, 3);
        
        // Check BTC balance decreased
        assertEq(btc.balanceOf(address(trader)), 99 ether);
        assertEq(usdt.balanceOf(address(trader)), 9_900_000 ether);

    }

    function test_start_assetA_only() public {
        
        uint256 amountUSDT = 100_000 ether;
        vm.startPrank(trader);
        usdt.approve(address(doppiTrader), 10_000_000 ether);
        doppiTrader.start(amountUSDT, 0);
        vm.stopPrank();

        DualAssetPosition[] memory positions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(positions.length, 5);

        positions = positionLens.getPositionsSell(address(doppiTrader));
        assertEq(positions.length, 0);

        // Check USDT balance decreased
        assertEq(usdt.balanceOf(address(trader)), 9_900_000 ether);
    }

    function test_startWithPrivateHubDoesNotTopUpWhenCreditAboveThreshold() public {
        mockPrivateAutomationHub.setBillingConfig(IERC20(usdt), 10 ether, false);
        mockPrivateAutomationHub.setCreditThreshold(0);
        doppiFactory.setPrivateAutomationHub(address(mockPrivateAutomationHub));

        vm.prank(trader);
        uint32 id = doppiFactory.deployTraderBot(defaultweights);
        DoppiTrader bot = DoppiTrader(doppiFactory.traderBots(id));

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        assertEq(mockPrivateAutomationHub.depositedByBot(address(bot)), 0);
        assertEq(usdt.balanceOf(address(mockPrivateAutomationHub)), 0);
        assertEq(bot.costBasis(), 100_000 ether);
    }

    function test_startWithPrivateHubTopUpWhenCreditAtThresholdUsesRemainingCapital() public {
        uint256 defaultTopUp = 10 ether;
        mockPrivateAutomationHub.setBillingConfig(IERC20(usdt), defaultTopUp, false);
        mockPrivateAutomationHub.setCreditThreshold(defaultTopUp);
        mockPrivateAutomationHub.setCreditBalance(defaultTopUp);
        doppiFactory.setPrivateAutomationHub(address(mockPrivateAutomationHub));

        vm.prank(trader);
        uint32 id = doppiFactory.deployTraderBot(defaultweights);
        DoppiTrader bot = DoppiTrader(doppiFactory.traderBots(id));

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        assertEq(mockPrivateAutomationHub.depositedByBot(address(bot)), defaultTopUp);
        assertEq(usdt.balanceOf(address(mockPrivateAutomationHub)), defaultTopUp);
        assertEq(bot.costBasis(), 100_000 ether - defaultTopUp);
    }

    function test_startWithPrivateHubTopUpRevertsWhenFundTokenDepositIsInsufficient() public {
        mockPrivateAutomationHub.setBillingConfig(IERC20(usdt), 10 ether, false);
        mockPrivateAutomationHub.setCreditThreshold(10 ether);
        mockPrivateAutomationHub.setCreditBalance(10 ether);
        doppiFactory.setPrivateAutomationHub(address(mockPrivateAutomationHub));

        vm.prank(trader);
        uint32 id = doppiFactory.deployTraderBot(defaultweights);
        DoppiTrader bot = DoppiTrader(doppiFactory.traderBots(id));

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        vm.expectRevert(bytes4(keccak256("InsufficientTopUpAmount()")));
        bot.start(5 ether, 0);
        vm.stopPrank();
    }

    function test_startWithPrivateHubUnsupportedFundTokenLeavesCapitalUnchanged() public {
        MockToken otherToken = new MockToken("Other", "OTHER");
        mockPrivateAutomationHub.setBillingConfig(IERC20(otherToken), 10 ether, false);
        mockPrivateAutomationHub.setCreditThreshold(10 ether);
        mockPrivateAutomationHub.setCreditBalance(10 ether);
        doppiFactory.setPrivateAutomationHub(address(mockPrivateAutomationHub));

        vm.prank(trader);
        uint32 id = doppiFactory.deployTraderBot(defaultweights);
        DoppiTrader bot = DoppiTrader(doppiFactory.traderBots(id));

        vm.startPrank(trader);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        assertEq(mockPrivateAutomationHub.depositedByBot(address(bot)), 0);
        assertEq(bot.costBasis(), 100_000 ether);
    }

    function test_stop_assetA_only() public {
        
        uint256 amountUSDT = 100_000 ether;
        vm.startPrank(trader);
        usdt.approve(address(doppiTrader), 10_000_000 ether);
        doppiTrader.start(amountUSDT, 0);
        vm.stopPrank();

        uint256 afterUSDT = usdt.balanceOf(address(trader));        
                
        // ***** START doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(98_000 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        vm.stopPrank();
        
        // ***** END 
        
        // stop trader bot
        vm.startPrank(trader);
        doppiTrader.stop();
        vm.stopPrank();

        uint256 finalUSDT = usdt.balanceOf(address(trader));   
        // console.log(finalUSDT, afterUSDT);     
        assertGt(finalUSDT, afterUSDT);
    }

    function test_stop() public {
        
        _start();
        uint256 afterBTC = btc.balanceOf(address(trader));        
        uint256 afterUSDT = usdt.balanceOf(address(trader));        
                
        // ***** START doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(98_000 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        vm.stopPrank();
        
        // ***** END 
        
        // stop trader bot
        vm.startPrank(trader);
        doppiTrader.stop();
        vm.stopPrank();

        uint256 finalBTC = btc.balanceOf(address(trader));        
        uint256 finalUSDT = usdt.balanceOf(address(trader));        
        assertGt(finalUSDT, afterUSDT);
        assertGt(finalBTC, afterBTC);
        

    }

    function test_paused() public {
        
        _start();

        vm.startPrank(trader);        
        doppiTrader.setPause();
        vm.stopPrank();

        // ***** START doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        vm.stopPrank();

        DualAssetPosition[] memory positionssell = positionLens.getPositionsSell(address(doppiTrader));
        assertEq(positionssell.length, 0);
        DualAssetPosition[] memory positions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(positions.length, 0);

        // update implied volatility to trigger checkupkeep in trader bot
        _updateIV();

        // Retest doppiTrader checkUpkeep when paused, should not perform upkeep
        (upkeepNeeded, performData) = doppiTrader.checkUpkeep("");
        assertFalse(upkeepNeeded, "Should not perform upkeep when paused");

        // trade unpause it
        vm.startPrank(trader);        
        doppiTrader.setUnPause();
        vm.stopPrank();

        // checkupkeep should be needed now
        (upkeepNeeded, performData) = doppiTrader.checkUpkeep("");
        assertTrue(upkeepNeeded, "Should perform upkeep when unpaused");


    }

    function test_stop_not_yet_settle() public {
        _start();
        vm.prank(trader);
        vm.expectRevert("ActiveOrders()");
        doppiTrader.stop();
        vm.stopPrank();
    }

    function test_checkUpkeep_performUpKeep_settle_place_new_orders() public {
        _start();

        // ***** START doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(98_500 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        vm.stopPrank();
        DualAssetPosition[] memory positionssell = positionLens.getPositionsSell(address(doppiTrader));
        assertEq(positionssell.length, 0);
        DualAssetPosition[] memory positions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(positions.length, 0);

        // ***** END 

        _updateIV();

        // ***** validate trader checkupkeep to place new batch of orders

        oracle.setPrice(int256(98_600 * 1e8));
        (upkeepNeeded, performData) = doppiTrader.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(mockForwarder);
        doppiTrader.performUpkeep(performData);
        positionssell = positionLens.getPositionsSell(address(doppiTrader));
        assertGt(positionssell.length, 0);
        positions = positionLens.getPositionsBuy(address(doppiTrader));
        assertGt(positions.length, 0);
        // ***** END 
    
    }

    function test_checkUpkeep_performUpKeep_settleTradedNoStrike() public {
        
        _start();
        
        // ***** START perform opportunityBot.checkUpkeep
        oracle.setPrice(int256(104_000 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = opportunityBot.checkUpkeep("");
        // console.log(upkeepNeeded, "upkeepNeeded");
        assertTrue(upkeepNeeded);

        vm.prank(mockForwarder);
        opportunityBot.performUpkeep(performData);
        
        // // ***** END 
        

        // ***** START doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(99_500 * 1e8)); // settled sell + traded with profit in assetB with buy back + NO strike
        (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        console.log(upkeepNeeded, "upkeepNeeded");
        assertTrue(upkeepNeeded);
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        DualAssetPosition[] memory positionssell = positionLens.getPositionsSell(address(doppiTrader));
        assertEq(positionssell.length, 0);
        DualAssetPosition[] memory positions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(positions.length, 0);

        // ***** END 
        
    }

    function test_checkUpkeep_performUpKeep_settleTradedStrike() public {
        _start();
        
        // ***** START perform opportunityBot.checkUpkeep
        oracle.setPrice(int256(104_000 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = opportunityBot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(mockForwarder);
        opportunityBot.performUpkeep(performData);
        
        // ***** END 

        // ***** doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(101_900 * 1e8)); // settled sell + traded + strike
        (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        DualAssetPosition[] memory positionssell = positionLens.getPositionsSell(address(doppiTrader));
        assertEq(positionssell.length, 0);
        DualAssetPosition[] memory positions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(positions.length, 0);

        // ***** END    
    }

    function test_createUnwindPosition_onlyDoppiCore() public {
        vm.expectRevert("OnlyDoppiCore()");
        doppiTrader.createUnwindPosition(100_000 ether, 99_000 * 1e8, true);
    }

    function test_createUnwindPosition_buy() public {
        uint256 amount = 22500 ether;
        uint256 strikePrice = 99_000 * 1e8;

        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(amount, strikePrice, true);
        vm.stopPrank();
        (uint256 undo_assetB,)= doppiTrader.undoStat();
        assertGt(undo_assetB, 0);
    }

    function test_createUnwindPosition_sell() public {
        uint256 amount = 0.225 ether;
        uint256 strikePrice = 101_000 * 1e8;

        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(amount, strikePrice, false);
        vm.stopPrank();

        (,uint256 undo_assetA)= doppiTrader.undoStat();
        assertGt(undo_assetA, 0);
    }

    function test_get_buy_unrealized_PNLPositive() public {
        // Create an unwind position
        uint256 amount = 100_000 ether;
        uint256 strikePrice = 99_000 * 1e8;
        uint256 payout = amount * 1e8 / strikePrice;
        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(payout, strikePrice, true);
        vm.stopPrank();

        oracle.setPrice(int256(100_000 * 1e8));
        uint256 gasBefore = gasleft();
        int256 pnl = doppiTrader.get_unrealized_PNL();
        uint256 gasUsed = gasBefore - gasleft();
        console.log(gasUsed, "gasUsed in get_unrealized_PNL");
        
        console.logInt(pnl);
        assertGt(pnl, 0); // Should be positive (profit) when price up
    }

    function test_get_buy_unrealized_PNLNegative() public {
        // Create an unwind position
        uint256 amount = 100_000 ether;
        uint256 strikePrice = 99_000 * 1e8;
        uint256 payout = amount * 1e8 / strikePrice;
        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(payout, strikePrice, true);
        vm.stopPrank();

        oracle.setPrice(int256(98_000 * 1e8));
        uint256 gasBefore = gasleft();
        int256 pnl = doppiTrader.get_unrealized_PNL();
        uint256 gasUsed = gasBefore - gasleft();
        console.log(gasUsed, "gasUsed in get_unrealized_PNL");
        console.logInt(pnl);
        assertLt(pnl, 0); // Should be negative when price drops
    }

    function test_get_sell_unrealized_PNLPositive() public {
        // Create an unwind position
        uint256 amount = 1 ether;
        uint256 strikePrice = 99_000 * 1e8;
        uint256 payout = amount * strikePrice / 1e8;
        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(payout, strikePrice, false);
        vm.stopPrank();

        oracle.setPrice(int256(98_000 * 1e8));
        int256 pnl = doppiTrader.get_unrealized_PNL();
        console.logInt(pnl);
        assertGt(pnl, 0); // Should be positive (profit) when price drops
    }

    function test_get_sell_unrealized_PNLNegative() public {
        // Create an unwind position
        uint256 amount = 1 ether;
        uint256 strikePrice = 99_000 * 1e8;
        uint256 payout = amount * strikePrice / 1e8;
        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(payout, strikePrice, false);
        vm.stopPrank();

        oracle.setPrice(int256(100_000 * 1e8));
        int256 pnl = doppiTrader.get_unrealized_PNL();
        console.logInt(pnl);
        assertLt(pnl, 0); // Should be negative (loss) when price up
    }

    function test_checkUpkeep_noUndoPositions() public {
        // active order is placed but no undo position
        _start();
        (bool upkeepNeeded, bytes memory performData) = doppiTrader.checkUpkeep("");
        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    function test_checkUpkeep_buyUndo() public {
        // Create buy unwind position
        uint256 amount = 0.1 ether;
        uint256 strikePrice = 99_000 * 1e8;
        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(amount, strikePrice, true);
        vm.stopPrank();

        // Set price to trigger
        oracle.setPrice(int256(103_000 * 1e8));
        int256 pnl = doppiTrader.get_unrealized_PNL();
        assertEq(pnl, 400000000000000000000);
        (bool upkeepNeeded, bytes memory performData) = doppiTrader.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
    }

    function test_multiple_unwind_positions() public {
        vm.startPrank(address(doppiCore));

        uint256 price = doppiLP.getPrice();
        // Create multiple buy unwind positions, payout in assetB
        doppiTrader.createUnwindPosition(1 ether, 99_000 * 1e8, true);
        doppiTrader.createUnwindPosition(0.5 ether, 100_000 * 1e8, true);
        doppiTrader.createUnwindPosition(0.7 ether, 101_000 * 1e8, true);
        
        // Create multiple sell unwind positions, payout in assetA
        doppiTrader.createUnwindPosition(50000 ether, 100_000 * 1e8, false);
        doppiTrader.createUnwindPosition(70000 ether, 100_010 * 1e8, false);
        doppiTrader.createUnwindPosition(70000 ether, 101_000 * 1e8, false);
        
        vm.stopPrank();

        (uint256 undo_assetB, uint256 undo_assetA)= doppiTrader.undoStat();
        assertGt(undo_assetB, 0);
        assertGt(undo_assetA, 0);

        vm.startPrank(trader);
        doppiTrader.setUnwindGapMultiplier(1);
        doppiTrader.setMaxSwap(300000 ether);
        vm.stopPrank();

        // buy : those buy <= 99000 will trigger, sell : only those sold > 101500 will trigger
        oracle.setPrice(int256(100_100 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiTrader.checkUpkeep("");
        (bool performUnwind, bool placeBuy, bool placeSell) = 
            abi.decode(performData, (bool, bool, bool));
        
        assertTrue(performUnwind);

        // buy : those buy <= 100_000 will trigger, sell : only those sold > 102_500 will trigger
        oracle.setPrice(int256(101_100 * 1e8));
        (upkeepNeeded,  performData) = doppiTrader.checkUpkeep("");
        (performUnwind, placeBuy, placeSell) = 
            abi.decode(performData, (bool, bool, bool));

        assertTrue(performUnwind);
        
    }

    function test_MultipleOrderConfigs() public {
        vm.startPrank(trader);
        
        // Set multiple configs at once
        uint8[] memory strikeZones = new uint8[](3);
        uint24[] memory weights = new uint24[](3);
        strikeZones[0] = 0;
        weights[0] = 6000;        
        strikeZones[1] = 2;
        weights[1] = 3000;
        strikeZones[2] = 4;
        weights[2] = 1000;
        
        doppiTrader.setMultipleOrderConfigs(strikeZones, weights);
        
        // Verify the configuration
        OrderConfig[] memory orderConfig = doppiTrader.getOrderConfigs();
        assertEq(orderConfig[0].weight, 6000);
        assertEq(orderConfig[0].strikeZone, 0);
        assertEq(orderConfig[1].weight, 3000);
        assertEq(orderConfig[1].strikeZone, 2);
        assertEq(orderConfig[2].weight, 1000);
        assertEq(orderConfig[2].strikeZone, 4);        
        vm.stopPrank();
    }

    function test_ConfigResetWithMax6Orders() public {
        
        vm.startPrank(trader);
        vm.expectRevert("exceeds total offers");
        doppiTrader.setMaxOrder(6);
        vm.stopPrank();        
    }

    function test_updateConfig_start_placeOrders() public {
        vm.startPrank(trader);
        
        // Set multiple configs at once
        uint8[] memory strikeZones = new uint8[](3);
        uint24[] memory weights = new uint24[](3);
        strikeZones[0] = 0;
        weights[0] = 6000;        
        strikeZones[1] = 2;
        weights[1] = 3000;
        strikeZones[2] = 4;
        weights[2] = 1000;
        
        doppiTrader.setMultipleOrderConfigs(strikeZones, weights);
        
        _start();

        DualAssetPosition[] memory positions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(positions.length, 3);

        // total of USDT 50k in trader bot, 50% in liquidity
        assertEq(positions[0].amount, 30000 ether); // 60%
        assertEq(positions[1].amount, 15000 ether); // 30%
        assertEq(positions[2].amount, 5000 ether); // 10%
        
        // total of BTC 0.50 in trader bot, 0.50 in liquidity
        positions = positionLens.getPositionsSell(address(doppiTrader));
        assertEq(positions.length, 3);
        assertEq(positions[0].amount, 0.3 ether); // 60%
        assertEq(positions[1].amount, 0.15 ether); // 30%
        assertEq(positions[2].amount, 0.05 ether); // 10%

        vm.stopPrank();
    }

    function test_placeOrders_maxRoundCap_example1() public {
        
        _seedPoolCapacity(10000 ether, 1 ether);
        
        // Balance 1000, minOrderA 50, maxOrderPerRoundA 500.
        // Budget = 500; zone amounts: 25,50,100,125,200.
        // 25 is skipped, other four are placed.
        doppiCore.setMinOrder(50 ether, 0.001 ether);

        vm.startPrank(trader);
        _setExampleOrderConfig_5_10_20_25_40();
        doppiTrader.setMaxOrderPerRound(500 ether, 0);
        usdt.transfer(address(doppiTrader), 1000 ether);
        doppiTrader.placeOrders();
        vm.stopPrank();

        DualAssetPosition[] memory buyPositions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(buyPositions.length, 4);

        uint256 totalPlaced;
        for (uint256 i = 0; i < buyPositions.length; ) {
            totalPlaced += buyPositions[i].amount;
            unchecked { ++i; }
        }
        assertEq(totalPlaced, 475 ether);
    }

    function test_placeOrders_maxRoundCap_example2() public {
        
        _seedPoolCapacity(10000 ether, 1 ether);
        // Balance 50000, minOrderA 50, maxOrderPerRoundA 5000.
        // Budget = 5000; all zones are >= min and should be placed.
        doppiCore.setMinOrder(50 ether, 0.001 ether);

        vm.startPrank(trader);
        _setExampleOrderConfig_5_10_20_25_40();
        doppiTrader.setMaxOrderPerRound(5000 ether, 0);
        usdt.transfer(address(doppiTrader), 50_000 ether);
        doppiTrader.placeOrders();
        vm.stopPrank();

        DualAssetPosition[] memory buyPositions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(buyPositions.length, 5);

        uint256 totalPlaced;
        for (uint256 i = 0; i < buyPositions.length; ) {
            totalPlaced += buyPositions[i].amount;
            unchecked { ++i; }
        }
        assertEq(totalPlaced, 5000 ether);
    }

    function test_placeOrders_maxRoundCap_example3_useAvailableWhenBalanceBelowCap() public {
        
        _seedPoolCapacity(10000 ether, 1 ether);
        // Balance 500, minOrderA 50, maxOrderPerRoundA 5000.
        // Budget uses available balance (500) when below cap.
        doppiCore.setMinOrder(50 ether, 0.001 ether);

        vm.startPrank(trader);
        _setExampleOrderConfig_5_10_20_25_40();
        doppiTrader.setMaxOrderPerRound(5000 ether, 0);
        usdt.transfer(address(doppiTrader), 500 ether);
        doppiTrader.placeOrders();
        vm.stopPrank();

        DualAssetPosition[] memory buyPositions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(buyPositions.length, 4);

        uint256 totalPlaced;
        for (uint256 i = 0; i < buyPositions.length; ) {
            totalPlaced += buyPositions[i].amount;
            unchecked { ++i; }
        }
        assertEq(totalPlaced, 475 ether);
    }

    function test_placeOrders_autoRoundBudget_fallbackFrom5To4() public {
        // cap == 0 -> auto mode.
        // available=1000, min=50, equal 5 zones:
        // split 3 (new max split cap) => budget 333.333... => 66.666.../zone (valid)
        doppiCore.setMinOrder(50 ether, 0.001 ether);
        _seedPoolCapacity(10_000 ether, 1 ether);

        vm.startPrank(trader);
        doppiTrader.setMaxOrderPerRound(0, 0);
        _setEqualOrderConfig5();
        usdt.transfer(address(doppiTrader), 1000 ether);
        doppiTrader.placeOrders();
        vm.stopPrank();

        DualAssetPosition[] memory buyPositions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(buyPositions.length, 5);

        uint256 available = 1000 ether;
        uint256 expectedPerOrder = ((available / 3) * 2000) / 10000;
        uint256 totalPlaced;
        for (uint256 i = 0; i < buyPositions.length; ) {
            assertEq(buyPositions[i].amount, expectedPerOrder);
            totalPlaced += buyPositions[i].amount;
            unchecked { ++i; }
        }
        assertEq(totalPlaced, expectedPerOrder * 5);
    }

    function test_placeOrders_autoRoundBudget_fallbackFrom5To2() public {
        // cap == 0 -> auto mode.
        // available=1000, min=90, equal 5 zones:
        // split 5 => 40/zone invalid, split 4 => 50 invalid, split 3 => 66 invalid,
        // split 2 => 100 valid.
        doppiCore.setMinOrder(90 ether, 0.001 ether);
        _seedPoolCapacity(10_000 ether, 1 ether);

        vm.startPrank(trader);
        doppiTrader.setMaxOrderPerRound(0, 0);
        _setEqualOrderConfig5();
        usdt.transfer(address(doppiTrader), 1000 ether);
        doppiTrader.placeOrders();
        vm.stopPrank();

        DualAssetPosition[] memory buyPositions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(buyPositions.length, 5);

        uint256 totalPlaced;
        for (uint256 i = 0; i < buyPositions.length; ) {
            assertEq(buyPositions[i].amount, 100 ether);
            totalPlaced += buyPositions[i].amount;
            unchecked { ++i; }
        }
        assertEq(totalPlaced, 500 ether);
    }

    function test_placeOrders_scenario1_zone3_zone4_50_50_with_205usdt() public {
        vm.startPrank(trader);

        uint8[] memory strikeZones = new uint8[](2);
        uint24[] memory weights = new uint24[](2);
        strikeZones[0] = 3;
        weights[0] = 5000;
        strikeZones[1] = 4;
        weights[1] = 5000;
        doppiTrader.setMultipleOrderConfigs(strikeZones, weights);

        uint256 amountUSDT = 500 ether;
        usdt.approve(address(doppiTrader), amountUSDT);
        doppiTrader.start(amountUSDT, 0);

        OrderConfig[] memory orderConfig = doppiTrader.getOrderConfigs();
        console.log(orderConfig[0].weight, orderConfig[0].strikeZone);
        console.log(orderConfig[1].weight, orderConfig[1].strikeZone);
        // console.log(orderConfig[2].weight, orderConfig[2].strikeZone);
        
    //     assertEq(orderConfig[0].weight, 6000);
    //     assertEq(orderConfig[0].strikeZone, 0);
    //     assertEq(orderConfig[1].weight, 3000);
    //     assertEq(orderConfig[1].strikeZone, 2);
    //     assertEq(orderConfig[2].weight, 1000);
    //     assertEq(orderConfig[2].strikeZone, 4);  
        DualAssetPosition[] memory buyPositions = positionLens.getPositionsBuy(address(doppiTrader));
        assertEq(buyPositions.length, 2);
        console.log(buyPositions[0].strikePrice, buyPositions[1].strikePrice);
        console.log(buyPositions[0].amount, buyPositions[1].amount);
        // assertEq(buyPositions[0].strikePrice, 3);
        // assertEq(buyPositions[1].strikePrice, 4);

        // vm.warp(block.timestamp + 1 days + 1);
        // oracle.setPrice(int256(98_500 * 1e8));
        // (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        // assertTrue(upkeepNeeded);
        // vm.stopPrank();

        // vm.prank(mockForwarder);
        // doppiCore.performUpkeep(performData);

        // _updateIV();

        // vm.prank(trader);
        // doppiTrader.placeOrders();

        // DualAssetPosition[] memory buyPositions = doppiCore.get_positions_buy(address(doppiTrader));
        // assertEq(buyPositions.length, 2);
        // assertEq(buyPositions[0].strikePrice, 3);
        // assertEq(buyPositions[1].strikePrice, 4);

        // uint256 expectedPerOrder = amountUSDT / 2;
        // assertApproxEqAbs(buyPositions[0].amount, expectedPerOrder, 1);
        // assertApproxEqAbs(buyPositions[1].amount, expectedPerOrder, 1);

        // // Integer division may leave 1 wei USDT unallocated.
        // assertLe(usdt.balanceOf(address(doppiTrader)), 1);

        // DualAssetPosition[] memory sellPositions = doppiCore.get_positions_sell(address(doppiTrader));
        // assertEq(sellPositions.length, 0);
    }

    function test_out_of_strikezone() public {
        vm.startPrank(trader);
        
        // Set multiple configs at once
        uint8[] memory strikeZones = new uint8[](3);
        uint24[] memory weights = new uint24[](3);
        strikeZones[0] = 0;
        weights[0] = 6000;        
        strikeZones[1] = 2;
        weights[1] = 3000;
        strikeZones[2] = 6;
        weights[2] = 1000;
        
        vm.expectRevert("ExceedMaxZone()");
        doppiTrader.setMultipleOrderConfigs(strikeZones, weights);
        vm.stopPrank();
    }

    function test_more_than_ExpectedOrderLength() public {
        vm.startPrank(trader);
        
        // Set multiple configs at once
        uint8[] memory strikeZones = new uint8[](6);
        uint24[] memory weights = new uint24[](6);
        strikeZones[0] = 0;
        weights[0] = 2000;        
        strikeZones[1] = 1;
        weights[1] = 1000;        
        strikeZones[2] = 2;
        weights[2] = 2000;
        strikeZones[3] = 3;
        weights[3] = 500;
        strikeZones[4] = 4;
        weights[4] = 500;
        strikeZones[5] = 5;
        weights[5] = 4000;
        
        vm.expectRevert("MaxLimit()");
        doppiTrader.setMultipleOrderConfigs(strikeZones, weights);
        vm.stopPrank();
    }

    function test_sum_not_100() public {
        vm.startPrank(trader);
        
        // Set multiple configs at once
        uint8[] memory strikeZones = new uint8[](5);
        uint24[] memory weights = new uint24[](5);
        strikeZones[0] = 0;
        weights[0] = 2000;        
        strikeZones[1] = 1;
        weights[1] = 1000;        
        strikeZones[2] = 2;
        weights[2] = 2000;
        strikeZones[3] = 3;
        weights[3] = 500;
        strikeZones[4] = 4;
        weights[4] = 500;
        vm.expectRevert("MustHundred()");
        doppiTrader.setMultipleOrderConfigs(strikeZones, weights);
        vm.stopPrank();
    }

    // Event emit test
    function test_BulkDeposit_EmitsEvent() public {
        
        uint256 amountUSDT = 100_000 ether;
        uint256 amountBTC = 1 ether;
        vm.startPrank(trader);
        usdt.approve(address(doppiTrader), 10_000_000 ether);
        btc.approve(address(doppiTrader), 100 ether);
        doppiTrader.setMaxSwap(100000 ether);

        // Expect Deposited event
        vm.expectEmit(true, true, true, true);
        emit BulkDeposited(
            trader,
            amountBTC / 2, // amount
            false
        );    
        doppiTrader.start(amountUSDT, amountBTC);
        vm.stopPrank();
    }

    function test_UnwindPerform_EmitsEvent() public {
        
        _start();
        
        // ***** START doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(99_000 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        vm.stopPrank();
        
        (uint256 undo_assetB, uint256 undo_assetA) = doppiTrader.undoStat();
        console.log(undo_assetB, undo_assetA, "undo_assetB, undo_assetA");
        assertGt(undo_assetB, 0);
        assertEq(undo_assetA, 0);        
        
        // update IV for next orders
        _updateIV();

        // Set price to trigger . Place new orders
        oracle.setPrice(int256(103_000 * 1e8));
        (upkeepNeeded, performData) = doppiTrader.checkUpkeep("");
        vm.prank(mockForwarder);
        doppiTrader.performUpkeep(performData);
        vm.stopPrank();

        (undo_assetB, undo_assetA) = doppiTrader.undoStat();
        console.log(undo_assetB, undo_assetA, "undo_assetB, undo_assetA");
        assertGt(undo_assetB, 0);
        assertEq(undo_assetA, 0);        
        
        // trigger to unwind
        (upkeepNeeded, performData) = doppiTrader.checkUpkeep("");
        vm.expectEmit(true, true, true, true);
        // event UnwindPerformed(address indexed trader, bool isBuy, uint256 amountIn, uint256 amountOut);

        emit UnwindPerformed(
            address(doppiTrader),
            false,
            151008832038982792, // amountIn
            15382972232412060305700 // amountOut
        );    
        vm.prank(mockForwarder);
        doppiTrader.performUpkeep(performData);
        vm.stopPrank();

        (undo_assetB, undo_assetA) = doppiTrader.undoStat();
        assertEq(undo_assetB, 0);
        assertEq(undo_assetA, 0);        
        console.log(undo_assetB, undo_assetA, "undo_assetB, undo_assetA");
        
    }

    function test_partialUnwindClearsOnlyExecutedAmount_singleStrike() public {
        _start();

        // createUnwindPosition occured due to the sell side BTC to USDT striked
        // So, we expected doppiTrader to have 300 in the trader bot
        vm.prank(trader);
        usdt.transfer(address(doppiTrader), 300 ether);

        uint256 strikePrice = 102_000 * 1e8;
        uint256 initialUnwindSellAmountA = 300 ether;

        vm.prank(address(doppiCore));
        doppiTrader.createUnwindPosition(initialUnwindSellAmountA, strikePrice, false);

        vm.prank(trader);
        doppiTrader.setMaxSwap(100 ether);

        // For sell-side unwind trigger: strike >= roundedPrice + 2*gap + unwindGap.
        oracle.setPrice(int256(100_000 * 1e8));

        (bool upkeepNeeded, bytes memory performData) = doppiTrader.checkUpkeep("");
        assertTrue(upkeepNeeded);

        vm.prank(mockForwarder);
        doppiTrader.performUpkeep(performData);

        uint256 remaining = doppiTrader.getUnwindInfo(false, strikePrice);
        assertEq(remaining, 200 ether, "Remaining unwind amount should be initial - maxSwap");

        (, uint256 undoAssetA) = doppiTrader.undoStat();
        assertEq(undoAssetA, 200 ether, "undoStat should match remaining sell-side unwind amount");
    }

    function test_doppicore_doppiRouter_emergencyWithdraw() public {
        
        uint256 start_usdtbal = usdt.balanceOf(trader);
        uint256 start_btcbal = btc.balanceOf(trader);

        _start();

        vm.startPrank(trader);
        vm.expectRevert("NotEmergency()");
        doppiTrader.emergencyWithdraw();
        vm.stopPrank();
        
        // vm.startPrank(owner);
        doppiCore.setPause();
        doppiCore.setEmergencyMode(true);
        doppiRouter.setPause();
        doppiRouter.setEmergencyMode(true);
        // vm.stopPrank();
        

        vm.startPrank(trader);
        doppiTrader.emergencyWithdraw();
        doppiTrader.emergencyWithdrawLP();
        vm.stopPrank();

        uint256 end_usdtbal = usdt.balanceOf(trader);
        uint256 end_btcbal = btc.balanceOf(trader);

        console.log(start_usdtbal, end_usdtbal);
        console.log(start_btcbal, end_btcbal);
        
        // Check BTC balance decreased
        assertEq(end_usdtbal, 10000000000000000000000000);
        assertEq(end_btcbal, 100000000000000000000);

    }

    function test_unitPrice_increasesAfterGains() public {
        // Zero out treasury fee so 100% of interest stays in the portfolio.
        // With a non-zero fee the treasury extracts value, causing net loss on LP
        // that exceeds the interest credited to the bot.
        doppiCore.setTreasury(treasury, 0);

        // USDT-only start to avoid BTC price-exposure noise
        uint256 amountUSDT = 100_000 ether;
        vm.startPrank(trader);
        usdt.approve(address(doppiTrader), amountUSDT);
        doppiTrader.start(amountUSDT, 0);
        vm.stopPrank();

        // Immediately after first deposit the unit price must be exactly 1e18
        (,, uint256 unitPrice,) = doppiTrader.getPerformanceMultipliers();
        assertEq(unitPrice, 1e18);

        // Settle after 1 day — keep oracle price unchanged so LP BTC exposure is neutral;
        // unit price must rise purely from interest earned on DoppiCore positions.
        vm.warp(block.timestamp + 1 days + 1);
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);


        // Set LP gain
        usdt.mint(address(doppiLP), 100 ether);

        // Interest received increases totalValueInA without changing totalUnits
        (,, unitPrice,) = doppiTrader.getPerformanceMultipliers();
        assertGt(unitPrice, 1e18);
    }

    function test_unitPrice_secondDepositDoesNotDilute() public {
        // Zero out treasury fee so interest is net-positive for the bot.
        doppiCore.setTreasury(treasury, 0);

        // First deposit (USDT only)
        uint256 amountUSDT = 100_000 ether;
        vm.startPrank(trader);
        usdt.approve(address(doppiTrader), 10_000_000 ether);
        doppiTrader.start(amountUSDT, 0);
        vm.stopPrank();

        // Settle to generate gains — keep oracle price unchanged so LP BTC exposure is neutral
        vm.warp(block.timestamp + 1 days + 1);
        (, bytes memory performData) = doppiCore.checkUpkeep("");
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

        // Set LP gain
        usdt.mint(address(doppiLP), 100 ether);

        (,, uint256 unitPriceBefore,) = doppiTrader.getPerformanceMultipliers();
        assertGt(unitPriceBefore, 1e18); // confirm portfolio has gains

        _updateIV();

        // Second deposit of the same size
        vm.prank(trader);
        doppiTrader.start(amountUSDT, 0);

        // Unit price must be preserved within 0.01% (integer rounding only)
        (,, uint256 unitPriceAfter,) = doppiTrader.getPerformanceMultipliers();
        assertApproxEqRel(unitPriceAfter, unitPriceBefore, 1e14);
    }

    function test_stop_resetsUnitTracking() public {
        _start();

        // settle so stop() is allowed
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(98_000 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

        // confirm units and costBasis were set after start()
        assertGt(doppiTrader.totalUnits(), 0);
        assertGt(doppiTrader.costBasis(), 0);

        vm.prank(trader);
        doppiTrader.stop();

        // both must be reset to 0
        assertEq(doppiTrader.totalUnits(), 0);
        assertEq(doppiTrader.costBasis(), 0);
    }

    function test_stop_thenRestart_unitPriceStartsFresh() public {
        _start();

        // settle and stop
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(98_000 * 1e8));
        (, bytes memory performData) = doppiCore.checkUpkeep("");
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

        vm.prank(trader);
        doppiTrader.stop();

        assertEq(doppiTrader.totalUnits(), 0);

        _updateIV();

        // restart with a fresh deposit
        uint256 amountUSDT = 100_000 ether;
        vm.startPrank(trader);
        usdt.approve(address(doppiTrader), amountUSDT);
        doppiTrader.start(amountUSDT, 0);
        vm.stopPrank();

        // totalUnits should equal the deposit value (first-deposit seed path)
        uint256 price = doppiTrader.doppiLP().getPrice();
        uint256 expectedUnits = amountUSDT; // _amountB == 0
        assertEq(doppiTrader.totalUnits(), expectedUnits);
        assertEq(doppiTrader.costBasis(), expectedUnits);

        // unit price should be exactly 1e18 (no gains/losses yet on first deposit)
        (,, uint256 unitPrice,) = doppiTrader.getPerformanceMultipliers();
        assertEq(unitPrice, 1e18);
    }

    // internal
    function _start() internal {
        uint256 amountUSDT = 100_000 ether;
        uint256 amountBTC = 1 ether;
        vm.startPrank(trader);
        usdt.approve(address(doppiTrader), 10_000_000 ether);
        btc.approve(address(doppiTrader), 100 ether);
        doppiTrader.setMaxSwap(200000 * 1e18);
        doppiTrader.start(amountUSDT, amountBTC);
        vm.stopPrank();
    }

    function _updateIV() internal {
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;
        impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
    }

    function _setExampleOrderConfig_5_10_20_25_40() internal {
        uint8[] memory strikeZones = new uint8[](5);
        uint24[] memory weights = new uint24[](5);
        strikeZones[0] = 0;
        weights[0] = 500;
        strikeZones[1] = 1;
        weights[1] = 1000;
        strikeZones[2] = 2;
        weights[2] = 2000;
        strikeZones[3] = 3;
        weights[3] = 2500;
        strikeZones[4] = 4;
        weights[4] = 4000;
        doppiTrader.setMultipleOrderConfigs(strikeZones, weights);
    }

    function _setEqualOrderConfig5() internal {
        uint8[] memory strikeZones = new uint8[](5);
        uint24[] memory weights = new uint24[](5);
        for (uint8 i = 0; i < 5; ) {
            strikeZones[i] = i;
            weights[i] = 2000;
            unchecked { ++i; }
        }
        doppiTrader.setMultipleOrderConfigs(strikeZones, weights);
    }

    function _seedPoolCapacity(uint256 amountA, uint256 amountB) internal {
        vm.startPrank(owner);
        if (amountA > 0) {
            usdt.approve(address(doppiRouter), amountA);
            doppiRouter.deposit(address(usdt), amountA);
        }
        if (amountB > 0) {
            btc.approve(address(doppiRouter), amountB);
            doppiRouter.deposit(address(btc), amountB);
        }
        vm.stopPrank();
    }
}
