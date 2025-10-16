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
import {IImpliedVol} from "../../src/Interface/IImpliedVol.sol";
import {DoppiPoints} from "../../src/mainnet/DoppiPoints.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../../src/test/MockToken.sol";
import {MockOracle} from "../../src/test/MockOracle.sol";
import {MockDoppiUpKeepManager} from "../../src/test/MockDoppiUpkeepManager.sol";
import {DoppiOpportunity} from "../../src/mainnet/DoppiOpportunity.sol";
import {Swapper} from "../../src/test/Swapper.sol";
import {DoppiConfig} from "../../src/mainnet/DoppiConfig.sol";
import "../../src/mainnet/DoppiCoreTypes.sol";

contract BasicFlowTest is Test {
    DoppiTraderFactory doppiFactory;
    // DoppiTrader doppiTrader;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    // BlackScholes blackScholes;
    ImpliedVol impliedVol;
    IERC20 usdt;
    IERC20 btc;
    MockOracle oracle;
    MockDoppiUpKeepManager mockDoppiUpKeepManager;
    DoppiOpportunity doppiOpportunity;
    Swapper public swapper;
    DoppiConfig doppiConfig;
    DoppiPoints doppiPoints;

    
    // Mainnet addresses for forking
    address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
    address constant BTCB = address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    address constant CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
    address constant PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    address constant PCSWAP_V3_QUOTER = address(0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997);

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address admin = makeAddr("admin");
    address forwarder = makeAddr("forwarder");
    address trader = makeAddr("trader");
    address trader2 = makeAddr("trader2");
    address liquidityProvider = makeAddr("liquidityProvider");
    
    uint24[] defaultWeights = [2000, 2000, 2000, 2000, 2000]; // Equal weights

    function setUp() public {
        
        // Fork Mainnet at a specific block
        uint256 mainnetFork = vm.createFork("mainnet", 60905002); // Do not change the block number for the unit test
        vm.selectFork(mainnetFork);
        
        // Start prank as owner
        vm.startPrank(owner);
        oracle = new MockOracle(int256(100_000 * 1e8), 8);
        mockDoppiUpKeepManager = new MockDoppiUpKeepManager(forwarder);

        usdt = IERC20(USDT);
        btc = IERC20(BTCB);
        doppiPoints = new DoppiPoints();
        doppiConfig = new DoppiConfig();
        doppiConfig.setRouter(PCSWAP_V3_ROUTER);
        doppiConfig.setQuoter(PCSWAP_V3_QUOTER);
        doppiConfig.setTreasury(treasury);
        doppiConfig.setPancakeV3Pool(PCSWAP_V3_ROUTER); 
        doppiConfig.setOracle(CHAINLINK_BTC_USD);
        doppiConfig.setSlippage(500);
        doppiConfig.setDoppiUpKeepManager(address(mockDoppiUpKeepManager));
        doppiConfig.setDoppiPoints(address(doppiPoints)); 
        
        impliedVol = _setupIV();
        doppiLP = _setupLP(address(usdt), address(btc));

        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);
        doppiOpportunity = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiFactory = new DoppiTraderFactory(IERC20(usdt), IERC20(btc), address(doppiCore), address(doppiLP), address(doppiRouter));

        doppiPoints.setDoppiCore(address(doppiCore));
        doppiOpportunity.setForwarderAddress(forwarder);
        doppiOpportunity.setDoppiConfig(doppiConfig);
        doppiCore.setForwarderAddress(forwarder);
        doppiCore.setAdmin(address(doppiOpportunity), true);
        doppiLP.setForwarderAddress(forwarder);
        doppiLP.setDoppiCore(address(doppiCore));
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));
        doppiLP.setDoppiTraderFactory(address(doppiFactory));
        doppiCore.setDoppiTraderFactory(doppiFactory);
        
        vm.stopPrank();
    }

    function testForkDeployment() public view {
        assertEq(doppiLP.owner(), owner);
        assertEq(address(doppiLP.assetA()), USDT);
        assertEq(address(doppiLP.assetB()), BTCB);
        assertEq(address(doppiLP.getDoppiConfig()), address(doppiConfig));
        
        assertEq(address(doppiCore.assetA()), address(usdt));
        assertEq(address(doppiCore.assetB()), address(btc));
        assertEq(address(doppiCore.doppiLP()), address(doppiLP));
        assertEq(address(doppiCore.impliedVol()), address(impliedVol));
        assertEq(doppiCore.owner(), owner);
        assertTrue(doppiCore.admins(owner));

        assertEq(doppiOpportunity.owner(), owner);
        assertEq(address(doppiOpportunity.doppiLP()), address(doppiLP));
        assertEq(address(doppiOpportunity.doppiCore()), address(doppiCore));

        assertEq(address(doppiRouter.doppiLP()), address(doppiLP));
        assertEq(doppiRouter.assetA(), address(usdt));
        assertEq(doppiRouter.assetB(), address(btc));
        assertTrue(address(doppiRouter.entryPointA()) != address(0));
        assertTrue(address(doppiRouter.entryPointB()) != address(0));
    }
    
    function testPriceFeed() public view {
        uint256 price = doppiLP.getPrice();
        console.log("BTC Price from Chainlink:", price);
        assertGt(price, 0);
    }

    function test_Scenario1_CompleteProtocolFlow() public {
        // Phase 1: Liquidity Provision
        vm.startPrank(liquidityProvider);
        deal(BTCB, address(liquidityProvider), 1 ether);
        deal(USDT, address(liquidityProvider), 100_000 ether);

        usdt.approve(address(doppiRouter), 100_000 ether);
        btc.approve(address(doppiRouter), 1 ether);
        
        uint256 sharesA = doppiRouter.deposit(address(usdt), 50000 ether);
        uint256 sharesB = doppiRouter.deposit(address(btc), 0.5 ether);

        assertTrue(sharesA > 0);
        assertTrue(sharesB > 0);
        vm.stopPrank();

        // Phase 2: Trader Bot Creation
        vm.startPrank(trader);
        uint256 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        assertTrue(doppiFactory.isTraderBot(address(traderBot)));
        vm.stopPrank();

        // Phase 3: Trader Bot Funding and Trading
        vm.startPrank(trader);
        deal(BTCB, address(trader), 1 ether);
        deal(USDT, address(trader), 100_000 ether);        
        usdt.approve(address(traderBot), 100_000 ether);
        btc.approve(address(traderBot), 1 ether);
        traderBot.start(100_000 ether, 1 ether);
        vm.stopPrank();

        // Phase 4: User Interaction with doppiCore
        vm.startPrank(trader2);
        deal(USDT, address(trader2), 100_000 ether);        
        usdt.approve(address(doppiCore), 5000 ether);
        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 0);
        doppiCore.deposit_buy(DepositParams({
            amount: 5000 ether,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            validityTime: buyOffer.validUntilTimestamp
        }));
        vm.stopPrank();

        // Verify state changes
        assertTrue(doppiCore.getBuyPositionCount(trader2) > 0);
    }

    // SCENARIO 4: Trader Bot Lifecycle
    function test_Scenario4_TraderBotLifecycle() public {
        
        vm.startPrank(trader);
        deal(BTCB, address(trader), 1 ether);
        deal(USDT, address(trader), 100_000 ether);

        // Deploy bot
        uint256 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        // Fund and start
        usdt.approve(address(traderBot), 10000 ether);
        btc.approve(address(traderBot), 0.2 ether);
        traderBot.start(10000 ether, 0.2 ether);
        
        // Verify active
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0);
        vm.stopPrank();
        
        
        // Price Down 2%
        uint256 currentPrice = doppiLP.getPrice();
        int256 newPrice = int256(currentPrice * 9900 / 10000);
        _manipulateRealChainlink(newPrice, address(oracle));
        
        _doppiCoreCheckUpkeep_performUpkeep();     
        
        // stop trader bot
        vm.startPrank(trader);
        traderBot.setPause();
        traderBot.stop();

        // Verify stopped and funds returned
        uint256 finalBalanceA = usdt.balanceOf(trader);
        uint256 finalBalanceB = btc.balanceOf(trader);
        assertTrue(finalBalanceA > 0);
        assertTrue(finalBalanceB > 0);
        assertEq(doppiCore.getBuyPositionCount(address(traderBot)), 0);
        
    }

    function test_Scenario5_traderbot_one_sided_asset() public {
        
        vm.startPrank(trader);
        deal(USDT, address(trader), 100_000 ether);
        // Deploy bot
        uint256 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        // Fund and start
        usdt.approve(address(traderBot), 100_000 ether);
        traderBot.start(100_000 ether, 0);
        
        // Verify active
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0);
        vm.stopPrank();
        
        
        // Price Down 2%
        uint256 currentPrice = doppiLP.getPrice();
        int256 newPrice = int256(currentPrice * 9800 / 10000);
        _manipulateRealChainlink(newPrice, address(oracle));
        
        _doppiCoreCheckUpkeep_performUpkeep();     

        // stop trader bot
        vm.startPrank(trader);
        traderBot.setPause();
        traderBot.stop();

        // Verify stopped and funds returned
        uint256 finalBalanceA = usdt.balanceOf(trader);
        console.log(finalBalanceA);
        assertTrue(finalBalanceA > 0);
        assertEq(doppiCore.getBuyPositionCount(address(traderBot)), 0);
        
        vm.stopPrank();

        // ***** END 
    }

    // SCENARIO 6: Trader Bot Lifecycle
    function test_Scenario4_TraderBotLifecycle_Pagination() public {
        
        vm.startPrank(trader);
        deal(BTCB, address(trader), 1 ether);
        deal(USDT, address(trader), 100_000 ether);

        // Deploy bot
        uint256 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        // Fund and start
        usdt.approve(address(traderBot), 100000 ether);
        btc.approve(address(traderBot), 2 ether);
        traderBot.start(10000 ether, 0.2 ether);
        
        // Verify active
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0);
        vm.stopPrank();
        
        
        // Price Down 2%
        uint256 currentPrice = doppiLP.getPrice();
        int256 newPrice = int256(currentPrice * 9900 / 10000);
        _manipulateRealChainlink(newPrice, address(oracle));
        
        vm.prank(owner);
        doppiCore.setUpkeeps_per_check(2);
        vm.stopPrank();

        // initial start with 5
        assertEq(doppiCore.getBuyPositionCount(address(traderBot)), 5);
        assertEq(doppiCore.getSellPositionCount(address(traderBot)), 5);
  
        _doppiCoreCheckUpkeep_performUpkeep();     
        
        // processed 2. remaining 3
        assertEq(doppiCore.getBuyPositionCount(address(traderBot)), 3);
        assertEq(doppiCore.getSellPositionCount(address(traderBot)), 3);
  
        // Price Down 2%
        currentPrice = doppiLP.getPrice();
        newPrice = int256(currentPrice * 9800 / 10000);
        _manipulateRealChainlink(newPrice, address(oracle));
        
        _doppiCoreCheckUpkeep_performUpkeep();     
        
        // processed 2. remaining 1
        assertEq(doppiCore.getBuyPositionCount(address(traderBot)), 1);
        assertEq(doppiCore.getSellPositionCount(address(traderBot)), 1);
  
        _doppiCoreCheckUpkeep_performUpkeep();     
        
        // processed remaining
        assertEq(doppiCore.getBuyPositionCount(address(traderBot)), 0);
        assertEq(doppiCore.getSellPositionCount(address(traderBot)), 0);
  
    }

    

    function _setupLP(address _assetA, address _assetB) internal returns (DoppiLiquidity _doppiLP) {
        _doppiLP =
            new DoppiLiquidity("Doppi BTC-USDT LP", "BTCB-USDT", IERC20(_assetA), IERC20(_assetB));
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
        _impliedVol = new ImpliedVol(blackScholes, address(doppiConfig.chainLinkFeed()), 500);
        _impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
        doppiConfig.setImpliedVol(address(_impliedVol)); 
    }

    function _doppiCoreCheckUpkeep_performUpkeep() internal {

        vm.warp(block.timestamp + 1 days + 1);
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(forwarder);
        doppiCore.performUpkeep(performData);  
        vm.stopPrank();
    }

    function _manipulateRealChainlink(int256 newPrice, address _oracle) internal {
        
        // Then override the feed address
        vm.prank(doppiConfig.owner());
        doppiConfig.setOracle(_oracle);
        MockOracle(_oracle).setPrice(newPrice);
        vm.stopPrank();
    }
}
