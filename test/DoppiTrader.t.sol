// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiTraderFactory} from "../src/mainnet/DoppiTraderFactory.sol";
import {DoppiTrader} from "../src/mainnet/DoppiTrader.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
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

contract DoppiTraderTest is Test {
    DoppiTraderFactory doppiFactory;
    DoppiTrader doppiTrader;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    BlackScholes blackScholes;
    DoppiOffer impliedVol;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    MockDoppiUpKeepManager mockDoppiUpKeepManager;
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

        // Deploy Swapper that will act as both router and pool
        swapper = new Swapper(MockToken(usdt), MockToken(btc));
        swapper.setOracle(MockOracle(oracle));    
        
        doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(usdt), IERC20(btc));
        
        configLP = TestParamLib.get_configLP();
        configLP.chainLinkFeed = address(oracle);
        configLP.router = address(swapper);
        doppiLP.setConfig(configLP);
        doppiLP.approveRouter();

        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol, address(doppiPoints));
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
            new DoppiTraderFactory(IERC20(usdt), IERC20(btc), address(doppiCore), address(doppiLP), address(doppiRouter));
        doppiLP.setDoppiTraderFactory(address(doppiFactory));
        doppiCore.setDoppiTraderFactory(doppiFactory);
        doppiFactory.setDoppiUpKeepManager(address(mockDoppiUpKeepManager));

        vm.prank(trader);
        uint32 id = doppiFactory.deployTraderBot(defaultweights);
        vm.stopPrank();
        doppiTrader = DoppiTrader(doppiFactory.traderBots(id));
        vm.prank(trader);
        doppiTrader.setForwarderAddress(mockForwarder);
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

    function test_getTotalBalances() public {
        _start();
        (uint256 totalAssetA, uint256 totalAssetB, uint256 price) = doppiTrader.getTotalBalances();
        console.log(totalAssetA, totalAssetB, price);
    }
    
    function test_start() public {
        _start();

        DualAssetPosition[] memory positions = doppiCore.get_positions_buy(address(doppiTrader));
        assertEq(positions.length, 5);

        // total of USDT 50k in trader bot, 50% in liquidity
        assertEq(positions[0].amount, 2500 ether); // 5%
        assertEq(positions[1].amount, 5000 ether); // 10%
        assertEq(positions[2].amount, 7500 ether); // 15%
        assertEq(positions[3].amount, 12500 ether); // 25%
        assertEq(positions[4].amount, 22500 ether); // 45%

        // total of BTC 0.50 in trader bot, 0.50 in liquidity
        positions = doppiCore.get_positions_sell(address(doppiTrader));
        assertEq(positions.length, 5);
        assertEq(positions[0].amount, 0.025 ether); // 5%
        assertEq(positions[1].amount, 0.05 ether); // 10%
        assertEq(positions[2].amount, 0.075 ether); // 15%
        assertEq(positions[3].amount, 0.125 ether); // 25%
        assertEq(positions[4].amount, 0.225 ether); // 45%

        // Check BTC balance decreased
        assertEq(btc.balanceOf(address(trader)), 99 ether);
        assertEq(usdt.balanceOf(address(trader)), 9_900_000 ether);

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
        doppiTrader.setUseCustomConfig(true);
        vm.stopPrank();

        _start();

        DualAssetPosition[] memory positions = doppiCore.get_positions_buy(address(doppiTrader));
        assertEq(positions.length, 3);

        // total of BTC 0.50 in trader bot, 0.50 in liquidity
        positions = doppiCore.get_positions_sell(address(doppiTrader));
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

        DualAssetPosition[] memory positions = doppiCore.get_positions_buy(address(doppiTrader));
        assertEq(positions.length, 5);

        positions = doppiCore.get_positions_sell(address(doppiTrader));
        assertEq(positions.length, 0);

        // Check USDT balance decreased
        assertEq(usdt.balanceOf(address(trader)), 9_900_000 ether);
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

        DualAssetPosition[] memory positionssell = doppiCore.get_positions_sell(address(doppiTrader));
        assertEq(positionssell.length, 0);
        DualAssetPosition[] memory positions = doppiCore.get_positions_buy(address(doppiTrader));
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
        DualAssetPosition[] memory positionssell = doppiCore.get_positions_sell(address(doppiTrader));
        assertEq(positionssell.length, 0);
        DualAssetPosition[] memory positions = doppiCore.get_positions_buy(address(doppiTrader));
        assertEq(positions.length, 0);

        // ***** END 

        _updateIV();

        // ***** validate trader checkupkeep to place new batch of orders

        oracle.setPrice(int256(98_600 * 1e8));
        (upkeepNeeded, performData) = doppiTrader.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(mockForwarder);
        doppiTrader.performUpkeep(performData);
        positionssell = doppiCore.get_positions_sell(address(doppiTrader));
        assertGt(positionssell.length, 0);
        positions = doppiCore.get_positions_buy(address(doppiTrader));
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
        DualAssetPosition[] memory positionssell = doppiCore.get_positions_sell(address(doppiTrader));
        assertEq(positionssell.length, 0);
        DualAssetPosition[] memory positions = doppiCore.get_positions_buy(address(doppiTrader));
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
        DualAssetPosition[] memory positionssell = doppiCore.get_positions_sell(address(doppiTrader));
        assertEq(positionssell.length, 0);
        DualAssetPosition[] memory positions = doppiCore.get_positions_buy(address(doppiTrader));
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

        // Create multiple buy unwind positions
        doppiTrader.createUnwindPosition(50_000 ether, 100_000 * 1e8, true);
        doppiTrader.createUnwindPosition(75_000 ether, 101_000 * 1e8, true);
        doppiTrader.createUnwindPosition(100_000 ether, 99_000 * 1e8, true);

        // Create multiple sell unwind positions
        doppiTrader.createUnwindPosition(0.5 ether, 100_000 * 1e8, false);
        doppiTrader.createUnwindPosition(0.7 ether, 101_000 * 1e8, false);

        vm.stopPrank();

        (uint256 undo_assetB, uint256 undo_assetA)= doppiTrader.undoStat();
        assertGt(undo_assetB, 0);
        assertGt(undo_assetA, 0);
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
        doppiTrader.setUseCustomConfig(true);
        
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

    function test_ConfigReset() public {
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
        doppiTrader.setUseCustomConfig(true);

        // Reset to default
        doppiTrader.resetToDefaultConfig();
        OrderConfig[] memory orderConfig = doppiTrader.getOrderConfigs();
        assertEq(orderConfig.length, 5);
        for (uint8 i = 0; i < 5; i++) {
            assertEq(orderConfig[i].weight, 2000);
        }
        assertFalse(doppiTrader.useCustomConfig());
        
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
        doppiTrader.setUseCustomConfig(true);
        
        _start();

        DualAssetPosition[] memory positions = doppiCore.get_positions_buy(address(doppiTrader));
        assertEq(positions.length, 3);

        // total of USDT 50k in trader bot, 50% in liquidity
        assertEq(positions[0].amount, 30000 ether); // 60%
        assertEq(positions[1].amount, 15000 ether); // 30%
        assertEq(positions[2].amount, 5000 ether); // 10%
        
        // total of BTC 0.50 in trader bot, 0.50 in liquidity
        positions = doppiCore.get_positions_sell(address(doppiTrader));
        assertEq(positions.length, 3);
        assertEq(positions[0].amount, 0.3 ether); // 60%
        assertEq(positions[1].amount, 0.15 ether); // 30%
        assertEq(positions[2].amount, 0.05 ether); // 10%

        vm.stopPrank();
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
        vm.expectRevert("ActiveOrders()");
        doppiTrader.emergencyWithdraw();
        vm.stopPrank();

        // let admin manually trigger emergency settlement in doppiCore to settle all positions
        vm.startPrank(doppiCore.owner());
        doppiCore.emergencySettlement(1);
        vm.stopPrank();

        vm.startPrank(trader);
        doppiTrader.emergencyWithdraw();
        // doppiTrader.emergencyWithdrawLP();
        vm.stopPrank();

        uint256 end_usdtbal = usdt.balanceOf(trader);
        uint256 end_btcbal = btc.balanceOf(trader);

        console.log(start_usdtbal, end_usdtbal);
        console.log(start_btcbal, end_btcbal);
        
        // Check BTC balance decreased
        assertEq(end_usdtbal, 9999999999999999999999999);
        assertEq(end_btcbal, 100000000000000000000);

    }

    // internal
    function _start() internal {
        uint256 amountUSDT = 100_000 ether;
        uint256 amountBTC = 1 ether;
        vm.startPrank(trader);
        usdt.approve(address(doppiTrader), 10_000_000 ether);
        btc.approve(address(doppiTrader), 100 ether);
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

}
