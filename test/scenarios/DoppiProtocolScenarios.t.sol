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


contract DoppiProtocolScenariosTest is Test {
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
    DoppiConfig doppiConfig;
    
    // Addresses
    address public owner = address(0x1);
    address public liquidityProvider = address(0x2);
    address public trader1 = address(0x3);
    address public trader2 = address(0x4);
    address public user = address(0x5);
    address treasury = address(0x6);
    address mockForwarder = address(0x7);
    

    // Test parameters
    uint24[] defaultWeights = [2000, 2000, 2000, 2000, 2000]; // Equal weights

    function setUp() public {
        vm.startPrank(owner);
        
        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(int256(100_000 ether), 18);

        swapper = _setupMockSwapper(address(usdt), address(btc), address(oracle));        
        
        doppiConfig = new DoppiConfig();
        doppiConfig.setRouter(address(swapper));
        doppiConfig.setQuoter(address(swapper));
        doppiConfig.setTreasury(treasury);
        doppiConfig.setPancakeV3Pool(address(swapper)); 
        doppiConfig.setOracle(address(oracle));
        
        impliedVol = _setupIV();
        doppiLP = _setupLP(address(usdt), address(btc), address(oracle), address(swapper));
        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);
        opportunityBot = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiFactory = new DoppiTraderFactory(IERC20(usdt), IERC20(btc), doppiCore, doppiLP, doppiRouter, mockForwarder);

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
        
        // Distribute initial tokens
        usdt.mint(liquidityProvider, 10000 * 10 ** usdt.decimals());
        btc.mint(liquidityProvider, 20 * 10 ** btc.decimals());
        usdt.mint(trader1, 5000 * 10 ** usdt.decimals());
        btc.mint(trader1, 10 * 10 ** btc.decimals());
        usdt.mint(trader2, 3000 * 10 ** usdt.decimals());
        btc.mint(trader2, 5 * 10 ** btc.decimals());
        usdt.mint(user, 1000 * 10 ** usdt.decimals());
        btc.mint(user, 2 * 10 ** btc.decimals());
        
        vm.stopPrank();
    }

    // SCENARIO 1: Complete Protocol Flow
    function test_Scenario1_CompleteProtocolFlow() public {
        // Phase 1: Liquidity Provision
        vm.startPrank(liquidityProvider);
        usdt.approve(address(doppiRouter), 5000 * 10 ** usdt.decimals());
        btc.approve(address(doppiRouter), 10 * 10 ** btc.decimals());
        
        uint256 sharesA = doppiRouter.deposit(address(usdt), 5000 * 10 ** usdt.decimals());
        uint256 sharesB = doppiRouter.deposit(address(btc), 10 * 10 ** btc.decimals());
        
        assertTrue(sharesA > 0);
        assertTrue(sharesB > 0);
        vm.stopPrank();

        // Phase 2: Trader Bot Creation
        vm.startPrank(trader1);
        uint256 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = doppiFactory.traderBots(traderId);
        
        assertTrue(doppiFactory.isTraderBot(address(traderBot)));
        vm.stopPrank();

        // Phase 3: Trader Bot Funding and Trading
        vm.startPrank(trader1);
        usdt.mint(address(traderBot), 1000 * 10 ** usdt.decimals());
        btc.mint(address(traderBot), 2 * 10 ** btc.decimals());
        usdt.approve(address(traderBot), 1000 * 10 ** usdt.decimals());
        btc.approve(address(traderBot), 2 * 10 ** btc.decimals());
        traderBot.start(1000 * 10 ** usdt.decimals(), 2 * 10 ** btc.decimals());
        vm.stopPrank();

        // Phase 4: User Interaction with doppiCore
        vm.startPrank(user);
        usdt.approve(address(doppiCore), 500 * 10 ** usdt.decimals());
        
        // Get offers and deposit
        (DoppiCore.DualAssetOffer[] memory buyOffers, ) = doppiCore.getAllOffers(1);
        doppiCore.deposit_buy(DoppiCore.DepositParams({
            amount: 500 * 10 ** usdt.decimals(),
            strikeZone: 0,
            strikePrice: buyOffers[0].strikePrice,
            numDays: 1,
            apr: buyOffers[0].apr,
            validityTime: buyOffers[0].validUntilTimestamp
        }));
        vm.stopPrank();

        // Verify state changes
        assertTrue(doppiCore.getBuyPositionCount(user) > 0);
    }

    // SCENARIO 2: Multiple Traders Competition
    function test_Scenario2_MultipleTradersCompetition() public {
        // Setup liquidity
        vm.startPrank(liquidityProvider);
        usdt.approve(address(doppiRouter), 8000 * 10 ** usdt.decimals());
        btc.approve(address(doppiRouter), 15 * 10 ** btc.decimals());
        doppiRouter.deposit(address(usdt), 8000 * 10 ** usdt.decimals());
        doppiRouter.deposit(address(btc), 15 * 10 ** btc.decimals());
        vm.stopPrank();

        // Trader 1 creates bot
        vm.startPrank(trader1);
        uint256 trader1Id = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader trader1Bot = doppiFactory.traderBots(trader1Id);
        usdt.mint(address(trader1Bot), 2000 * 10 ** usdt.decimals());
        btc.mint(address(trader1Bot), 4 * 10 ** btc.decimals());
        usdt.approve(address(trader1Bot), 2000 * 10 ** usdt.decimals());
        btc.approve(address(trader1Bot), 4 * 10 ** btc.decimals());
        trader1Bot.start(2000 * 10 ** usdt.decimals(), 4 * 10 ** btc.decimals());
        vm.stopPrank();

        // Trader 2 creates bot with different strategy
        vm.startPrank(trader2);
        uint24[] memory aggressiveWeights = new uint24[](4);
        aggressiveWeights[0] = 4000;
        aggressiveWeights[1] = 3000;
        aggressiveWeights[2] = 2000;
        aggressiveWeights[3] = 1000;
        // aggressiveWeights[4] = 0;
        uint256 trader2Id = doppiFactory.deployTraderBot(aggressiveWeights);
        DoppiTrader trader2Bot = doppiFactory.traderBots(trader2Id);
        usdt.mint(address(trader2Bot), 1500 * 10 ** usdt.decimals());
        btc.mint(address(trader2Bot), 3 * 10 ** btc.decimals());
        usdt.approve(address(trader2Bot), 1500 * 10 ** usdt.decimals());
        btc.approve(address(trader2Bot), 3 * 10 ** btc.decimals());
        trader2Bot.start(1500 * 10 ** usdt.decimals(), 3 * 10 ** btc.decimals());
        vm.stopPrank();

        // Verify both traders are active
        assertTrue(doppiFactory.isTraderBot(address(trader1Bot)));
        assertTrue(doppiFactory.isTraderBot(address(trader2Bot)));
        
        // Check that both traders have positions
        assertTrue(doppiCore.getBuyPositionCount(address(trader1Bot)) > 0);
        assertTrue(doppiCore.getBuyPositionCount(address(trader2Bot)) > 0);
    }

    // SCENARIO 3: Liquidity Stress Test
    function test_Scenario3_LiquidityStressTest() public {
        // Large liquidity provision
        vm.startPrank(liquidityProvider);
        usdt.approve(address(doppiRouter), 8000 * 10 ** usdt.decimals());
        btc.approve(address(doppiRouter), 15 * 10 ** btc.decimals());
        
        uint256 initialLiquidity = doppiLP.totalAssetsInAssetA();
        doppiRouter.deposit(address(usdt), 8000 * 10 ** usdt.decimals());
        doppiRouter.deposit(address(btc), 15 * 10 ** btc.decimals());
        
        uint256 newLiquidity = doppiLP.totalAssetsInAssetA();
        assertTrue(newLiquidity > initialLiquidity);
        vm.stopPrank();

        // Multiple users depositing simultaneously
        address[5] memory users = [
            address(0x10), address(0x11), address(0x12), address(0x13), address(0x14)
        ];

        for (uint8 i = 0; i < users.length; i++) {
            vm.prank(owner);
            usdt.mint(users[i], 200 * 10 ** usdt.decimals());
            
            vm.startPrank(users[i]);
            usdt.approve(address(doppiCore), 200 * 10 ** usdt.decimals());
            
            (DoppiCore.DualAssetOffer[] memory buyOffers, ) = doppiCore.getAllOffers(1);
            doppiCore.deposit_buy(DoppiCore.DepositParams({
                amount: 200 * 10 ** usdt.decimals(),
                strikeZone: i % 5,
                strikePrice: buyOffers[i % 5].strikePrice,
                numDays: 1,
                apr: buyOffers[i % 5].apr,
                validityTime: buyOffers[i % 5].validUntilTimestamp
            }));
            vm.stopPrank();
        }

        // Verify all users have positions
        for (uint256 i = 0; i < users.length; i++) {
            assertTrue(doppiCore.getBuyPositionCount(users[i]) > 0);
        }
    }

    // SCENARIO 4: Trader Bot Lifecycle
    function test_Scenario4_TraderBotLifecycle() public {
        vm.startPrank(trader1);
        
        // Deploy bot
        uint256 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = doppiFactory.traderBots(traderId);
        
        // Fund and start
        usdt.mint(address(traderBot), 1000 * 10 ** usdt.decimals());
        btc.mint(address(traderBot), 2 * 10 ** btc.decimals());
        usdt.approve(address(traderBot), 1000 * 10 ** usdt.decimals());
        btc.approve(address(traderBot), 2 * 10 ** btc.decimals());
        traderBot.start(1000 * 10 ** usdt.decimals(), 2 * 10 ** btc.decimals());
        
        // Verify active
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0);
        
        // pause it
        traderBot.setPause();
        vm.stopPrank();
        // settle it
        _doppiCoreCheckUpkeep_performUpkeep(100_000 ether);     
        
        vm.startPrank(trader1);
        // Stop bot
        traderBot.stop();
        
        // Verify stopped and funds returned
        uint256 finalBalanceA = usdt.balanceOf(trader1);
        uint256 finalBalanceB = btc.balanceOf(trader1);
        assertTrue(finalBalanceA > 0);
        assertTrue(finalBalanceB > 0);
        assertEq(doppiCore.getBuyPositionCount(address(traderBot)), 0);
        
        vm.stopPrank();
    }

    // SCENARIO 5: Price Movement Simulation
    function test_Scenario5_PriceMovementSimulation() public {
        // Setup
        vm.startPrank(liquidityProvider);
        usdt.approve(address(doppiRouter), 5000 * 10 ** usdt.decimals());
        doppiRouter.deposit(address(usdt), 5000 * 10 ** usdt.decimals());
        vm.stopPrank();

        vm.startPrank(trader1);
        uint256 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = doppiFactory.traderBots(traderId);
        usdt.mint(address(traderBot), 1000 * 10 ** usdt.decimals());
        usdt.approve(address(traderBot), 1000 * 10 ** usdt.decimals());
        traderBot.start(1000 * 10 ** usdt.decimals(), 0);
        vm.stopPrank();

        // Simulate price changes and check positions
        // Simulate price drop (should create opportunities)
        // Note: In real scenario, this would be done via oracle manipulation
        // For test, we just verify the contract state changes
        _doppiOpportunityCheckUpkeep_performUpkeep(97_500 ether); 
        DoppiCore.KeyPosition[] memory keyPositions = doppiCore.get_buy_positions_id(address(traderBot));
        DoppiCore.DualAssetPosition memory pos = doppiCore.get_buy(address(traderBot), keyPositions[0].positionId);
        assertEq(pos.isTraded, true);
        pos = doppiCore.get_buy(address(traderBot), keyPositions[1].positionId);
        assertEq(pos.isTraded, true);
        pos = doppiCore.get_buy(address(traderBot), keyPositions[2].positionId);
        assertEq(pos.isTraded, true);
        pos = doppiCore.get_buy(address(traderBot), keyPositions[3].positionId);
        assertEq(pos.isTraded, false);
        pos = doppiCore.get_buy(address(traderBot), keyPositions[4].positionId);
        assertEq(pos.isTraded, false);

    }

    // SCENARIO 6: Emergency Protocol Shutdown
    function test_Scenario6_EmergencyShutdown() public {
        // Setup active protocol
        test_Scenario1_CompleteProtocolFlow();
        
        // Owner pauses everything
        vm.startPrank(owner);
        doppiCore.setPause();
        opportunityBot.setPause();
        doppiRouter.setPause();
        vm.stopPrank();

        // Verify everything is paused
        assertTrue(doppiCore.paused());
        assertTrue(opportunityBot.paused());
        assertTrue(doppiRouter.paused());

        // Try operations - should fail
        vm.startPrank(user);
        usdt.approve(address(doppiCore), 100 * 10 ** usdt.decimals());        
        
        vm.expectRevert();
        doppiCore.deposit_buy(DoppiCore.DepositParams({
            amount: 100 * 1e18,
            strikeZone: 0,
            strikePrice: 100000 * 10 ** 8, // Example strike price
            numDays: 1,
            apr: 500, // Example APR
            validityTime: 17000000 + 3600
        }));
        vm.stopPrank();

        vm.startPrank(liquidityProvider);
        usdt.approve(address(doppiRouter), 5000 ether);
        vm.expectRevert();
        doppiRouter.deposit(address(usdt), 5000 ether);
        vm.stopPrank();

        // Unpause and verify operations work again
        vm.startPrank(owner);
        doppiCore.setUnPause();
        opportunityBot.setUnPause();
        doppiRouter.setUnPause();
        vm.stopPrank();

        assertFalse(doppiCore.paused());
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
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(_assetA), IERC20(_assetB));
        // Set the mock oracle, router, pool, and quoter
        // _doppiLP.setOracle(address(_oracle));
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

    function test_Scenario6_NotAPR_Available() public {
        
        // Phase 2: Trader Bot Creation
        vm.startPrank(trader1);
        uint256 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = doppiFactory.traderBots(traderId);
        traderBot.setDefaultDay(2);
        vm.stopPrank();

        // Phase 3: Trader Bot Funding and Trading
        vm.startPrank(trader1);
        usdt.mint(address(traderBot), 1000 * 10 ** usdt.decimals());
        btc.mint(address(traderBot), 2 * 10 ** btc.decimals());
        usdt.approve(address(traderBot), 1000 * 10 ** usdt.decimals());
        btc.approve(address(traderBot), 2 * 10 ** btc.decimals());
        vm.expectRevert("Zero APR");
        traderBot.start(1000 ether, 2 ether);
        vm.stopPrank();

        
    }
}