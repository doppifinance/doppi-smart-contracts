// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
import {DoppiTrader} from "../../src/mainnet/DoppiTrader.sol";
import {DoppiCore} from "../../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../../src/mainnet/DoppiLiquidityRouter.sol";
import {BlackScholes} from "../../src/mainnet/BlackScholes.sol";
import {ImpliedVol} from "../../src/mainnet/ImpliedVol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../../src/test/MockToken.sol";
import {MockOracle} from "../../src/test/MockOracle.sol";
import {DoppiOpportunity} from "../../src/mainnet/DoppiOpportunity.sol";
import {Swapper} from "../../src/test/Swapper.sol";


contract BasicFlowTest is Test {
    DoppiTraderFactory doppiFactory;
    DoppiTrader trader;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    // BlackScholes blackScholes;
    ImpliedVol impliedVol;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    DoppiOpportunity opportunityBot;
    Swapper public swapper;

    address owner = address(0x1);
    address treasury = address(0x3);
    address admin = address(0x4);
    address mockForwarder = address(0x5);

    // uint24[] weights;

    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        
        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(int256(100_000 ether), 18);

        vm.prank(owner);
        // Deploy Swapper that will act as both router and pool
        swapper = _setupMockSwapper(address(usdt), address(btc), address(oracle));        
        impliedVol = _setupIV();
        doppiLP = _setupLP(address(usdt), address(btc), address(oracle), address(swapper));
        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);
        opportunityBot = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiFactory = new DoppiTraderFactory(IERC20(usdt), IERC20(btc), doppiCore, doppiLP, doppiRouter, mockForwarder);

        // Setup initial setting
        doppiCore.setAdmin(address(opportunityBot), true);
        doppiCore.setForwarderAddress(mockForwarder);
        doppiLP.setDualAsset(address(doppiCore));
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));
        doppiLP.setDoppiTraderFactory(address(doppiFactory));

        vm.prank(owner);
        trader = _setupTraderBot();
        usdt.mint(owner, 1_000_000 ether);
        btc.mint(owner, 20 ether);

        usdt.mint(admin, 1_000_000 ether);
        btc.mint(admin, 20 ether);
    }

    function test_lp_swapfallback_sell() public {
        
        // start trader bot
        _start();
        // ***** doppiCore settle buy and sell order
        _doppiCoreCheckUpkeep_performUpkeep(126_500 ether);     
        // ***** END  
        assertGt(doppiCore.get_stats(address(trader)).settleProfit_assetA, 0); // profit on sell and profit in USDT
        assertEq(doppiCore.get_stats(address(trader)).settleProfit_assetB, 0); // no profit on buy
        assertGt(doppiCore.get_stats(address(trader)).interestPaid_assetA, 0); 
        assertGt(doppiCore.get_stats(address(trader)).interestPaid_assetB, 0); 

        
    }

    function test_lp_swapfallback_buy() public {
        
        // start trader bot
        _start();
        // ***** doppiCore settle buy and sell order
        _doppiCoreCheckUpkeep_performUpkeep(96_500 ether);     
        // ***** END  
        assertEq(doppiCore.get_stats(address(trader)).settleProfit_assetA, 0); // no profit on buy
        assertGt(doppiCore.get_stats(address(trader)).settleProfit_assetB, 0); // profit on buy and profit in BTC
        assertGt(doppiCore.get_stats(address(trader)).interestPaid_assetA, 0); 
        assertGt(doppiCore.get_stats(address(trader)).interestPaid_assetB, 0); 

        // console.log(doppiCore.get_stats(address(trader)).opportunityProfit_assetB);
        // console.log(doppiCore.get_stats(address(trader)).opportunityProfit_assetA);
        // console.log(doppiCore.get_stats(address(trader)).settleProfit_assetA);
        // console.log(doppiCore.get_stats(address(trader)).settleProfit_assetB);
        // console.log(doppiCore.get_stats(address(trader)).interestPaid_assetA);
        // console.log(doppiCore.get_stats(address(trader)).interestPaid_assetB);
    }

    function test_lp_swapfallback_sell_with_opportunity() public {
        
        // start trader bot
        _start();

        // ***** START perform opportunityBot.checkUpkeep
        _doppiOpportunityCheckUpkeep_performUpkeep(126_500 ether); // set higher price for sell opp
        DoppiCore.KeyPosition[] memory keyPositions = doppiCore.get_sell_positions_id(address(trader));
        for(uint8 i=0; i< keyPositions.length; i++){
            DoppiCore.DualAssetPosition memory pos = doppiCore.get_sell(address(trader), keyPositions[i].positionId);
            assertEq(pos.isTraded, true);
        }
        keyPositions = doppiCore.get_buy_positions_id(address(trader));
        for(uint8 i=0; i< keyPositions.length; i++){
            DoppiCore.DualAssetPosition memory pos = doppiCore.get_buy(address(trader), keyPositions[i].positionId);
            assertEq(pos.isTraded, false);
        }
        // ***** END 
        // ***** START perform opportunityBot.checkUpkeep to unwind opportunity trades
        _doppiOpportunityCheckUpkeep_performUpkeep(99_500 ether); 
        keyPositions = doppiCore.get_sell_positions_id(address(trader));
        for(uint8 i=0; i< keyPositions.length; i++){
            DoppiCore.DualAssetPosition memory pos = doppiCore.get_sell(address(trader), keyPositions[i].positionId);
            assertEq(pos.isTraded, false);
            assertGt(opportunityBot.profitAssetB(), 0); // profit recorded on BTC
            assertEq(opportunityBot.profitAssetA(), 0);
        
        }
        // ***** END 

        // ***** doppiCore settle buy and sell order
        _doppiCoreCheckUpkeep_performUpkeep(105_500 ether);    
        assertEq(doppiCore.getBuyPositionCount(), 0); 
        assertEq(doppiCore.getSellPositionCount(), 0);
        assertGt(doppiCore.get_stats(address(trader)).settleProfit_assetA, 0); // profit on sell and profit in USDT
        assertEq(doppiCore.get_stats(address(trader)).settleProfit_assetB, 0); // no profit on buy
        assertGt(doppiCore.get_stats(address(trader)).interestPaid_assetA, 0); 
        assertGt(doppiCore.get_stats(address(trader)).interestPaid_assetB, 0); 
        // ***** END  
        
    }

    // internal
    function _start() internal {

        vm.startPrank(owner);
        uint256 amountUSDT = 100_000 ether;
        uint256 amountBTC = 1 ether;
        usdt.approve(address(trader), 10_000_000 ether);
        btc.approve(address(trader), 100 ether);
        trader.start(amountUSDT, amountBTC);
        vm.stopPrank();
    }

    function _setupTraderBot() internal returns (DoppiTrader _traderbot) {
        
        uint24[] memory weights = new uint24[](5);
        weights[0] = 500;
        weights[1] = 1000;
        weights[2] = 1500;
        weights[3] = 2500;
        weights[4] = 4500;
        uint256 id = doppiFactory.deployTraderBot(weights);
        _traderbot = doppiFactory.traderBots(id);
    }
    

    function _setupLP(address _assetA, address _assetB, address _oracle, address _swapper) internal returns (DoppiLiquidity _doppiLP) {
        _doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(_assetA), IERC20(_assetB), treasury);
        _doppiLP.setOracle(address(_oracle));
        // Set the mock oracle, router, pool, and quoter
        _doppiLP.setOracle(address(_oracle));
        // setup mock pancakeswap router
        _doppiLP.setRouter(address(_swapper));
        _doppiLP.setPancakeV3Pool(address(_swapper));
        _doppiLP.setQuoter(address(_swapper));
        _doppiLP.approveRouter();
    }
    

    function _setupIV() internal returns (ImpliedVol _impliedVol) {
        
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;
        BlackScholes blackScholes = new BlackScholes();
        _impliedVol = new ImpliedVol(blackScholes);
        _impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
    }

    function _setupMockSwapper(address _usdt, address _btc, address _oracle) internal returns (Swapper _swapper) {
        
        // Deploy Swapper that will act as both router and pool
        _swapper = new Swapper(MockToken(_usdt), MockToken(_btc));
        _swapper.setOracle(MockOracle(_oracle));
    }
    
    function _doppiCoreCheckUpkeep_performUpkeep(uint256 _settlePrice) internal {
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(_settlePrice)); // settled buy + no traded + strike
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);  
    }

    function _doppiOpportunityCheckUpkeep_performUpkeep(uint256 _price) internal {
        
        oracle.setPrice(int256(_price));
        (bool upkeepNeeded, bytes memory performData) = opportunityBot.checkUpkeep("");
        // console.log(upkeepNeeded, "upkeepNeeded");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
        vm.prank(mockForwarder);
        opportunityBot.performUpkeep(performData);
    }
    
      


}
