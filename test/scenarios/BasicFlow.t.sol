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
import {DoppiConfig} from "../../src/mainnet/DoppiConfig.sol";


contract BasicFlowTest is Test {
    DoppiTraderFactory doppiFactory;
    DoppiTrader traderBot;
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
    DoppiConfig doppiConfig;
    
    address trader = address(0x6);
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
        oracle = new MockOracle(int256(100_000 * 1e8), 8);

        swapper = _setupMockSwapper(address(usdt), address(btc), address(oracle));        
        
        doppiConfig = new DoppiConfig();
        doppiConfig.setRouter(address(swapper));
        doppiConfig.setQuoter(address(swapper));
        doppiConfig.setTreasury(treasury);
        doppiConfig.setPancakeV3Pool(address(swapper)); 
        doppiConfig.setOracle(address(oracle));
        
        impliedVol = _setupIV();
        doppiLP = _setupLP(address(usdt), address(btc));
        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);
        opportunityBot = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiFactory = new DoppiTraderFactory(IERC20(usdt), IERC20(btc), doppiCore, doppiLP, doppiRouter);

        opportunityBot.setForwarderAddress(mockForwarder);
        opportunityBot.setDoppiConfig(doppiConfig);
        doppiCore.setForwarderAddress(mockForwarder);
        doppiCore.setAdmin(address(opportunityBot), true);
        doppiLP.setForwarderAddress(mockForwarder);
        doppiLP.setDoppiCore(address(doppiCore));
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));
        doppiLP.setDoppiTraderFactory(address(doppiFactory));
        doppiCore.setDoppiTraderFactory(doppiFactory);

        traderBot = _setupTraderBot();
        usdt.mint(owner, 1_000_000 ether);
        btc.mint(owner, 20 ether);
        usdt.mint(trader, 1_000_000 ether);
        btc.mint(trader, 20 ether);
        usdt.mint(admin, 1_000_000 ether);
        btc.mint(admin, 20 ether);
    }

    function test_lp_swapfallback_sell() public {
        
        // start trader bot
        _start();
        // ***** doppiCore settle buy and sell order
        _doppiCoreCheckUpkeep_performUpkeep(126_500 * 1e8);     
        // ***** END  
    }

    function test_lp_swapfallback_buy() public {
        
        // start trader bot
        _start();
        // ***** doppiCore settle buy and sell order
        _doppiCoreCheckUpkeep_performUpkeep(97_500 * 1e8);     
        // ***** END  
    }

    function test_lp_swapfallback_sell_with_opportunity() public {
        
        // start trader bot
        _start();

        // ***** START perform opportunityBot.checkUpkeep
        _doppiOpportunityCheckUpkeep_performUpkeep(126_500 * 1e8); // set higher price for sell opp
        DoppiCore.KeyPosition[] memory keyPositions = doppiCore.get_sell_positions_id(address(traderBot));
        for(uint8 i=0; i< keyPositions.length; i++){
            DoppiCore.DualAssetPosition memory pos = doppiCore.get_sell(address(traderBot), keyPositions[i].positionId);
            assertEq(pos.isTraded, true);
        }
        keyPositions = doppiCore.get_buy_positions_id(address(traderBot));
        for(uint8 i=0; i< keyPositions.length; i++){
            DoppiCore.DualAssetPosition memory pos = doppiCore.get_buy(address(traderBot), keyPositions[i].positionId);
            assertEq(pos.isTraded, false);
        }
        // ***** END 
        // ***** START perform opportunityBot.checkUpkeep to unwind opportunity trades
        _doppiOpportunityCheckUpkeep_performUpkeep(99_500 * 1e8); 
        keyPositions = doppiCore.get_sell_positions_id(address(traderBot));
        for(uint8 i=0; i< keyPositions.length; i++){
            DoppiCore.DualAssetPosition memory pos = doppiCore.get_sell(address(traderBot), keyPositions[i].positionId);
            assertEq(pos.isTraded, false);
        
        }
        // ***** END 

        // ***** doppiCore settle buy and sell order
        _doppiCoreCheckUpkeep_performUpkeep(105_500 * 1e8);    
        assertEq(doppiCore.getBuyPositionCount(), 0); 
        assertEq(doppiCore.getSellPositionCount(), 0);
        // ***** END  
        
    }

    // internal
    function _start() internal {

        console.log("start");
        vm.startPrank(trader);
        uint256 amountUSDT = 100_000 ether;
        uint256 amountBTC = 1 ether;
        usdt.approve(address(traderBot), 10_000_000 ether);
        btc.approve(address(traderBot), 100 ether);
        traderBot.start(amountUSDT, amountBTC);
        vm.stopPrank();
    }

    function _setupTraderBot() internal returns (DoppiTrader _traderbot) {
        
        vm.prank(trader);
        uint24[] memory weights = new uint24[](5);
        weights[0] = 500;
        weights[1] = 1000;
        weights[2] = 1500;
        weights[3] = 2500;
        weights[4] = 4500;

        uint256 id = doppiFactory.deployTraderBot(weights);
        vm.stopPrank();
        _traderbot = doppiFactory.traderBots(id);
        vm.prank(trader);
        _traderbot.setForwarderAddress(mockForwarder);
        vm.stopPrank();
    }
    

    function _setupLP(address _assetA, address _assetB) internal returns (DoppiLiquidity _doppiLP) {
        _doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(_assetA), IERC20(_assetB));
        _doppiLP.setDoppiConfig(doppiConfig); 
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
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
        vm.prank(mockForwarder);
        opportunityBot.performUpkeep(performData);
    }
    
      


}
