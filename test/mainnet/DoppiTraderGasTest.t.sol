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


contract DoppiTraderGasTest is Test {
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
        uint256 mainnetFork = vm.createFork("mainnet", 69703761); // Do not change the block number for the unit test
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

        doppiPoints.setDoppiTraderFactory(address(doppiFactory));
        doppiOpportunity.setForwarderAddress(forwarder);
        
        _setupIV(impliedVol);        
        vm.stopPrank();
    }

    function test_Scenario_CheckUpKeep_DoppiTrader_CheckUndoTrade_BuyOrder() public {
        
        uint256 depositLPAmount = 100_000_000 ether;
        uint256 depositBTCAmount = 100.0000 ether;

        deal(USDT, trader, depositLPAmount);            
        deal(BTC, trader, depositBTCAmount);            
            
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        // Deploy bot
        vm.startPrank(trader); 
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        vm.stopPrank();

        vm.startPrank(traderBot.owner());            
        traderBot.setMaxSwap(500000 ether);
        vm.stopPrank();

        uint256 strikePrice = 89500 * 1e8;        
        uint256 swapAmount = 100 ether;
        vm.startPrank(address(doppiCore));
        uint256 payout = swapAmount * 1e8 / strikePrice;
        traderBot.createUnwindPosition(payout, strikePrice , true);
        vm.stopPrank();

        int256 newPrice = int256(89520 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        
        deal(BTC, address(traderBot), payout); 

        uint256 unwindAmount = traderBot.getUnwindInfo(true, 89500 * 1e8);
        // console.log(unwindAmount, payout, "before upkeep");
        assertEq(unwindAmount, payout);
        
        (uint256 lowerBound, uint256 upperBound) = traderBot.getLowerUpperBound();
        console.log(lowerBound, upperBound);
        _displayBound(traderBot, lowerBound, upperBound);
        
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);        
        (lowerBound, upperBound) = traderBot.getLowerUpperBound();
        console.log(lowerBound, upperBound);
        _displayBound(traderBot, lowerBound, upperBound);
        assertEq(lowerBound, 8950000000000);
        assertEq(upperBound, 8950000000000);

        newPrice = int256(90020 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);        
        (lowerBound, upperBound) = traderBot.getLowerUpperBound();
        console.log(lowerBound, upperBound);
        _displayBound(traderBot, lowerBound, upperBound);

        newPrice = int256(90520 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);        
        (lowerBound, upperBound) = traderBot.getLowerUpperBound();
        console.log(lowerBound, upperBound);
        _displayBound(traderBot, lowerBound, upperBound);
        
    }

    function test_Scenario_CheckUpKeep_DoppiTrader_CheckUndoTrade_SellOrder() public {
        
        uint256 depositLPAmount = 100_000_000 ether;
        uint256 depositBTCAmount = 100.0000 ether;

        deal(USDT, trader, depositLPAmount);            
        deal(BTC, trader, depositBTCAmount);            
            
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        // Deploy bot
        vm.startPrank(trader); 
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        vm.stopPrank();

        vm.startPrank(traderBot.owner());            
        traderBot.setMaxSwap(500000 ether);
        vm.stopPrank();

        uint256 strikePrice = 89500 * 1e8;        
        uint256 swapAmount = 100 ether;
        vm.startPrank(address(doppiCore));
        uint256 payout = swapAmount; //swapAmount * 1e8 / strikePrice;
        traderBot.createUnwindPosition(payout, strikePrice , false);
        vm.stopPrank();

        int256 newPrice = int256(89480 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        
        deal(USDT, address(traderBot), payout); 

        uint256 unwindAmount = traderBot.getUnwindInfo(false, 89500 * 1e8);
        // console.log(unwindAmount, payout, "before upkeep");
        assertEq(unwindAmount, payout);
        
        (uint256 lowerBound, uint256 upperBound) = traderBot.getLowerUpperBound();
        console.log(lowerBound, upperBound);
        _displayBound(traderBot, lowerBound, upperBound);
        
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);        
        (lowerBound, upperBound) = traderBot.getLowerUpperBound();
        console.log(lowerBound, upperBound);
        _displayBound(traderBot, lowerBound, upperBound);
        assertEq(lowerBound, 8950000000000);
        assertEq(upperBound, 8950000000000);

        newPrice = int256(88520 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);        
        (lowerBound, upperBound) = traderBot.getLowerUpperBound();
        console.log(lowerBound, upperBound);
        _displayBound(traderBot, lowerBound, upperBound);

        newPrice = int256(88420 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);        
        (lowerBound, upperBound) = traderBot.getLowerUpperBound();
        console.log(lowerBound, upperBound);
        _displayBound(traderBot, lowerBound, upperBound);
        
    }

    function test_Scenario_CheckUpKeep_DoppiTrader_GasMax_Buy() public {
        
        uint256 depositLPAmount = 100_000_000 ether;
        uint256 depositBTCAmount = 100.0000 ether;

        deal(USDT, trader, depositLPAmount);            
        deal(BTC, trader, depositBTCAmount);            
            
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        // Deploy bot
        vm.startPrank(trader); 
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        vm.stopPrank();
        
        vm.startPrank(traderBot.owner());            
        traderBot.setMaxSwap(500000 ether);
        traderBot.setUnwindGapMultiplier(0);
        vm.stopPrank();

        uint256 totalSwaps = 500;
        uint256 priceChanges = 50; // Change price 50 times during test
        uint256 swapsPerPrice = totalSwaps / priceChanges;

        uint256 totalPayout;
        uint256 currentPrice = (100_000 * 10**8) * (10100 / 10000);
        for (uint256 priceChange = 0; priceChange < priceChanges; priceChange++) {
            
            int256 startPrice = int256(currentPrice);
            _manipulateRealChainlink(startPrice, address(oracle));            
            uint256 strikePrice = _getStrikePrice(currentPrice, 1, true);
            // Perform swaps at this price
            for (uint256 swapNum = 0; swapNum < swapsPerPrice; swapNum++) {
                uint256 swapAmount = _generateRandomAmount(swapNum);
                vm.startPrank(address(doppiCore));
                uint256 payout = swapAmount * 1e8 / strikePrice;
                totalPayout += payout;
                traderBot.createUnwindPosition(payout, strikePrice , true);
                vm.stopPrank();
            }

            // Generate random price between 100000 and 120000 
            if(priceChange > 10 && priceChange <= 15){
                currentPrice = currentPrice * 9950 / 10000;
            }else if(priceChange > 15 && priceChange <= 20){
                currentPrice = currentPrice * 10050 / 10000;
            }else if(priceChange > 20 && priceChange <= 25){
                currentPrice = currentPrice * 9910 / 10000;
            }else{
                currentPrice = currentPrice * 10010 / 10000;
            }
        }
        int256 newPrice = int256(99556 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        
        deal(BTC, address(traderBot), totalPayout); 

        uint256 unwindAmount = traderBot.getUnwindInfo(true, 9750000000000);
        assertEq(unwindAmount, 2820512820512820490);
        unwindAmount = traderBot.getUnwindInfo(true, 9800000000000);
        assertEq(unwindAmount, 3367346938775510178);
        unwindAmount = traderBot.getUnwindInfo(true, 9850000000000);
        assertEq(unwindAmount, 2791878172588832460);
        unwindAmount = traderBot.getUnwindInfo(true, 9900000000000);
        assertEq(unwindAmount, 3333333333333333330);

        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        
        newPrice = int256(100056 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        
        unwindAmount = traderBot.getUnwindInfo(true, 9750000000000);
        assertEq(unwindAmount, 0);
        unwindAmount = traderBot.getUnwindInfo(true, 9800000000000);
        assertEq(unwindAmount, 0);
        unwindAmount = traderBot.getUnwindInfo(true, 9850000000000);
        assertEq(unwindAmount, 0);
        unwindAmount = traderBot.getUnwindInfo(true, 9900000000000);
        assertEq(unwindAmount, 0);

        unwindAmount = traderBot.getUnwindInfo(true, 9950000000000);
        assertEq(unwindAmount, 0);
        
        (uint256 undo_assetB, uint256 undo_assetA) = traderBot.undoStat();
        (uint256 lowerBound, uint256 upperBound) = traderBot.getLowerUpperBound();
        _displayBound(traderBot, lowerBound, upperBound);
        assertEq(lowerBound, 10000000000000);
        assertEq(upperBound, 10200000000000);
    }

    function test_Scenario_CheckUpKeep_DoppiTrader_GasMax_NetBuy() public {
        
        uint256 depositLPAmount = 100_000_000 ether;
        uint256 depositBTCAmount = 100.0000 ether;

        deal(USDT, trader, depositLPAmount);            
        deal(BTC, trader, depositBTCAmount);  
        
        vm.startPrank(doppiCore.owner());            
        doppiCore.setPause();          
        vm.stopPrank();            
            
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        // Deploy bot
        vm.startPrank(trader);  
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        vm.stopPrank();

         vm.startPrank(traderBot.owner());            
        traderBot.setMaxSwap(500000 ether);
        traderBot.setUnwindGapMultiplier(0);
        vm.stopPrank();


        uint256 totalSwaps = 500;
        uint256 priceChanges = 50; // Change price 50 times during test
        uint256 swapsPerPrice = totalSwaps / priceChanges;

        uint256 totalPayoutBuy;
        uint256 totalPayoutSell;
        uint256 currentPrice = (100_000 * 10**8) * (10100 / 10000);
        for (uint256 priceChange = 0; priceChange < priceChanges; priceChange++) {
            
            int256 startPrice = int256(currentPrice);
            _manipulateRealChainlink(startPrice, address(oracle));            
            uint256 strikePrice = _getStrikePrice(currentPrice, 1, true);
            
            // Perform swaps at this price
            for (uint256 swapNum = 0; swapNum < swapsPerPrice; swapNum++) {
                bool isBuy = swapNum % 2 == 0;
                if(isBuy){
                    uint256 swapAmount = _generateRandomAmount(swapNum);
                    vm.startPrank(address(doppiCore));
                    uint256 payout = swapAmount * 1e8 / strikePrice;
                    totalPayoutBuy += payout;
                    traderBot.createUnwindPosition(payout, strikePrice , true);
                    vm.stopPrank();
                }else{
                    uint256 swapAmount = _generateRandomAmount(swapNum);
                    vm.startPrank(address(doppiCore));
                    totalPayoutSell += swapAmount;
                    traderBot.createUnwindPosition(swapAmount, strikePrice, false);
                    vm.stopPrank();
                }   
            }

            // Generate random price between 100000 and 120000 
            if(priceChange > 10 && priceChange <= 15){
                currentPrice = currentPrice * 9950 / 10000;
            }else if(priceChange > 15 && priceChange <= 20){
                currentPrice = currentPrice * 10050 / 10000;
            }else if(priceChange > 20 && priceChange <= 25){
                currentPrice = currentPrice * 9910 / 10000;
            }else{
                currentPrice = currentPrice * 10010 / 10000;
            }
        }
        int256 newPrice = int256(99556 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));

        (uint256 lowerBound, uint256 upperBound) = traderBot.getLowerUpperBound();
        _displayBound(traderBot, lowerBound, upperBound);
        
        deal(BTC, address(traderBot), totalPayoutBuy); 
        deal(USDT, address(traderBot), totalPayoutSell); 

        uint256 unwindAmount = traderBot.getUnwindInfo(true, 9750000000000);
        assertEq(unwindAmount, 1282051282051282040);
        unwindAmount = traderBot.getUnwindInfo(true, 9800000000000);
        assertEq(unwindAmount, 1530612244897959174);
        unwindAmount = traderBot.getUnwindInfo(false, 10200000000000);
        assertEq(unwindAmount, 90000000000000000000000);
        unwindAmount = traderBot.getUnwindInfo(false, 10150000000000);
        assertEq(unwindAmount, 210000000000000000000000);

        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);

        (lowerBound, upperBound) = traderBot.getLowerUpperBound();
        _displayBound(traderBot, lowerBound, upperBound);

        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        
        (lowerBound, upperBound) = traderBot.getLowerUpperBound();
        _displayBound(traderBot, lowerBound, upperBound);
        
        unwindAmount = traderBot.getUnwindInfo(true, 9750000000000);
        assertEq(unwindAmount, 0);
        unwindAmount = traderBot.getUnwindInfo(true, 9800000000000);
        assertEq(unwindAmount, 0);
        unwindAmount = traderBot.getUnwindInfo(false, 10200000000000);
        assertEq(unwindAmount, 0);
        unwindAmount = traderBot.getUnwindInfo(false, 10150000000000);
        assertEq(unwindAmount, 0);

        (uint256 undo_assetB, uint256 undo_assetA) = traderBot.undoStat();
        console.log(totalPayoutBuy, totalPayoutSell, "totalPayoutBuy, totalPayoutSell");
        assertEq(undo_assetA, 740000000000000000000000);
        // assertEq(undo_assetB, 5321094126146880050);
        // console.log(traderBot.lowerBound(), traderBot.upperBound());
        (uint256 lower, uint256 upper) = traderBot.getLowerUpperBound();
        console.log(lower, upper);
        _displayBound(traderBot, lower, upper);

        newPrice = int256(97556 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);

         (lower, upper) = traderBot.getLowerUpperBound();
        console.log(lower, upper);
         _displayBound(traderBot, lower, upper);
        // assertEq(lower, 9750000000000);
        // assertEq(upper, 10200000000000);
    }

    function test_Scenario_CheckUpKeep_DoppiTrader_GasMax_Sell() public {
        
        uint256 depositLPAmount = 100_000_000 ether;
        uint256 depositBTCAmount = 100.0000 ether;

        deal(USDT, trader, depositLPAmount);            
        deal(BTC, trader, depositBTCAmount);            

  
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        // Deploy bot
        vm.startPrank(trader); 
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        vm.stopPrank();

        vm.startPrank(traderBot.owner());            
        traderBot.setMaxSwap(500000 ether);
        traderBot.setUnwindGapMultiplier(0);
        vm.stopPrank();

        uint256 totalSwaps = 500;
        uint256 priceChanges = 50; // Change price 50 times during test
        uint256 swapsPerPrice = totalSwaps / priceChanges;

        uint256 totalPayout;
        uint256 currentPrice = (100_000 * 10**8) * (10100 / 10000);
        for (uint256 priceChange = 0; priceChange < priceChanges; priceChange++) {
            
            int256 startPrice = int256(currentPrice);
            _manipulateRealChainlink(startPrice, address(oracle));            
            uint256 strikePrice = _getStrikePrice(currentPrice, 1, false);
            
            // Perform swaps at this price
            for (uint256 swapNum = 0; swapNum < swapsPerPrice; swapNum++) {
                uint256 payout = _generateRandomAmount(swapNum);
                vm.startPrank(address(doppiCore));
                totalPayout += payout;
                traderBot.createUnwindPosition(payout, strikePrice, false);
                vm.stopPrank();
            }

            // Generate random price between 100000 and 120000 
            if(priceChange > 10 && priceChange <= 15){
                currentPrice = currentPrice * 9950 / 10000;
            }else if(priceChange > 15 && priceChange <= 20){
                currentPrice = currentPrice * 10050 / 10000;
            }else if(priceChange > 20 && priceChange <= 25){
                currentPrice = currentPrice * 9910 / 10000;
            }else{
                currentPrice = currentPrice * 10010 / 10000;
            }
        }
        int256 newPrice = int256(99556 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        
        deal(USDT, address(traderBot), totalPayout); 

        uint256 unwindAmount = traderBot.getUnwindInfo(false, 10250000000000);
        assertEq(unwindAmount, 165000000000000000000000);
        unwindAmount = traderBot.getUnwindInfo(false, 10200000000000);
        assertEq(unwindAmount, 385000000000000000000000);
        unwindAmount = traderBot.getUnwindInfo(false, 10150000000000);
        assertEq(unwindAmount, 440000000000000000000000);
        unwindAmount = traderBot.getUnwindInfo(false, 10100000000000);
        assertEq(unwindAmount, 110000000000000000000000);

        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);

        unwindAmount = traderBot.getUnwindInfo(false, 10250000000000);
        assertEq(unwindAmount, 0);
        unwindAmount = traderBot.getUnwindInfo(false, 10200000000000);
        assertEq(unwindAmount, 0);
        unwindAmount = traderBot.getUnwindInfo(false, 10150000000000);
        assertEq(unwindAmount, 0);
        unwindAmount = traderBot.getUnwindInfo(false, 10100000000000);
        assertEq(unwindAmount, 0);
        // not unwind for new logic
        unwindAmount = traderBot.getUnwindInfo(false, 10000000000000);
        // console.log(unwindAmount, "unwindAmount for 10000000000000");
        assertGt(unwindAmount, 0);

        // should clear for 10000000000000
        newPrice = int256(99056 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);

        unwindAmount = traderBot.getUnwindInfo(false, 10000000000000);
        assertEq(unwindAmount, 0);
        
        (uint256 undo_assetB, uint256 undo_assetA) = traderBot.undoStat();
        (uint256 lower, uint256 upper) = traderBot.getLowerUpperBound();
        assertEq(lower, 9800000000000);
        assertEq(upper, 9950000000000);
        
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
            assertLt(gasUsed, 4_000_000, "Gas usage too high");
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
			quoter: PCSWAP_V3_QUOTER,
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

    function _displayBound(DoppiTrader traderBot, uint256 lowerBound, uint256 upperBound) internal view {
        
        if(lowerBound == 0 && upperBound == 0) {
            console.log("No active positions");
            return;
        }

        for (uint256 price = upperBound; price >= lowerBound; ) {
            // console.log(price, "price");
            bool isBuy = true;
            uint256 unwindBuy = traderBot.unWindBuy(price);
            uint256 unwindSell = traderBot.unWindSell(price);
            console.log(price, unwindBuy, unwindSell);
            price -= (500 * 1e8); 
        }

    }
}
