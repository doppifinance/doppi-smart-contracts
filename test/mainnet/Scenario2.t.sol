// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/Interface/IAutomationRegistrar.sol";
import "../../src/Interface/IAutomationRegistryConsumer.sol";
import {IBlackScholes} from "../../src/Interface/IBlackScholes.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
import {DoppiTrader} from "../../src/mainnet/DoppiTrader.sol";
import {DoppiCore} from "../../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../../src/mainnet/DoppiLiquidityRouter.sol";
import {BlackScholes} from "../../src/mainnet/BlackScholes.sol";
import {DoppiOffer} from "../../src/mainnet/DoppiOffer.sol";
import {DoppiPoints} from "../../src/mainnet/DoppiPoints.sol";
import {DoppiClaim} from "../../src/mainnet/DoppiClaim.sol";
import {DOPPI} from "../../src/test/Doppi.sol";
import {DoppiOpportunity} from "../../src/mainnet/DoppiOpportunity.sol";
import {DoppiConfig} from "../../src/mainnet/DoppiConfig.sol";
import {DoppiUpkeepManager} from "../../src/mainnet/DoppiUpkeepManager.sol";
import {MockRegistryConsumer} from "../../src/test/MockRegistryConsumer.sol";
import {DoppiReferral} from "../../src/mainnet/DoppiReferral.sol";



