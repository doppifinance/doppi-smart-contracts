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
import {DoppiUpkeepManager} from "../../src/mainnet/DoppiUpkeepManager.sol";
import {MockRegistryConsumer} from "../../src/test/MockRegistryConsumer.sol";
import {DoppiReferral} from "../../src/mainnet/DoppiReferral.sol";
import "../../src/mainnet/DoppiCoreTypes.sol";
import {MockOracle} from "../../src/test/MockOracle.sol";
import {TestParamLib} from "../../src/Library/TestParamLib.sol";
import "../../src/mainnet/DoppiLiquidityTypes.sol";
import {PrivateDoppiGridTraderFactory} from "../../src/mainnet/private/PrivateDoppiGridTraderFactory.sol";
import {DoppiGridTrader} from "../../src/mainnet/private/DoppiGridTrader.sol";
import {PrivateAutomationHub} from "../../src/mainnet/private/PrivateAutomationHub.sol";
import {DoppiFeePool} from "../../src/mainnet/DoppiFeePool.sol";
import {BotBillingState, PrivateJobView} from "../../src/mainnet/private/PrivateAutomationHubTypes.sol";

import {IPrivateAutomationHub} from "../../src/Interface/IPrivateAutomationHub.sol";


contract PrivateGridTraderScenarioTest is Test {
    DoppiTraderFactory doppiFactory;
    PrivateDoppiGridTraderFactory privateFactory;
    PrivateAutomationHub privateAutomationHub;
    // DoppiTrader doppiTrader;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    BlackScholes blackScholes;
    DoppiOffer impliedVol;
    IERC20 usdt;
    IERC20 btc;
    IERC20 link;
    MockOracle oracle;
    DoppiOpportunity doppiOpportunity;
    // Swapper public swapper;
    DoppiPoints doppiPoints;
    DoppiReferral doppiReferral;
    DOPPI doppiToken;
    DoppiClaim doppiClaim;
    ConfigParam configLP;
    address mockRegistryConsumerAddr;
    
    // Mainnet addresses for forking
    address constant LINK = address(0x404460C6A5EdE2D891e8297795264fDe62ADBB75);
    address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
    address constant BTC = address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    address constant BNBLINK = address(0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD);
    address constant CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
    address constant CHAINLINK_LINK_USD = address(0xca236E327F629f9Fc2c30A4E95775EbF0B89fac8);
    address constant CHAINLINK_BNB_USD = address(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE);
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
    uint16 privateTreasuryFeeBps = 1000;
    uint16 privateFeeToSharedLPBps = 3000;

    function setUp() public {
        
        // Fork Mainnet at a specific block
        uint256 mainnetFork = vm.createFork("mainnet", 109490107); // Do not change the block number for the unit test
        vm.selectFork(mainnetFork);
        
        // Start prank as owner
        vm.startPrank(owner);
        
        usdt = IERC20(USDT);
        btc = IERC20(BTC);
        oracle = new MockOracle(int256(100_000 * 1e8), 8);
        blackScholes = _deployBlackScholes();
        impliedVol = _deployDoppiOffer(address(blackScholes));
        doppiPoints = _deployDoppiPoints();
        doppiLP = _deployDoppiLiquidity();
        doppiCore = _deployDoppiCore(doppiLP, impliedVol, doppiPoints);
        doppiOpportunity = _deployDoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiReferral = _deployDoppiReferral(address(doppiPoints));
    
        doppiRouter = new DoppiLiquidityRouter(IERC20(USDT), IERC20(BTC), doppiLP);
        doppiRouter.setDoppiCore(address(doppiCore));
        doppiLP.setDoppiLiquidityRouter(address(doppiRouter));
        doppiFactory = new DoppiTraderFactory(IERC20(USDT), IERC20(BTC), address(doppiCore), address(doppiLP), address(doppiRouter), address(impliedVol), address(doppiPoints));
        
        doppiToken = new DOPPI("Doppi Token", "DOPPI");
        doppiClaim = _deployDoppiClaim(doppiPoints, doppiReferral, doppiToken);
        
        _setDoppiLiquidityProperties(doppiLP, address(doppiCore), doppiRouter, address(doppiFactory));
        _setDoppiCoreProperties(doppiCore, doppiFactory, address(doppiOpportunity));

        doppiPoints.setCoreTraderFactory(address(doppiCore), address(doppiFactory));
        doppiOpportunity.setForwarderAddress(forwarder);

        // // Deploy private factory implementations
        DoppiGridTrader privateTraderImpl = new DoppiGridTrader();
        // Deploy private grid factory
        privateFactory = new PrivateDoppiGridTraderFactory(
            IERC20(USDT),
            IERC20(BTC),
            address(doppiLP),
            address(impliedVol),
            address(doppiPoints),
            address(privateTraderImpl)
        );
        doppiPoints.setCoreRegistrar(address(privateFactory), true);

        doppiLP.setDoppiTraderFactory(address(privateFactory));
        
        // Deploy PrivateAutomationHub for private grid bot job scheduling and billing
        privateAutomationHub = new PrivateAutomationHub(
            owner, // owner (deployer EOA)
            USDT,          // fundToken for billing
            CHAINLINK_BNB_USD, // chainlink feed for native asset pricing
            100 days,      // maxOracleDelay (scenario warps 1+ day before upkeep)
            treasury       // treasury for fee collection
        );
        console.log("PrivateAutomationHub deployed at:", address(privateAutomationHub));

        DoppiFeePool doppiFeePool = new DoppiFeePool(
            address(doppiLP),
            treasury,
            privateFeeToSharedLPBps
        );
        doppiFeePool.setCoreAuthorizer(address(privateFactory));
        privateFactory.setDefaultPrivateTreasury(address(doppiFeePool), privateTreasuryFeeBps);

        // Wire hub to both shared and private factories for auto job registration.
        doppiFactory.setPrivateAutomationHub(address(privateAutomationHub));
        privateFactory.setPrivateAutomationHub(address(privateAutomationHub));

        // Configure points-based billing in hub.
        privateAutomationHub.setDoppiPointsContract(address(doppiPoints));
        privateAutomationHub.setDoppiPointsExchangeRate(10000); // 1 point ~= 1 USDT unit (basis points)
        
        // Register both factories + deployer as registrars in the hub.
        privateAutomationHub.setRegistrar(address(doppiFactory), true);
        privateAutomationHub.setRegistrar(address(privateFactory), true);
        privateAutomationHub.setRegistrar(owner, true);

        // Allow deployer to call performUpkeep in localhost testing.
        privateAutomationHub.setExecutor(owner, true);
        privateAutomationHub.setExecutor(forwarder, true);

        // Authorize PrivateAutomationHub to deduct points for fees in DoppiPoints
        doppiPoints.setAuthorizedPointsDeductor(address(privateAutomationHub), true);

        doppiPoints.setCoreRegistrar(address(privateFactory), true);

        
        _setupIV(impliedVol);        
        vm.stopPrank();
    }
   
    function test_Scenario_TraderBotStart() public {
        
        
        deal(BTC, address(trader), 1 ether);
        deal(USDT, address(trader), 100_000 ether);
        
        // Deploy bot
        vm.startPrank(trader);
        uint32 traderId = privateFactory.deployPrivateBot(defaultWeights);
        DoppiGridTrader traderBot = DoppiGridTrader(privateFactory.traderBots(traderId));
        
        // Seed billing credit so strict mode allows upkeep execution.
        usdt.approve(address(privateAutomationHub), 1_000 ether);
        privateAutomationHub.deposit(address(traderBot), 1_000 ether);
        vm.stopPrank();

        // Fund and start
        vm.startPrank(trader);
        usdt.approve(address(traderBot), 10000 ether);
        btc.approve(address(traderBot), 0.2 ether);
        uint256 gasBefore = gasleft();
        traderBot.start(10000 ether, 0.1 ether);
        uint256 gasUsed = gasBefore - gasleft();
        console.log(gasUsed, "gasUsed in traderBot.start");
        vm.stopPrank();

        // Check positions
        DoppiGridTrader.EpochZoneInfo[] memory zones = traderBot.getEpochZoneInfo();
        _display(zones);
        
        _manipulateRealChainlink(int256(68_600 * 1e8), address(oracle));
        _doppiPrivateAutomationHubCheckUpkeep_performUpkeep();
        
        zones = traderBot.getEpochZoneInfo();
        _display(zones);
        
        // after 1 day, the bot place the next round
        vm.warp(block.timestamp + 1 days + 1);
        _manipulateRealChainlink(int256(68_100 * 1e8), address(oracle));
        _doppiPrivateAutomationHubCheckUpkeep_performUpkeep();

        zones = traderBot.getEpochZoneInfo();
        _display(zones);

        vm.warp(block.timestamp + 50 seconds);
        
        _manipulateRealChainlink(int256(64_500 * 1e8), address(oracle));
        _doppiPrivateAutomationHubCheckUpkeep_performUpkeep();
        
        zones = traderBot.getEpochZoneInfo();
        _display(zones);

        // after 1 day, the bot place the next round
        vm.warp(block.timestamp + 2 days + 1);
        _doppiPrivateAutomationHubCheckUpkeep_performUpkeep();

        zones = traderBot.getEpochZoneInfo();
        _display(zones);

        vm.warp(block.timestamp + 3600 seconds);
        
        _manipulateRealChainlink(int256(69_500 * 1e8), address(oracle));
        _doppiPrivateAutomationHubCheckUpkeep_performUpkeep();

        zones = traderBot.getEpochZoneInfo();
        _display(zones);

        // stop the bot reset the bot state
        vm.startPrank(trader);
        gasBefore = gasleft();
        traderBot.stop();
        gasUsed = gasBefore - gasleft();
        console.log(gasUsed, "gasUsed in traderBot.stop");
        vm.stopPrank();

        zones = traderBot.getEpochZoneInfo();
        _display(zones);

    }

    function _display(DoppiGridTrader.EpochZoneInfo[] memory zones) internal view {
        console.log(zones[0].zone, "zone"); // 1
        console.log(zones[0].buyStrike, "buyStrike");
        console.log(zones[0].sellStrike, "sellStrike");
        console.log(zones[0].originalBuyAmount, "originalBuyAmount");
        console.log(zones[0].originalSellAmount, "originalSellAmount");
        console.log(zones[0].remainingBuyOpportunity, "remainingBuyOpportunity");
        console.log(zones[0].remainingSellOpportunity, "remainingSellOpportunity");
    }

    function _getBotBilling(address bot) internal view {
        
        BotBillingState memory billingState = privateAutomationHub.getBotBilling(bot);
        // console.log(privateAutomationHub.minCreditThreshold(), "minCreditThreshold");
        // console.log("Trader:", billingState.trader);
        // console.log(billingState.creditBalance, "Credit Balance");
        // console.log(billingState.totalGasFeePaid, "Total Gas Fee Paid");
        // console.log("Low Credit Paused:", billingState.lowCreditPaused);
        // console.log("Use Points:", billingState.usePoint);
        assertLt(billingState.creditBalance, 1_000 ether, "Expected credit balance < 1000 USDT after upkeep");
        assertGt(billingState.totalGasFeePaid, 0, "Expected total gas fee paid > 0 USDT after upkeep");
        assertFalse(billingState.lowCreditPaused, "Expected low credit paused to be false after upkeep");

    }

    function _setDoppiCoreProperties(
        DoppiCore _doppiCore, 
        DoppiTraderFactory _doppiFactory,
        address _doppiOpportunity
        ) internal {
        
        _doppiCore.setForwarderAddress(forwarder);
        _doppiCore.setOpportunityBot(_doppiOpportunity, true);
        _doppiCore.setDoppiTraderFactory(_doppiFactory);
        _doppiCore.setAPRTolerance(300);
        _doppiCore.setTreasury(treasury, 1000);
    }

    function _setDoppiLiquidityProperties(
        DoppiLiquidity _doppiLP, 
        address _doppiCore, 
        DoppiLiquidityRouter _doppiRouter,
        address _doppiFactory
        ) internal {
        
        _doppiLP.setDoppiCore(_doppiCore);
        _doppiLP.setEntryPoint(address(_doppiRouter.entryPointA()), true);
        _doppiLP.setEntryPoint(address(_doppiRouter.entryPointB()), true);
        _doppiLP.setDoppiTraderFactory(_doppiFactory);
        _doppiLP.lockEntryPoints();
    }

    function _deployDoppiCore(DoppiLiquidity _doppiLP, DoppiOffer _impliedVol, DoppiPoints _doppiPoints) internal returns (DoppiCore) {
        
        DoppiCore _doppiCore = new DoppiCore(USDT, BTC, _doppiLP, _impliedVol, address(_doppiPoints));
        _doppiPoints.setDoppiCore(address(_doppiCore), true);
        _doppiCore.setTreasury(treasury, 1000);
        _doppiCore.setUpkeeps_per_check(100);
        return _doppiCore;
    }
        
    function _deployDoppiOpportunity(address _doppiCore, address _doppiLP) internal returns (DoppiOpportunity) {
    
        DoppiOpportunity _doppiOpportunity = new DoppiOpportunity(_doppiCore, _doppiLP);
        return _doppiOpportunity;
    }

    function _deployDoppiLiquidity() internal returns (DoppiLiquidity) {
        
        DoppiLiquidity _doppiLP = new DoppiLiquidity("Doppi BTC-USDT LP", "BTCB-USDT", address(IERC20(USDT)), address(IERC20(BTC)));
        configLP = _getConfigLP();
        _doppiLP.setConfig(configLP); 
        _doppiLP.approveRouter();
        _doppiLP.setForwarderAddress(forwarder);
        
        return _doppiLP;
    }

    function _deployBlackScholes() internal returns (BlackScholes) {
        
        BlackScholes _blackScholes = new BlackScholes();
        return _blackScholes;
    }

    function _deployDoppiClaim(DoppiPoints _doppiPoints, DoppiReferral _doppiReferral, DOPPI _doppiToken) internal returns (DoppiClaim) {
        DoppiClaim _doppiClaim = new DoppiClaim(
            address(_doppiToken),
            address(_doppiPoints),
            address(_doppiReferral),
            1 // 1 token per point
        );
        _doppiPoints.setDoppiClaim(address(_doppiClaim));
        _doppiReferral.setDoppiClaim(address(_doppiClaim));
        _doppiToken.addMinter(address(_doppiClaim));
        return _doppiClaim;
    }

    function _deployDoppiReferral(address _doppiPoints) internal returns (DoppiReferral) {
        DoppiReferral _doppiReferral = new DoppiReferral(_doppiPoints, 150, 100, 50);
        _doppiReferral.setMinVolumeForL2L3(1_000 ether, 2_000 ether);
        DoppiPoints(_doppiPoints).setDoppiReferral(address(_doppiReferral));
        return _doppiReferral;
    }

    function _deployDoppiOffer(address _blackScholes) internal returns (DoppiOffer) {
        
        DoppiOffer _impliedVol = new DoppiOffer(IBlackScholes(_blackScholes), CHAINLINK_BTC_USD, 500);
        _impliedVol.setTwapDuration(3600);
        _impliedVol.setPancakeV3Pool(PCSWAP_V3Pool);
        return _impliedVol;
    }

    function _deployDoppiPoints() internal returns (DoppiPoints) {
        DoppiPoints _doppiPoints = new DoppiPoints();
        return _doppiPoints;
    }

    function _doppiPrivateAutomationHubCheckUpkeep_performUpkeep() internal {

        uint256 gasBefore = gasleft();
        (bool upkeepNeeded, bytes memory performData) = privateAutomationHub.checkUpkeep("");
        uint256 gasUsed = gasBefore - gasleft();
        console.log(gasUsed, "gasUsed in privateAutomationHub.checkUpkeep");
        
        if(upkeepNeeded){

            (uint256 nextCursor, uint256[] memory jobIds, bytes[] memory payloads) =
            abi.decode(performData, (uint256, uint256[], bytes[]));
            // console.log("Decoded nextCursor:", nextCursor);
            // console.log("Selected job count:", jobIds.length);
            
            vm.txGasPrice(0.1 gwei);
            vm.prank(forwarder);
            gasBefore = gasleft();
            privateAutomationHub.performUpkeep(performData);  
            gasUsed = gasBefore - gasleft();
            console.log(gasUsed, "gasUsed in privateAutomationHub.performUpkeep");
            vm.stopPrank();

            uint256 scanCursorAfter = privateAutomationHub.scanCursor();
            console.log("Hub scanCursor after:", scanCursorAfter);

            for (uint256 i = 0; i < jobIds.length; ) {
                PrivateJobView memory afterJob = privateAutomationHub.getJob(jobIds[i]);
                console.log("After jobId:", jobIds[i]);
                console.log("After active:", afterJob.active);
                console.log("After failCount:", afterJob.failCount);
                console.log("After lastRunAt:", uint256(afterJob.lastRunAt));
                console.log("After nextEligibleAt:", uint256(afterJob.nextEligibleAt));
                unchecked { ++i; }
            }
        }
    }


    function _setupIV(DoppiOffer _impliedVol) internal {
        
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
    }

    function _manipulateRealChainlink(int256 newPrice, address _oracle) internal {
        
        // Then override the feed address
        vm.prank(owner);
        MockOracle(_oracle).setPrice(newPrice);
        vm.stopPrank();
        configLP = _getConfigLP();
        configLP.chainLinkFeed = _oracle;
        vm.prank(doppiLP.owner());
        doppiLP.setConfig(configLP); 
        vm.stopPrank();
        vm.prank(impliedVol.owner());
        impliedVol.setOracle(_oracle);
        vm.stopPrank();

    }

    function _getConfigLP() internal returns (ConfigParam memory _configLP)  {

        _configLP = ConfigParam({
			chainLinkFeed : CHAINLINK_BTC_USD,
			router : PCSWAP_V3_ROUTER,
			poolFee: 500,  
			slippage: 2000,
			liquidityFee: 1000,
			priceDecimals: 8,
			decimals: 10 ** 8,
			v3Pool: PCSWAP_V3Pool,
			twapDuration: 3600,
			maxDepositPercentage: 20000,
			maxDelay: 2 minutes,
			maxSwap: 500000 ether,
            priceGap: 500,
            unwindGapMultiplier: 1
		});
    }

    
}
