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


contract DoppiCoreEmergencyTest is Test {
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
    MockOracle oracle;
    // MockDoppiUpKeepManager mockDoppiUpKeepManager;
    DoppiOpportunity doppiOpportunity;
    // Swapper public swapper;
    DoppiPoints doppiPoints;
    DoppiUpkeepManager doppiUpkeepManager;
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
        uint256 mainnetFork = vm.createFork("mainnet", 92227024); // Do not change the block number for the unit test
        vm.selectFork(mainnetFork);
        
        // Start prank as owner
        vm.startPrank(owner);
        
        usdt = IERC20(USDT);
        btc = IERC20(BTC);
        link = IERC20(LINK);
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
        doppiFactory = new DoppiTraderFactory(IERC20(USDT), IERC20(BTC), address(doppiCore), address(doppiLP), address(doppiRouter));
        doppiUpkeepManager = _deployDoppiUpkeepManager(address(doppiFactory));
        
        doppiToken = new DOPPI("Doppi Token", "DOPPI");
        doppiClaim = _deployDoppiClaim(doppiPoints, doppiReferral, doppiToken);
        
        _setDoppiLiquidityProperties(doppiLP, address(doppiCore), doppiRouter, address(doppiFactory));
        _setDoppiCoreProperties(doppiCore, doppiFactory, address(doppiOpportunity));

        doppiPoints.setCoreTraderFactory(address(doppiCore), address(doppiFactory));
        doppiOpportunity.setForwarderAddress(forwarder);
        
        _setupIV(impliedVol);        
        vm.stopPrank();
    }

    function test_doppiCore_scenario_bot_oppo_settle() public {

        vm.startPrank(doppiCore.owner());
        doppiCore.setUpkeeps_per_check(5);
        vm.stopPrank();

        uint256 amountUSDT = 2_000 ether;
        uint256 amountBTC = 0.02 ether;

        deal(USDT, trader, amountUSDT);            
        deal(BTC, trader, amountBTC);            

        vm.startPrank(trader); 
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        usdt.approve(address(traderBot), amountUSDT);
        btc.approve(address(traderBot), amountBTC);
        traderBot.start(amountUSDT, amountBTC);
        traderBot.setForwarderAddress(forwarder);
        vm.stopPrank();

        int256 newPrice = int256(67000 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));

        // perform opportunity settlement
        _doppiOpportunityCheckUpkeep_performUpkeep();
        
        (uint256 lowerBound, uint256 upperBound) = doppiCore.getLowerUpperBound();
        // console.log("Lower bound:", lowerBound, "Upper bound:", upperBound);
        assertEq(lowerBound, 6900000000000, "Lower bound should be 69000"); 
        assertEq(upperBound, 7350000000000, "Upper bound should be 73500"); 

        _displayBound(lowerBound, upperBound);
        
        vm.warp(vm.getBlockTimestamp() + 1 days);
        newPrice = int256(71000 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));

        _doppiCoreCheckUpkeep_performUpkeep();

        (lowerBound, upperBound) = doppiCore.getLowerUpperBound();
        // console.log("Lower bound:", lowerBound, "Upper bound:", upperBound);
        assertEq(lowerBound, 7150000000000, "Lower bound should be 71500"); 
        assertEq(upperBound, 7350000000000, "Upper bound should be 73500"); 

        _displayBound(lowerBound, upperBound);
        
        _doppiCoreCheckUpkeep_performUpkeep();

        newPrice = int256(70220 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        
        vm.startPrank(owner);
        _setupIV(impliedVol);
        vm.stopPrank();
        
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 count = doppiCore.getBuyPositionCount(address(traderBot));
        assertEq(count, 5, "Buy positions should not be settled yet before upkeep");
        count = doppiCore.getSellPositionCount(address(traderBot));
        assertEq(count, 5, "Sell positions should not be settled yet before upkeep");
        
        _doppiCoreCheckUpkeep_performUpkeep();
        count = doppiCore.getBuyPositionCount(address(traderBot));
        assertEq(count, 0, "Buy positions should be fully settled with the first 5 after second upkeeps");
        count = doppiCore.getSellPositionCount(address(traderBot));
        assertEq(count, 5, "Sell positions should not be settled yet in secound upkeep");
        
        _doppiCoreCheckUpkeep_performUpkeep();

        count = doppiCore.getBuyPositionCount(address(traderBot));
        assertEq(count, 0, "Buy positions should be fully settled after third upkeep");
        count = doppiCore.getSellPositionCount(address(traderBot));
        assertEq(count, 0, "Sell positions should be fully settled after third upkeep");


        (uint256 amount, uint256 swappedAmount, uint256 outAmount) = doppiCore.opportunityBuy(7100000000000);
        assertEq(amount, 0, "No opportunity should be available at this price");
        assertEq(swappedAmount, 0, "No opportunity should be available at this price");
        assertEq(outAmount, 0, "No opportunity should be available at this price");

        (amount, swappedAmount, outAmount) = doppiCore.opportunityBuy(7050000000000);
        assertEq(amount, 0, "No opportunity should be available at this price");
        assertEq(swappedAmount, 0, "No opportunity should be available at this price");
        assertEq(outAmount, 0, "No opportunity should be available at this price");
        
        (lowerBound, upperBound) = doppiCore.getLowerUpperBound();
        assertEq(lowerBound, 0, "Lower bound should be 0"); // reset
        assertEq(upperBound, 0, "Upper bound should be 0"); // reset

        
    }

    function test_doppiCore_scenario_emergency_withdraw() public {

        uint256 amountUSDT = 100_000 ether;
        uint256 amountBTC = 1 ether;

        deal(USDT, trader, amountUSDT);            
        deal(BTC, trader, amountBTC);            

        int256 startPrice = int256(9151519000000);
        _manipulateRealChainlink(startPrice, address(oracle));   

        vm.startPrank(trader); 
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        usdt.approve(address(traderBot), amountUSDT);
        btc.approve(address(traderBot), amountBTC);
        traderBot.start(amountUSDT, amountBTC);
        vm.stopPrank();

        int256 newPrice = int256(9742000000000);
        _manipulateRealChainlink(newPrice, address(oracle));

        (uint256 ratioA, uint256 ratioB) = doppiLP.assetRatio();
        
        // perform opportunity settlement
        _doppiOpportunityCheckUpkeep_performUpkeep();
        OpportunityOrders memory sell = doppiCore.getOpportunityOrders(false, 9250000000000);
        assertGt(sell.swappedAmount, 0); // Ensure that the opportunity settlement actually executed a swap
        assertGt(sell.outAmount, 0);
        (ratioA, ratioB) = doppiLP.assetRatio();
        
        vm.startPrank(owner);
        doppiCore.setPause();
        doppiCore.setEmergencyMode(true);
        vm.stopPrank();

        vm.startPrank(owner);
        doppiRouter.setPause();
        doppiRouter.setEmergencyMode(true);
        vm.stopPrank();

        uint256 start_usdtbal = usdt.balanceOf(trader);
        uint256 start_btcbal = btc.balanceOf(trader);
        console.log(start_usdtbal, start_btcbal, "start balances before emergency withdraw");
        
        
        uint256 bot_usdtbal = usdt.balanceOf(address(traderBot));
        uint256 bot_btcbal = btc.balanceOf(address(traderBot));
        console.log(bot_usdtbal, bot_btcbal, "bot balances before emergency settlement");

        // let admin manually trigger emergency settlement in doppiCore to settle all positions
        vm.startPrank(doppiCore.owner());
        doppiCore.emergencySettlement(1);
        vm.stopPrank();

        bot_usdtbal = usdt.balanceOf(address(traderBot));
        bot_btcbal = btc.balanceOf(address(traderBot));
        console.log(bot_usdtbal, bot_btcbal, "bot balances after emergency settlement");
        assertEq(bot_usdtbal, 49975 ether); // 25 is in upkeep manager, so 49975 instead of 50000
        assertEq(bot_btcbal, 0.5 ether); 
        

        // emergency withdraw buy and sell
        vm.startPrank(trader);
        traderBot.emergencyWithdraw();
        vm.stopPrank();

        assertEq(doppiCore.getBuyPositionCount(address(traderBot)), 0);
        assertEq(doppiCore.getSellPositionCount(address(traderBot)), 0);

        uint256 end_usdtbal = usdt.balanceOf(trader);
        uint256 end_btcbal = btc.balanceOf(trader);
        console.log(end_usdtbal, end_btcbal, "end balances after emergency withdraw");

        uint256 totalAssetsInAssetA = doppiLP.totalAssetsInAssetA();
        uint256 totalAssetsInAssetB = doppiLP.totalAssetsInAssetB();
        // console.log(totalAssetsInAssetA, totalAssetsInAssetB, "total assets in doppiLP after emergency withdraw");
        assertApproxEqAbs(totalAssetsInAssetA, 0, 1);
        assertApproxEqAbs(totalAssetsInAssetB, 0, 1);

        assertApproxEqAbs(end_usdtbal, 100_000 ether, 30 ether); // due to the swap slippage and 25 USDT in UpkeepManager
        assertApproxEqAbs(end_btcbal, 1 ether, 0.001 ether);
        
    }

    function _getBuffer() internal view {

        uint256 price = doppiLP.getPrice();
        uint256 buyBuffer = impliedVol.getOneDayBuffer(price, true);
        uint256 sellBuffer = impliedVol.getOneDayBuffer(price, false);
        console.log("buyBuffer", buyBuffer);
        console.log("sellBuffer", sellBuffer);
    }

    function _depositBTC(uint256 amount) internal returns (DualAssetOffer memory) {

        DualAssetOffer memory sellOffer = impliedVol.getOffer(false, 1, 0);
        DepositParams memory params = DepositParams({
            amount: amount,
            strikeZone: 0,
            strikePrice: sellOffer.strikePrice,
            numDays: 1,
            apr: sellOffer.apr,
            expiry: sellOffer.expiry
        });

        vm.startPrank(trader);
        btc.approve(address(doppiCore), params.amount);
        doppiCore.deposit_sell(params);
        vm.stopPrank();
        return sellOffer;
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
    }

    function _deployDoppiCore(DoppiLiquidity _doppiLP, DoppiOffer _impliedVol, DoppiPoints _doppiPoints) internal returns (DoppiCore) {
        
        DoppiCore _doppiCore = new DoppiCore(USDT, BTC, _doppiLP, _impliedVol, address(_doppiPoints));
        _doppiPoints.setDoppiCore(address(_doppiCore), true);
        _doppiCore.setTreasury(treasury, 1000);
        _doppiCore.setUpkeeps_per_check(100);
        _doppiCore.addSupportDay(3);
        _doppiCore.addSupportDay(7);
        return _doppiCore;
    }
        
        
    function _deployDoppiOpportunity(address _doppiCore, address _doppiLP) internal returns (DoppiOpportunity) {
    
        DoppiOpportunity _doppiOpportunity = new DoppiOpportunity(_doppiCore, _doppiLP);
        return _doppiOpportunity;
    }

    function _deployDoppiLiquidity() internal returns (DoppiLiquidity) {
        
        DoppiLiquidity _doppiLP = new DoppiLiquidity("Doppi BTC-USDT LP", "BTCB-USDT", IERC20(USDT), IERC20(BTC));
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

    function _deployDoppiUpkeepManager(address _doppiFactory) internal returns (DoppiUpkeepManager) {

        IAutomationRegistrar registrar = IAutomationRegistrar(CHAINLINK_Registrar);
        // IAutomationRegistryConsumer registryConsumer = IAutomationRegistryConsumer(CHAINLINK_RegistryConsumer);
        MockRegistryConsumer mockRegistryConsumer = new MockRegistryConsumer();
        mockRegistryConsumerAddr = address(mockRegistryConsumer);
        DoppiUpkeepManager _doppiUpkeepManager = new DoppiUpkeepManager(
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
        // console.log("mockRegistryConsumer deployed at:", address(mockRegistryConsumer));
        _doppiUpkeepManager.setMaxDelay(10 days);
        doppiFactory.setDoppiUpKeepManager(address(_doppiUpkeepManager));

        return _doppiUpkeepManager;
    }  

    function _doppiCoreCheckUpkeep_performUpkeep() internal {

        uint256 gasBefore = gasleft();
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        uint256 gasUsed = gasBefore - gasleft();
        console.log(gasUsed, "gasUsed in doppiCore.checkUpkeep");
        
        if(upkeepNeeded){
            vm.prank(forwarder);
            gasBefore = gasleft();
            doppiCore.performUpkeep(performData);  
            gasUsed = gasBefore - gasleft();
            console.log(gasUsed, "gasUsed in doppiCore.performUpkeep");
            vm.stopPrank();
        }else{
            console.log("No upkeep needed at this time");
        }
    }

    function _doppiOpportunityCheckUpkeep_performUpkeep() internal {
        
        uint256 gasBefore = gasleft();
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        uint256 gasUsed = gasBefore - gasleft();
        console.log(upkeepNeeded, gasUsed, "gasUsed in doppiOpportunity.checkUpkeep");
        assertLt(gasUsed, 1_000_000, "Gas usage too high");

        if(upkeepNeeded){
            vm.prank(forwarder);
            gasBefore = gasleft();
            doppiOpportunity.performUpkeep(performData);
            gasUsed = gasBefore - gasleft();
            console.log(gasUsed, "gasUsed in doppiOpportunity.performUpkeep");
            assertLt(gasUsed, 2_000_000, "Gas usage too high");
            vm.stopPrank();
        }
        
    }

    function _doppiTraderCheckUpkeep_performUpkeep(DoppiTrader traderBot) internal {
        
        uint256 gasBefore = gasleft();
        (bool upkeepNeeded, bytes memory performData) = traderBot.checkUpkeep("");
        uint256 gasUsed = gasBefore - gasleft();
        console.log(upkeepNeeded, gasUsed, "gasUsed in traderBot.checkUpkeep");
        assertLt(gasUsed, 400_000, "Gas usage too high");

        if(upkeepNeeded){
            vm.prank(forwarder);
            gasBefore = gasleft();
            traderBot.performUpkeep(performData);
            gasUsed = gasBefore - gasleft();
            console.log(gasUsed, "gasUsed in traderBot.performUpkeep");
            assertLt(gasUsed, 4_500_000, "Gas usage too high");
            vm.stopPrank();
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
        _impliedVol.setRegression(86400 * 3, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
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
			slippage: 3000,
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

    function _generateRandomAmount(uint256 seed) internal pure returns (uint256) {
        // Generate amount between 1000 and 5000 tokens
        uint256 base = 1000 * 10**18;
        if(seed > 15){
            seed -= 5;
        }else if(seed > 25){
            seed -= 10;
        }  
        // uint256 variation = (uint256(keccak256(abi.encodePacked(seed))) % 4990) + 10;
        return base * (seed + 1);
    }

    function _getStrikePrice(uint256 _price, uint8 _strikeZone, bool _isBuy) internal view returns (uint256) {
        
        uint256 priceGapWithDecimals = 500 * 1e8;
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * (_strikeZone - 1)) : _price + (priceGapWithDecimals * _strikeZone);
    }

    function _displayBound(uint256 lowerBound, uint256 upperBound) internal view {
        
        for (uint256 price = upperBound; price >= lowerBound; ) {
            // console.log(price, "price");
            bool isBuy = true;
            (uint256 amount, uint256 swappedAmount, uint256 outAmount) = doppiCore.opportunityBuy(price);
            
            if(amount == 0){
                isBuy = false;
                (amount, swappedAmount, outAmount) = doppiCore.opportunitySell(price);
            }
            console.log(isBuy, price, swappedAmount, outAmount);
            price -= (500 * 1e8); 
        }

    }

}