contract Scenario2Test is Test {
    DoppiTraderFactory doppiFactory;
    // DoppiTrader doppiTrader;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    BlackScholes blackScholes;
    DoppiOffer impliedVol;
    IERC20 usdt;
    IERC20 btc;
    IERC20 link;
    // MockOracle oracle;
    // MockDoppiUpKeepManager mockDoppiUpKeepManager;
    DoppiOpportunity doppiOpportunity;
    // Swapper public swapper;
    DoppiConfig doppiConfig;
    DoppiPoints doppiPoints;
    DoppiUpkeepManager doppiUpkeepManager;
    DoppiReferral doppiReferral;
    DOPPI doppiToken;
    DoppiClaim doppiClaim;
    
    // Mainnet addresses for forking
    address constant LINK = address(0x404460C6A5EdE2D891e8297795264fDe62ADBB75);
    address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
    address constant BTC = address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    address constant BNBLINK = address(0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD);
    address constant CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
    address constant CHAINLINK_LINK_USD = address(0xca236E327F629f9Fc2c30A4E95775EbF0B89fac8);
    address constant LINK_PEGGED_SWAP = address(0x1FCc3B22955e76Ca48bF025f1A6993685975Bb9e);
    address constant PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    address constant PCSWAP_V3_QUOTER = address(0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997);
    address constant PCSWAP_V3Pool = address(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);
    address constant CHAINLINK_RegistryConsumer = address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C);
    address constant CHAINLINK_Registrar = address(0xf671F60bCC964B309D22424886FF202807381B32);
    address constant treasury = address(0xaD8234bC07168d9f7E49c3780e4b5fefa6620f8A);
    address constant admin = address(0xaD8234bC07168d9f7E49c3780e4b5fefa6620f8A);
    address constant forwarder = address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
    
    address owner = makeAddr("owner");
    // address treasury = makeAddr("treasury");
    // address admin = makeAddr("admin");
    // address forwarder = makeAddr("forwarder");
    address trader = makeAddr("trader");
    address trader2 = makeAddr("trader2");
    address liquidityProvider = makeAddr("liquidityProvider");
    
    uint24[] defaultWeights = [2000, 2000, 2000, 2000, 2000]; // Equal weights

    function setUp() public {
        
        // Fork Mainnet at a specific block
        uint256 mainnetFork = vm.createFork("mainnet", 68217868); // Do not change the block number for the unit test
        vm.selectFork(mainnetFork);
        
        // Start prank as owner
        vm.startPrank(owner);
        
        usdt = IERC20(USDT);
        btc = IERC20(BTC);
        link = IERC20(LINK);
        
        blackScholes = _deployBlackScholes();
        impliedVol = _deployDoppiOffer(address(blackScholes));
        doppiPoints = _deployDoppiPoints();
        doppiConfig = _deployDoppiConfig(address(doppiPoints));
        doppiConfig.setDoppiOffer(address(impliedVol)); 
        doppiLP = _deployDoppiLiquidity(doppiConfig);
        doppiCore = _deployDoppiCore(doppiLP, impliedVol, doppiPoints);
        doppiOpportunity = _deployDoppiOpportunity(address(doppiCore), address(doppiLP), doppiConfig);
        doppiReferral = _deployDoppiReferral(address(doppiPoints));
    
        console.log("Deploying DoppiLiquidityRouter...");
        DoppiLiquidityRouter doppiRouter = new DoppiLiquidityRouter(IERC20(USDT), IERC20(BTC), doppiLP);
        console.log("DoppiLiquidityRouter deployed at:", address(doppiRouter));
        
        console.log("Deploying DoppiTraderFactory...");
        doppiFactory = new DoppiTraderFactory(IERC20(USDT), IERC20(BTC), address(doppiCore), address(doppiLP), address(doppiRouter));
        console.log("DoppiTraderFactory deployed at:", address(doppiFactory));
        
        doppiUpkeepManager = _deployDoppiUpkeepManager(doppiConfig, address(doppiFactory));
        
        doppiToken = new DOPPI("Doppi Token", "DOPPI");
        doppiClaim = _deployDoppiClaim(doppiPoints, doppiReferral, doppiToken);
        
        _setDoppiLiquidityProperties(doppiLP, address(doppiCore), doppiRouter, address(doppiFactory));

        _setDoppiCoreProperties(doppiCore, doppiFactory, address(doppiOpportunity));

        doppiPoints.setDoppiTraderFactory(address(doppiFactory));
        
        _setupIV(blackScholes, impliedVol, doppiConfig);
        
        // Log deployment addresses for easy access
        console.log("\n=== Deployment Summary ===");
        console.log("BlackScholes:", address(blackScholes));
        console.log("DoppiOffer:", address(impliedVol));
        console.log("DoppiPoints:", address(doppiPoints));
        console.log("DoppiConfig:", address(doppiConfig));
        console.log("DoppiLiquidity:", address(doppiLP));
        console.log("DoppiCore:", address(doppiCore));
        console.log("DoppiOpportunity:", address(doppiOpportunity));
        console.log("DoppiLiquidityRouter:", address(doppiRouter));
        console.log("DoppiTraderFactory:", address(doppiFactory));
        console.log("DoppiUpkeepManager:", address(doppiUpkeepManager));
        console.log("DoppiReferral:", address(doppiReferral));
        console.log("DoppiClaim:", address(doppiClaim));

        vm.stopPrank();
    }

    function test_Scenario2_TraderBotLifecycle() public {
        
        vm.startPrank(trader);
        deal(BTC, address(trader), 1 ether);
        deal(USDT, address(trader), 100_000 ether);
        deal(LINK, address(0x719474EC3C3587F47C81424c9c73F785aec3f1A0), 10_000 ether); //mockRegistryConsumer

        // Deploy bot
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));

        // Setup Automation First time
        // vm.warp(1763164397);
        usdt.approve(address(doppiUpkeepManager), 100000 ether);
        uint256 upkeepId = _setupAutomation(traderBot);

        // Verify active
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0);
        vm.stopPrank();

        // Cancel Automation
        vm.startPrank(trader);
        uint256 balLINK = link.balanceOf(trader);
        assertEq(balLINK, 0);
        doppiUpkeepManager.cancelUpkeep(upkeepId);
        vm.roll(block.number + 51);
        doppiUpkeepManager.stopWithdraw(upkeepId);
        balLINK = link.balanceOf(trader);
        assertGt(balLINK, 0);
        vm.stopPrank();

        // // settle core
        // _doppiCoreCheckUpkeep_performUpkeep();

        // stop and withdraw fund 
        vm.startPrank(trader);
        traderBot.setPause();
        // traderBot.stop();
        vm.stopPrank();

        vm.startPrank(owner);
        _setupIV(blackScholes, impliedVol, doppiConfig);
        vm.stopPrank();

        // setup again new automation
        vm.startPrank(trader);
        _setupAutomation(traderBot);
        vm.stopPrank();

    }

    function _setupAutomation(DoppiTrader traderBot) internal returns (uint256 upkeepId) {
        // Setup Automation
        upkeepId = doppiUpkeepManager.setupAutomation(address(traderBot));

        // Setup forwarder address
        address forwarder_ = doppiUpkeepManager.getForwarder(upkeepId);
        traderBot.setForwarderAddress(forwarder_);

        // Fund and start
        usdt.approve(address(traderBot), 10000 ether);
        btc.approve(address(traderBot), 0.2 ether);
        traderBot.start(10000 ether, 0.1 ether);
        
    }

    function _setDoppiCoreProperties(
        DoppiCore _doppiCore, 
        DoppiTraderFactory _doppiFactory,
        address _doppiOpportunity
        ) internal {
        
        console.log("Setting DoppiCore Properties...");
        _doppiCore.setForwarderAddress(forwarder);
        _doppiCore.setOpportunityBot(_doppiOpportunity, true);
        _doppiCore.setDoppiTraderFactory(_doppiFactory);
        _doppiCore.setAPRTolerance(300);
    }

    function _setDoppiLiquidityProperties(
        DoppiLiquidity _doppiLP, 
        address _doppiCore, 
        DoppiLiquidityRouter _doppiRouter,
        address _doppiFactory
        ) internal {
        
        console.log("Setting DoppiLiquidity Properties...");
        // _doppiLP.setForwarderAddress(forwarder);
        _doppiLP.setDoppiCore(_doppiCore);
        _doppiLP.setEntryPoint(address(_doppiRouter.entryPointA()), true);
        _doppiLP.setEntryPoint(address(_doppiRouter.entryPointB()), true);
        _doppiLP.approveEntryPoint(address(_doppiRouter.entryPointA()), USDT);
        _doppiLP.approveEntryPoint(address(_doppiRouter.entryPointB()), BTC);
        _doppiLP.setDoppiTraderFactory(_doppiFactory);
        // doppiCore.setDoppiTraderFactory(doppiFactory);
    }

    function _deployDoppiCore(DoppiLiquidity _doppiLP, DoppiOffer _impliedVol, DoppiPoints _doppiPoints) internal returns (DoppiCore) {
        
        console.log("Deploying DoppiCore...");
        DoppiCore doppiCore = new DoppiCore(USDT, BTC, _doppiLP, _impliedVol);
        console.log("DoppiCore deployed at:", address(doppiCore));
        _doppiPoints.setDoppiCore(address(doppiCore), true);
        return doppiCore;
    }
        
        
    function _deployDoppiOpportunity(address _doppiCore, address _doppiLP, DoppiConfig doppiConfig) internal returns (DoppiOpportunity) {
    
        console.log("Deploying DoppiOpportunity...");
        DoppiOpportunity doppiOpportunity = new DoppiOpportunity(_doppiCore, _doppiLP);
        console.log("DoppiOpportunity deployed at:", address(doppiOpportunity));
        // doppiOpportunity.setForwarderAddress(forwarder);
        doppiOpportunity.setDoppiConfig(doppiConfig);
        return doppiOpportunity;
    }

    function _deployDoppiLiquidity(DoppiConfig _doppiConfig) internal returns (DoppiLiquidity) {
        
        console.log("Deploying DoppiLiquidity...");
        DoppiLiquidity _doppiLP = new DoppiLiquidity("Doppi BTC-USDT LP", "BTCB-USDT", IERC20(USDT), IERC20(BTC));
        console.log("DoppiLiquidity deployed at:", address(_doppiLP));
        _doppiLP.setDoppiConfig(_doppiConfig); 
        _doppiLP.approveRouter();
        return _doppiLP;
    }

    function _deployBlackScholes() internal returns (BlackScholes) {
        
        console.log("Deploying BlackScholes...");
        BlackScholes blackScholes = new BlackScholes();
        console.log("BlackScholes deployed at:", address(blackScholes));
        return blackScholes;
    }

    function _deployDoppiClaim(DoppiPoints _doppiPoints, DoppiReferral _doppiReferral, DOPPI _doppiToken) internal returns (DoppiClaim) {
        console.log("Deploying DoppiClaim...");
        DoppiClaim doppiClaim = new DoppiClaim(
            address(_doppiToken),
            address(_doppiPoints),
            address(_doppiReferral),
            1 // 1 token per point
        );
        _doppiPoints.setDoppiClaim(address(doppiClaim));
        _doppiReferral.setDoppiClaim(address(doppiClaim));
        _doppiToken.addMinter(address(doppiClaim));
        console.log("DoppiClaim deployed at:", address(doppiClaim));
        return doppiClaim;
    }

    function _deployDoppiReferral(address _doppiPoints) internal returns (DoppiReferral) {
        console.log("Deploying DoppiReferral...");
        DoppiReferral doppiReferral = new DoppiReferral(_doppiPoints, 150, 100, 50);
        console.log("DoppiReferral deployed at:", address(doppiReferral));
        doppiReferral.setMinVolumeForL2(1_000 ether, 2_000 ether);
        return doppiReferral;
    }

    function _deployDoppiOffer(address _blackScholes) internal returns (DoppiOffer) {
        
        console.log("Deploying DoppiOffer...");
        DoppiOffer impliedVol = new DoppiOffer(IBlackScholes(_blackScholes), CHAINLINK_BTC_USD, 500);
        console.log("DoppiOffer deployed at:", address(impliedVol));
        impliedVol.setTwapDuration(3600);
        impliedVol.setPancakeV3Pool(PCSWAP_V3Pool);
        return impliedVol;
    }

    function _deployDoppiPoints() internal returns (DoppiPoints) {
        console.log("Deploying DoppiPoints...");
        DoppiPoints doppiPoints = new DoppiPoints();
        console.log("DoppiPoints deployed at:", address(doppiPoints));
        return doppiPoints;
    }

    function _deployDoppiConfig(address _doppiPoints) internal returns (DoppiConfig) {
        
        console.log("Deploying DoppiConfig...");
        DoppiConfig doppiConfig = new DoppiConfig();
        console.log("DoppiConfig deployed at:", address(doppiConfig));
        doppiConfig.setRouter(PCSWAP_V3_ROUTER);
        doppiConfig.setQuoter(PCSWAP_V3_QUOTER);
        doppiConfig.setTreasury(treasury);
        doppiConfig.setPancakeV3Pool(PCSWAP_V3Pool); 
        doppiConfig.setOracle(CHAINLINK_BTC_USD);
        doppiConfig.setSlippage(500);
        doppiConfig.setMaxDepositPercentage(20000); // if pool is 10000, allow up to 2x deposit
        // doppiConfig.setDoppiUpKeepManager(address(mockDoppiUpKeepManager));
        doppiConfig.setDoppiPoints(_doppiPoints); 

        return doppiConfig;
    }

    function _deployDoppiUpkeepManager(DoppiConfig _doppiConfig, address _doppiFactory) internal returns (DoppiUpkeepManager) {

        console.log("Deploying DoppiUpkeepManager...");
        IAutomationRegistrar registrar = IAutomationRegistrar(CHAINLINK_Registrar);
        // IAutomationRegistryConsumer registryConsumer = IAutomationRegistryConsumer(CHAINLINK_RegistryConsumer);
        MockRegistryConsumer mockRegistryConsumer = new MockRegistryConsumer();

        DoppiUpkeepManager doppiUpkeepManager = new DoppiUpkeepManager(
            address(mockRegistryConsumer), 
            address(registrar), 
            CHAINLINK_LINK_USD, 
            address(PCSWAP_V3_ROUTER),
            LINK_PEGGED_SWAP,
            USDT, 
            LINK, // erc677 link
            BNBLINK, //bnb link
            _doppiFactory,
            treasury
        );
        
        console.log("mockRegistryConsumer deployed at:", address(mockRegistryConsumer));
        console.log("DoppiUpkeepManager deployed at:", address(doppiUpkeepManager));
        _doppiConfig.setDoppiUpKeepManager(address(doppiUpkeepManager));
        doppiUpkeepManager.setMaxDelay(10 days);
        return doppiUpkeepManager;
    }  

    function _doppiCoreCheckUpkeep_performUpkeep() internal {

        vm.warp(block.timestamp + 1 days + 1);
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(forwarder);
        doppiCore.performUpkeep(performData);  
        vm.stopPrank();
    }

    function _setupIV(BlackScholes blackScholes, DoppiOffer _impliedVol, DoppiConfig doppiConfig) internal {
        
        // vm.warp(vm.getBlockTimestamp() + 30 days); 
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;
        _impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
        _impliedVol.setTwapDuration(3600);
        _impliedVol.setPancakeV3Pool(PCSWAP_V3Pool);
        doppiConfig.setDoppiOffer(address(_impliedVol)); 
    }

    // function _manipulateRealChainlink(int256 newPrice, address _oracle) internal {
        
    //     // Then override the feed address
    //     vm.prank(doppiConfig.owner());
    //     doppiConfig.setOracle(_oracle);
    //     MockOracle(_oracle).setPrice(newPrice);
    //     vm.stopPrank();
    // }
}
