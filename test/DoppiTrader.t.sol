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

contract DoppiTraderTest is Test {
    DoppiTraderFactory doppiFactory;
    DoppiTrader trader;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    BlackScholes blackScholes;
    ImpliedVol impliedVol;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    DoppiOpportunity opportunityBot;

    address owner = address(0x1);
    address treasury = address(0x3);
    address admin = address(0x4);
    uint24[] weights;

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

        doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(usdt), IERC20(btc), treasury);
        doppiLP.setOracle(address(oracle));

        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);

        opportunityBot = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiCore.setAdmin(address(opportunityBot), true);

        doppiLP.setDualAsset(address(doppiCore));

        weights.push(500);
        weights.push(1000);
        weights.push(1500);
        weights.push(2500);
        weights.push(4500);

        // Create router and set entry points
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));

        doppiFactory =
            new DoppiTraderFactory(IERC20(usdt), IERC20(btc), doppiCore, doppiLP, doppiRouter);
        doppiLP.setDoppiTraderFactory(address(doppiFactory));

        vm.prank(owner);
        uint256 id = doppiFactory.deployTraderBot(weights);
        trader = doppiFactory.traderBots(id);

        usdt.mint(owner, 10_000_000 ether);
        btc.mint(owner, 100 ether);

        usdt.mint(admin, 1_000_000 ether);
        btc.mint(admin, 20 ether);
        
        // vm.startPrank(admin);
        // usdt.approve(address(doppiRouter), 1_000_000 ether);
        // btc.approve(address(doppiRouter), 20 ether);
        // doppiRouter.deposit(address(usdt), 1_000_000 ether);
        // doppiRouter.deposit(address(btc), 20 ether);
        // vm.stopPrank();
    }

    function test_constructor() public view {
        assertEq(trader.owner(), owner);
        assertEq(address(trader.assetA()), address(usdt));
        assertEq(address(trader.assetB()), address(btc));
        assertEq(address(trader.doppiLP()), address(doppiLP));
        assertEq(address(trader.doppiCore()), address(doppiCore));
        assertEq(trader.DEFAULT_DAYS(), 1);
        assertEq(trader.defaultassetAAmount(), 0 ether);
        assertEq(trader.defaultassetBAmount(), 0 ether);
    }

    function test_start() public {
        vm.startPrank(owner);
        _start();
        vm.stopPrank();

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

        uint256 totalAssetsA = doppiRouter.entryPointA().totalAssets();
        uint256 totalAssetsB = doppiRouter.entryPointB().totalAssets();
        // console.log(totalAssetsA, totalAssetsB);

        // Check BTC balance decreased
        assertLt(btc.balanceOf(address(trader)), 1 ether);
        assertLt(usdt.balanceOf(address(trader)), 100_000 ether);
        assertEq(trader.ratio_assetA(), 5000);
        assertEq(trader.ratio_assetB(), 5000);

        // Check that tokens were transferred (some goes to LP, so balance increases)
        // assertGe(usdt.balanceOf(address(trader)), 200_000 ether);
    }

    function test_stop_not_yet_settle() public {
        vm.startPrank(owner);
        _start();
        trader.pauseTrades();
        // vm.warp(block.timestamp + 1 days);
        vm.expectRevert("active order exist");
        trader.stop();
        vm.stopPrank();
    }

    function test_checkUpkeep_performUpKeep_settleNoTrade() public {
        vm.startPrank(owner);
        _start();
        vm.stopPrank();

        // ***** START doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(98_500 ether));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        doppiCore.performUpkeep(performData);
        DoppiCore.DualAssetPosition[] memory positionssell = doppiCore.get_positions_sell();
        assertEq(positionssell.length, 0);
        DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        assertEq(positions.length, 0);

        // console.log(doppiCore.get_stats(address(trader)).opportunityProfit_assetB);
        // console.log(doppiCore.get_stats(address(trader)).opportunityProfit_assetA);
        // console.log(doppiCore.get_stats(address(trader)).settleProfit_assetA);
        // console.log(doppiCore.get_stats(address(trader)).settleProfit_assetB);
        // console.log(doppiCore.get_stats(address(trader)).interestPaid_assetA);
        // console.log(doppiCore.get_stats(address(trader)).interestPaid_assetB);

        // ***** END 
        
        // ***** validate trader checkupkeep to place new batch of orders
        oracle.setPrice(int256(98_600 ether));
        (upkeepNeeded, performData) = trader.checkUpkeep("");
        assertTrue(upkeepNeeded);
        trader.performUpkeep(performData);
        positionssell = doppiCore.get_positions_sell();
        assertGt(positionssell.length, 0);
        positions = doppiCore.get_positions_buy();
        assertGt(positions.length, 0);
        // ***** END 
    
    }

    function test_checkUpkeep_performUpKeep_settleTradedNoStrike() public {
        vm.startPrank(owner);
        _start();
        vm.stopPrank();

        // ***** START perform opportunityBot.checkUpkeep
        oracle.setPrice(int256(101_600 ether));
        (bool upkeepNeeded, bytes memory performData) = opportunityBot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
        (uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) =
            abi.decode(performData, (uint256, uint256[], uint256[]));
        assertGt(sellIndexes.length, 0);
        assertEq(buyIndexes.length, 0);
        opportunityBot.performUpkeep(performData);
        
        // DualAsset.KeyPosition[] memory keyPositions = doppiCore.get_sell_positions_id(address(trader));
        // for(uint8 i=0; i< keyPositions.length; i++){
        //     console.log(keyPositions[i].owner, keyPositions[i].positionId);
        // }
        DoppiCore.DualAssetPosition memory pos = doppiCore.get_sell(address(trader), 6);
        assertEq(pos.isTraded, true);

        // ***** END 
        

        // ***** START doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(99_500 ether)); // settled sell + traded with profit in assetB with buy back + NO strike
        (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        doppiCore.performUpkeep(performData);
        DoppiCore.DualAssetPosition[] memory positionssell = doppiCore.get_positions_sell();
        assertEq(positionssell.length, 0);
        DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        assertEq(positions.length, 0);

        // console.log(doppiCore.get_stats(address(trader)).opportunityProfit_assetB);
        // console.log(doppiCore.get_stats(address(trader)).opportunityProfit_assetA);
        // console.log(doppiCore.get_stats(address(trader)).settleProfit_assetA);
        // console.log(doppiCore.get_stats(address(trader)).settleProfit_assetB);
        // console.log(doppiCore.get_stats(address(trader)).interestPaid_assetA);
        // console.log(doppiCore.get_stats(address(trader)).interestPaid_assetB);

        assertGt(doppiCore.get_stats(address(trader)).opportunityProfit_assetB, 0);
        assertEq(doppiCore.get_stats(address(trader)).opportunityProfit_assetA, 0); 

        // ***** END 
        
    }

    function test_checkUpkeep_performUpKeep_settleTradedStrike() public {
        vm.startPrank(owner);
        _start();
        vm.stopPrank();

        // ***** START perform opportunityBot.checkUpkeep
        oracle.setPrice(int256(101_600 ether));
        (bool upkeepNeeded, bytes memory performData) = opportunityBot.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
        (uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) =
            abi.decode(performData, (uint256, uint256[], uint256[]));
        assertGt(sellIndexes.length, 0);
        assertEq(buyIndexes.length, 0);
        opportunityBot.performUpkeep(performData);
        
        // DualAsset.KeyPosition[] memory keyPositions = doppiCore.get_sell_positions_id(address(trader));
        // for(uint8 i=0; i< keyPositions.length; i++){
        //     console.log(keyPositions[i].owner, keyPositions[i].positionId);
        // }
        DoppiCore.DualAssetPosition memory pos = doppiCore.get_sell(address(trader), 6);
        assertEq(pos.isTraded, true);

        // ***** END 

        // ***** doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(101_900 ether)); // settled sell + traded + strike
        (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        doppiCore.performUpkeep(performData);
        DoppiCore.DualAssetPosition[] memory positionssell = doppiCore.get_positions_sell();
        assertEq(positionssell.length, 0);
        DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        assertEq(positions.length, 0);

        assertEq(doppiCore.get_stats(address(trader)).opportunityProfit_assetB, 0);
        assertGt(doppiCore.get_stats(address(trader)).opportunityProfit_assetA, 0); // sell btc oppotunity profit in usdt

        // console.log(doppiCore.get_stats(address(trader)).opportunityProfit_assetB);
        // console.log(doppiCore.get_stats(address(trader)).opportunityProfit_assetA);
        // console.log(doppiCore.get_stats(address(trader)).settleProfit_assetA);
        // console.log(doppiCore.get_stats(address(trader)).settleProfit_assetB);
        // console.log(doppiCore.get_stats(address(trader)).interestPaid_assetA);
        // console.log(doppiCore.get_stats(address(trader)).interestPaid_assetB);
        
        // ***** END    
    }

    function test_opportunity_bot_trader_buyUndo() public {
        
        // Fork BSC mainnet
        // vm.createSelectFork("bsc", 57458972);
        
        // vm.startPrank(admin);
        // usdt.approve(address(doppiRouter), 1_000_000 ether);
        // btc.approve(address(doppiRouter), 20 ether);
        // doppiRouter.deposit(address(usdt), 1_000_000 ether);
        // doppiRouter.deposit(address(btc), 20 ether);
        // vm.stopPrank();

        vm.startPrank(owner);
        _start();
        vm.stopPrank();

        // // ***** START perform opportunityBot.checkUpkeep
        // oracle.setPrice(int256(97_600 ether));
        // (bool upkeepNeeded, bytes memory performData) = opportunityBot.checkUpkeep("");
        // assertTrue(upkeepNeeded);
        // assertGt(performData.length, 0);
        // opportunityBot.performUpkeep(performData);
        // // ***** END 

        // ***** doppiCore settle buy and sell order
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(96_500 ether)); // settled buy + no traded + strike
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        // (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        doppiCore.performUpkeep(performData);        
        // ***** END  


        // ***** traderbot unwind opportunity
        // assertGt(trader.get_buy_undos().length, 0);    
        // vm.warp(block.timestamp + 1 days + 1);
        // oracle.setPrice(int256(100_000 ether)); // settled buy + no traded + strike
        // (upkeepNeeded, performData) = trader.checkUpkeep("");
        // assertTrue(upkeepNeeded);
        // doppiCore.performUpkeep(performData);    
        // assertEq(trader.get_buy_undos().length, 0);    
        // ***** END  



        // // Create an unwind position with even smaller amount
        // vm.startPrank(address(doppiCore));
        // trader.createUnwindPosition(1000 ether, 100_000 ether, true); // Very small amount
        // vm.stopPrank();

        // // Add more BTC to trader for swapping
        // btc.mint(address(trader), 10 ether);

        // // Test with extreme profit margin
        // uint256 triggerPrice = 200_000 ether; // 100% above strike

        // oracle.setPrice(int256(triggerPrice));

        // // Get initial balances
        // uint256 initialTraderUSDT = usdt.balanceOf(address(trader));
        // console.log("Initial trader USDT:", initialTraderUSDT);

        // trader.opportunity_bot_trader(triggerPrice, 0, true);
        // console.log("Trade executed successfully");
        // assertEq(trader.get_buy_undos().length, 0);
    }

    function test_pauseTrades_onlyOwner() public {
        vm.expectRevert();
        trader.pauseTrades();
    }

    function test_createUnwindPosition_onlyDualAsset() public {
        vm.expectRevert("only Dual Asset");
        trader.createUnwindPosition(100_000 ether, 99_000 ether, true);
    }

    function test_createUnwindPosition_buy() public {
        uint256 amount = 22500 ether;
        uint256 strikePrice = 99_000 ether;

        vm.startPrank(address(doppiCore));
        trader.createUnwindPosition(amount, strikePrice, true);
        vm.stopPrank();

        DoppiTrader.Trade[] memory trades = trader.get_buy_undos();
        assertEq(trades.length, 1);
        assertEq(trades[0].origAmount, amount);
        assertEq(trades[0].origStrikePrice, strikePrice);
        assertGt(trader.undo_assetB(), 0);
    }

    function test_createUnwindPosition_sell() public {
        uint256 amount = 0.225 ether;
        uint256 strikePrice = 101_000 ether;

        vm.startPrank(address(doppiCore));
        trader.createUnwindPosition(amount, strikePrice, false);
        vm.stopPrank();

        DoppiTrader.Trade[] memory trades = trader.get_sell_undos();
        assertEq(trades.length, 1);
        assertEq(trades[0].origAmount, amount);
        assertEq(trades[0].origStrikePrice, strikePrice);
        assertGt(trader.undo_assetA(), 0);
    }

    function test_get_buy_unrealized_PNLPositive() public {
        // Create an unwind position
        uint256 amount = 100_000 ether;
        uint256 strikePrice = 99_000 ether;
        vm.startPrank(address(doppiCore));
        trader.createUnwindPosition(amount, strikePrice, true);
        vm.stopPrank();

        // uint256 currentPrice = 95_000 ether; // Below original amount
        oracle.setPrice(int256(100_000 ether));
        int256 pnl = trader.get_buy_unrealized_PNL();
        assertGt(pnl, 0); // Should be positive (profit) when price up
    }

    function test_get_buy_unrealized_PNLNegative() public {
        // Create an unwind position
        uint256 amount = 100_000 ether;
        uint256 strikePrice = 99_000 ether;
        vm.startPrank(address(doppiCore));
        trader.createUnwindPosition(amount, strikePrice, true);
        vm.stopPrank();

        oracle.setPrice(int256(98_000 ether));
        int256 pnl = trader.get_buy_unrealized_PNL();
        assertLt(pnl, 0); // Should be negative when price drops
    }

    function test_get_sell_unrealized_PNLPositive() public {
        // Create an unwind position
        uint256 amount = 1 ether;
        uint256 strikePrice = 99_000 ether;
        vm.startPrank(address(doppiCore));
        trader.createUnwindPosition(amount, strikePrice, false);
        vm.stopPrank();

        oracle.setPrice(int256(98_000 ether));
        int256 pnl = trader.get_sell_unrealized_PNL();
        assertGt(pnl, 0); // Should be positive (profit) when price drops
    }

    function test_get_sell_unrealized_PNLNegative() public {
        // Create an unwind position
        uint256 amount = 1 ether;
        uint256 strikePrice = 99_000 ether;
        vm.startPrank(address(doppiCore));
        trader.createUnwindPosition(amount, strikePrice, false);
        vm.stopPrank();

        oracle.setPrice(int256(100_000 ether));
        int256 pnl = trader.get_sell_unrealized_PNL();
        assertLt(pnl, 0); // Should be negative (loss) when price up
    }

    function test_checkUpkeep_noUndoPositions() public {
        // active order is placed but no undo position
        vm.startPrank(owner);
        _start();
        vm.stopPrank();
        (bool upkeepNeeded, bytes memory performData) = trader.checkUpkeep("");
        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    function test_checkUpkeep_buyUndo() public {
        // Create buy unwind position
        uint256 amount = 10_000 ether;
        uint256 strikePrice = 99_000 ether;
        vm.startPrank(address(doppiCore));
        trader.createUnwindPosition(amount, strikePrice, true);
        vm.stopPrank();

        // Set price to trigger
        oracle.setPrice(int256(103_000 ether));
        int256 pnl = trader.get_buy_unrealized_PNL();
        // console.log(pnl);
        (bool upkeepNeeded, bytes memory performData) = trader.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
        // trader.performUpkeep(performData);
        // console.log(trader.buy_undo_profit(), "profit");
    }

    // internal
    function _start() internal {
        uint256 amountUSDT = 100_000 ether;
        uint256 amountBTC = 1 ether;
        usdt.approve(address(trader), 10_000_000 ether);
        btc.approve(address(trader), 100 ether);
        trader.start(amountUSDT, amountBTC);
    }

    

    // function test_opportunity_bot_trader_sellUndo() public {
    //     // Create an unwind position with very small amount
    //     vm.startPrank(address(doppiCore));
    //     trader.createUnwindPosition(0.01 ether, 100_000 ether, false);
    //     vm.stopPrank();

    //     // Add more USDT to trader for swapping
    //     usdt.mint(address(trader), 1_000_000 ether);

    //     uint256 triggerPrice = 50_000 ether; // 50% below strike for extreme profit

    //     oracle.setPrice(int256(triggerPrice));

    //     trader.opportunity_bot_trader(triggerPrice, 0, false);
    //     console.log("Sell trade executed successfully");
    //     assertEq(trader.get_sell_undos().length, 0);
    // }

    // function test_performUpkeep_PlaceNewOrder() public {
    //     (bool upkeepNeeded, bytes memory performData) = trader.checkUpkeep("");
    //     assertTrue(upkeepNeeded);
    //     // Change price significantly
    //     oracle.setPrice(int256(100_000 ether));
    //     trader.performUpkeep(performData);
    //     assertEq(doppiCore.getBuyPositionCount(address(trader)), 5);
    //     assertEq(doppiCore.getSellPositionCount(address(trader)), 5);
    //     // assertEq(doppiCore.get_buy(address(this)), 0);
    // }

    // function test_performUpkeep() public {
    //     // Create buy unwind position with very small amount
    //     vm.startPrank(address(doppiCore));
    //     trader.createUnwindPosition(1000 ether, 100_000 ether, true);
    //     vm.stopPrank();

    //     // Add more BTC to trader for swapping
    //     btc.mint(address(trader), 10 ether);

    //     // Set price to trigger with extreme margin
    //     oracle.setPrice(int256(200_000 ether));

    //     (bool upkeepNeeded, bytes memory performData) = trader.checkUpkeep("");
    //     assertTrue(upkeepNeeded);

    //     // Try performUpkeep and handle potential underflow
    //     trader.performUpkeep(performData);
    //     console.log("PerformUpkeep executed successfully");
    //     assertEq(trader.get_buy_undos().length, 0);
    // }

    // function test_performUpkeep_priceOutsideTolerance() public {
    //     // Create buy unwind position
    //     vm.startPrank(address(doppiCore));
    //     trader.createUnwindPosition(100_000 ether, 100_000 ether, true);
    //     vm.stopPrank();

    //     oracle.setPrice(int256(100_500 ether));
    //     (bool upkeepNeeded, bytes memory performData) = trader.checkUpkeep("");

    //     // Change price significantly
    //     oracle.setPrice(int256(102_000 ether));

    //     // Should not execute due to price tolerance
    //     trader.performUpkeep(performData);

    //     // Trade should not have been executed
    //     assertEq(trader.buy_undo_profit(), 0);
    //     assertEq(trader.get_buy_undos().length, 1);
    // }

    // function testFuzz_place_buys_withDifferentAmounts(uint256 amount) public {
    //     amount = bound(amount, 1000 ether, 500_000 ether);

    //     // Mint additional tokens
    //     usdt.mint(address(trader), amount);

    //     bool success = trader.place_buys();
    //     assertTrue(success);

    //     DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
    //     assertEq(positions.length, 5);
    // }

    // function testFuzz_place_sells_withDifferentAmounts(uint256 amount) public {
    //     amount = bound(amount, 1 ether, 10 ether);

    //     // Mint additional tokens
    //     btc.mint(address(trader), amount);

    //     bool success = trader.place_sells();
    //     assertTrue(success);

    //     DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_sell();
    //     assertEq(positions.length, 5);
    // }

    // function test_multiple_unwind_positions() public {
    //     vm.startPrank(address(doppiCore));

    //     // Create multiple buy unwind positions
    //     trader.createUnwindPosition(50_000 ether, 100_000 ether, true);
    //     trader.createUnwindPosition(75_000 ether, 101_000 ether, true);
    //     trader.createUnwindPosition(100_000 ether, 99_000 ether, true);

    //     // Create multiple sell unwind positions
    //     trader.createUnwindPosition(0.5 ether, 100_000 ether, false);
    //     trader.createUnwindPosition(0.7 ether, 101_000 ether, false);

    //     vm.stopPrank();

    //     assertEq(trader.get_buy_undos().length, 3);
    //     assertEq(trader.get_sell_undos().length, 2);
    //     assertGt(trader.undo_assetB(), 0);
    //     assertGt(trader.undo_assetA(), 0);
    // }
}
