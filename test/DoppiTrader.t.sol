// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiTraderFactory} from "../src/mainnet/DoppiTraderFactory.sol";
import {DoppiTrader} from "../src/mainnet/DoppiTrader.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {ImpliedVol} from "../src/mainnet/ImpliedVol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {DoppiOpportunity} from "../src/mainnet/DoppiOpportunity.sol";
import {Swapper} from "../src/test/Swapper.sol";
import {DoppiConfig} from "../src/mainnet/DoppiConfig.sol";

contract DoppiTraderTest is Test {
    DoppiTraderFactory doppiFactory;
    DoppiTrader doppiTrader;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiConfig doppiConfig;
    DoppiLiquidityRouter doppiRouter;
    BlackScholes blackScholes;
    ImpliedVol impliedVol;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    DoppiOpportunity opportunityBot;
    Swapper swapper;

    address owner = address(0x1);
    address treasury = address(0x3);
    address admin = address(0x4);
    address mockForwarder = address(0x5);
    address trader = address(0x6);
    // address owner2 = address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496);

    uint24[] defaultweights;

    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;

        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(int256(100_000 ether), 18);

        blackScholes = new BlackScholes();
        impliedVol = new ImpliedVol(blackScholes);
        impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);

        // deploy doppiConfig
        // vm.startPrank(owner);
        doppiConfig = new DoppiConfig();
        // vm.stopPrank();

        // Deploy Swapper that will act as both router and pool
        swapper = new Swapper(MockToken(usdt), MockToken(btc));
        swapper.setOracle(MockOracle(oracle));    
        doppiConfig.setRouter(address(swapper));
        doppiConfig.setQuoter(address(swapper));
        doppiConfig.setTreasury(treasury);
        doppiConfig.setOracle(address(oracle));

        doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(usdt), IERC20(btc));
        doppiLP.setDoppiConfig(doppiConfig);
        doppiLP.approveRouter();
        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);

        opportunityBot = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiCore.setAdmin(address(opportunityBot), true);
        doppiCore.setForwarderAddress(mockForwarder);
        opportunityBot.setForwarderAddress(mockForwarder);
        opportunityBot.setDoppiConfig(doppiConfig);

        doppiLP.setDoppiCore(address(doppiCore));

        defaultweights.push(500);
        defaultweights.push(1000);
        defaultweights.push(1500);
        defaultweights.push(2500);
        defaultweights.push(4500);

        // Create router and set entry points
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));

        doppiFactory =
            new DoppiTraderFactory(IERC20(usdt), IERC20(btc), doppiCore, doppiLP, doppiRouter, mockForwarder);
        doppiLP.setDoppiTraderFactory(address(doppiFactory));
        doppiCore.setDoppiTraderFactory(doppiFactory);

        vm.prank(trader);
        uint256 id = doppiFactory.deployTraderBot(defaultweights);
        doppiTrader = doppiFactory.traderBots(id);
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
        assertEq(doppiTrader.doppiConfig().DEFAULT_DAYS(), 1);
        assertEq(doppiTrader.defaultassetAAmount(), 0 ether);
        assertEq(doppiTrader.defaultassetBAmount(), 0 ether);
    }

    function test_start() public {
        _start();

        DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        assertEq(positions.length, 5);

        // total of USDT 50k in trader bot, 50% in liquidity
        assertEq(positions[0].amount, 2500 ether); // 5%
        assertEq(positions[1].amount, 5000 ether); // 10%
        assertEq(positions[2].amount, 7500 ether); // 15%
        assertEq(positions[3].amount, 12500 ether); // 25%
        assertEq(positions[4].amount, 22500 ether); // 45%

        // total of BTC 0.50 in trader bot, 0.50 in liquidity
        positions = doppiCore.get_positions_sell();
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

        DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        assertEq(positions.length, 3);

        // total of BTC 0.50 in trader bot, 0.50 in liquidity
        positions = doppiCore.get_positions_sell();
        assertEq(positions.length, 3);
        
        // Check BTC balance decreased
        assertEq(btc.balanceOf(address(trader)), 99 ether);
        assertEq(usdt.balanceOf(address(trader)), 9_900_000 ether);

    }

    function test_stop() public {
        
        uint256 startBTC = btc.balanceOf(address(trader));        
        uint256 startUSDT = usdt.balanceOf(address(trader));        
        _start();
        uint256 afterBTC = btc.balanceOf(address(trader));        
        uint256 afterUSDT = usdt.balanceOf(address(trader));        
                
        // ***** START doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(98_000 ether));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        vm.stopPrank();
        
        // ***** END 
        
        // stop trader bot
        vm.startPrank(trader);
        doppiTrader.setPause();
        doppiTrader.stop();
        vm.stopPrank();

        uint256 finalBTC = btc.balanceOf(address(trader));        
        uint256 finalUSDT = usdt.balanceOf(address(trader));        
        assertGt(finalUSDT, afterUSDT);
        assertGt(finalBTC, afterBTC);
        

    }

    function test_stop_not_yet_settle() public {
        _start();
        vm.prank(trader);
        doppiTrader.setPause();
        vm.stopPrank();
        vm.prank(trader);
        vm.expectRevert("active orders");
        doppiTrader.stop();
        vm.stopPrank();
    }

    function test_checkUpkeep_performUpKeep_settle_place_new_orders() public {
        _start();

        // ***** START doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(98_500 ether));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        vm.stopPrank();
        DoppiCore.DualAssetPosition[] memory positionssell = doppiCore.get_positions_sell();
        assertEq(positionssell.length, 0);
        DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        assertEq(positions.length, 0);

        // ***** END 
        
        // ***** validate trader checkupkeep to place new batch of orders

        oracle.setPrice(int256(98_600 ether));
        (upkeepNeeded, performData) = doppiTrader.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(mockForwarder);
        doppiTrader.performUpkeep(performData);
        positionssell = doppiCore.get_positions_sell();
        assertGt(positionssell.length, 0);
        positions = doppiCore.get_positions_buy();
        assertGt(positions.length, 0);
        // ***** END 
    
    }

    function test_checkUpkeep_performUpKeep_settleTradedNoStrike() public {
        
        _start();
        
        // ***** START perform opportunityBot.checkUpkeep
        oracle.setPrice(int256(101_600 ether));
        (bool upkeepNeeded, bytes memory performData) = opportunityBot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
        (uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) =
            abi.decode(performData, (uint256, uint256[], uint256[]));
        assertGt(sellIndexes.length, 0);
        assertEq(buyIndexes.length, 0);

        vm.prank(mockForwarder);
        opportunityBot.performUpkeep(performData);
        
        DoppiCore.DualAssetPosition memory pos = doppiCore.get_sell(address(doppiTrader), 6);
        assertEq(pos.isTraded, true);

        // // ***** END 
        

        // ***** START doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(99_500 ether)); // settled sell + traded with profit in assetB with buy back + NO strike
        (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        DoppiCore.DualAssetPosition[] memory positionssell = doppiCore.get_positions_sell();
        assertEq(positionssell.length, 0);
        DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        assertEq(positions.length, 0);

        assertGt(doppiCore.get_stats(address(doppiTrader)).opportunityProfit_assetB, 0);
        assertEq(doppiCore.get_stats(address(doppiTrader)).opportunityProfit_assetA, 0); 

        // ***** END 
        
    }

    function test_checkUpkeep_performUpKeep_settleTradedStrike() public {
        _start();
        
        // ***** START perform opportunityBot.checkUpkeep
        oracle.setPrice(int256(101_600 ether));
        (bool upkeepNeeded, bytes memory performData) = opportunityBot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
        (uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) =
            abi.decode(performData, (uint256, uint256[], uint256[]));
        assertGt(sellIndexes.length, 0);
        assertEq(buyIndexes.length, 0);
        vm.prank(mockForwarder);
        opportunityBot.performUpkeep(performData);
        

        DoppiCore.DualAssetPosition memory pos = doppiCore.get_sell(address(doppiTrader), 6);
        assertEq(pos.isTraded, true);

        // ***** END 

        // ***** doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(101_900 ether)); // settled sell + traded + strike
        (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        DoppiCore.DualAssetPosition[] memory positionssell = doppiCore.get_positions_sell();
        assertEq(positionssell.length, 0);
        DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        assertEq(positions.length, 0);

        assertEq(doppiCore.get_stats(address(doppiTrader)).opportunityProfit_assetB, 0);
        assertGt(doppiCore.get_stats(address(doppiTrader)).opportunityProfit_assetA, 0); // sell btc oppotunity profit in usdt

        // ***** END    
    }

    function test_pauseTrades_onlyOwner() public {
        vm.expectRevert();
        doppiTrader.setPause();
    }

    function test_createUnwindPosition_onlyDoppiCore() public {
        vm.expectRevert("only doppicore");
        doppiTrader.createUnwindPosition(100_000 ether, 99_000 ether, true);
    }

    function test_createUnwindPosition_buy() public {
        uint256 amount = 22500 ether;
        uint256 strikePrice = 99_000 ether;

        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(amount, strikePrice, true);
        vm.stopPrank();

        DoppiTrader.Trade[] memory trades = doppiTrader.get_buy_undos();
        assertEq(trades.length, 1);
        assertEq(trades[0].origAmount, amount);
        assertEq(trades[0].origStrikePrice, strikePrice);
        assertGt(doppiTrader.undo_assetB(), 0);
    }

    function test_createUnwindPosition_sell() public {
        uint256 amount = 0.225 ether;
        uint256 strikePrice = 101_000 ether;

        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(amount, strikePrice, false);
        vm.stopPrank();

        DoppiTrader.Trade[] memory trades = doppiTrader.get_sell_undos();
        assertEq(trades.length, 1);
        assertEq(trades[0].origAmount, amount);
        assertEq(trades[0].origStrikePrice, strikePrice);
        assertGt(doppiTrader.undo_assetA(), 0);
    }

    function test_get_buy_unrealized_PNLPositive() public {
        // Create an unwind position
        uint256 amount = 100_000 ether;
        uint256 strikePrice = 99_000 ether;
        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(amount, strikePrice, true);
        vm.stopPrank();

        // uint256 currentPrice = 95_000 ether; // Below original amount
        oracle.setPrice(int256(100_000 ether));
        int256 pnl = doppiTrader.get_buy_unrealized_PNL();
        assertGt(pnl, 0); // Should be positive (profit) when price up
    }

    function test_get_buy_unrealized_PNLNegative() public {
        // Create an unwind position
        uint256 amount = 100_000 ether;
        uint256 strikePrice = 99_000 ether;
        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(amount, strikePrice, true);
        vm.stopPrank();

        oracle.setPrice(int256(98_000 ether));
        int256 pnl = doppiTrader.get_buy_unrealized_PNL();
        assertLt(pnl, 0); // Should be negative when price drops
    }

    function test_get_sell_unrealized_PNLPositive() public {
        // Create an unwind position
        uint256 amount = 1 ether;
        uint256 strikePrice = 99_000 ether;
        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(amount, strikePrice, false);
        vm.stopPrank();

        oracle.setPrice(int256(98_000 ether));
        int256 pnl = doppiTrader.get_sell_unrealized_PNL();
        assertGt(pnl, 0); // Should be positive (profit) when price drops
    }

    function test_get_sell_unrealized_PNLNegative() public {
        // Create an unwind position
        uint256 amount = 1 ether;
        uint256 strikePrice = 99_000 ether;
        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(amount, strikePrice, false);
        vm.stopPrank();

        oracle.setPrice(int256(100_000 ether));
        int256 pnl = doppiTrader.get_sell_unrealized_PNL();
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
        uint256 amount = 10_000 ether;
        uint256 strikePrice = 99_000 ether;
        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(amount, strikePrice, true);
        vm.stopPrank();

        // Set price to trigger
        oracle.setPrice(int256(103_000 ether));
        int256 pnl = doppiTrader.get_buy_unrealized_PNL();
        assertEq(pnl, 404040404040404030000);
        (bool upkeepNeeded, bytes memory performData) = doppiTrader.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
    }

    function test_performUpkeep_priceOutsideTolerance() public {
        // Create buy unwind position
        vm.startPrank(address(doppiCore));
        doppiTrader.createUnwindPosition(100_000 ether, 100_000 ether, true);
        vm.stopPrank();

        oracle.setPrice(int256(100_500 ether));
        (bool upkeepNeeded, bytes memory performData) = doppiTrader.checkUpkeep("");

        // Change price significantly
        oracle.setPrice(int256(102_000 ether));

        // Should not execute due to price tolerance
        vm.prank(mockForwarder);
        doppiTrader.performUpkeep(performData);

        // Trade should not have been executed
        assertEq(doppiTrader.buy_undo_profit(), 0);
        assertEq(doppiTrader.get_buy_undos().length, 1);
    }


    function test_multiple_unwind_positions() public {
        vm.startPrank(address(doppiCore));

        // Create multiple buy unwind positions
        doppiTrader.createUnwindPosition(50_000 ether, 100_000 ether, true);
        doppiTrader.createUnwindPosition(75_000 ether, 101_000 ether, true);
        doppiTrader.createUnwindPosition(100_000 ether, 99_000 ether, true);

        // Create multiple sell unwind positions
        doppiTrader.createUnwindPosition(0.5 ether, 100_000 ether, false);
        doppiTrader.createUnwindPosition(0.7 ether, 101_000 ether, false);

        vm.stopPrank();

        assertEq(doppiTrader.get_buy_undos().length, 3);
        assertEq(doppiTrader.get_sell_undos().length, 2);
        assertGt(doppiTrader.undo_assetB(), 0);
        assertGt(doppiTrader.undo_assetA(), 0);
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
        DoppiTrader.OrderConfig[] memory orderConfig = doppiTrader.getOrderConfigs();
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
        DoppiTrader.OrderConfig[] memory orderConfig = doppiTrader.getOrderConfigs();
        assertEq(orderConfig.length, 5);
        for (uint8 i = 0; i < 5; i++) {
            assertEq(orderConfig[i].weight, 2000);
        }
        assertFalse(doppiTrader.useCustomConfig());
        
        vm.stopPrank();
    }

    function test_ConfigResetWithMax6Orders() public {
        
        doppiConfig.setMaxOrder(6);
        
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
        DoppiTrader.OrderConfig[] memory orderConfig = doppiTrader.getOrderConfigs();
        assertEq(orderConfig.length, 6);
        for (uint8 i = 0; i < 6; i++) {
            console.log(i, orderConfig[i].weight);
            // assertEq(orderConfig[i].weight, 2000);
        }
        assertFalse(doppiTrader.useCustomConfig());
        
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

        DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        assertEq(positions.length, 3);

        // total of USDT 50k in trader bot, 50% in liquidity
        assertEq(positions[0].amount, 30000 ether); // 60%
        assertEq(positions[1].amount, 15000 ether); // 30%
        assertEq(positions[2].amount, 5000 ether); // 10%
        
        // total of BTC 0.50 in trader bot, 0.50 in liquidity
        positions = doppiCore.get_positions_sell();
        // console.log(positions[0].amount, positions[0].strikePrice);
        // console.log(positions[1].amount, positions[1].strikePrice);
        // console.log(positions[2].amount, positions[2].strikePrice);
        
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
        
        vm.expectRevert("not more than max zone");
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
        
        vm.expectRevert("not more than max");
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
        vm.expectRevert("sum must equal 100%");
        doppiTrader.setMultipleOrderConfigs(strikeZones, weights);
        vm.stopPrank();
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

    
}
