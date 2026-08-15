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
import {IDoppiOpportunity} from "../../src/Interface/IDoppiOpportunity.sol";
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


contract DoppiCoreGasTest is Test {
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
        uint256 mainnetFork = vm.createFork("mainnet", 100250748); // Do not change the block number for the unit test
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
        doppiFactory = new DoppiTraderFactory(IERC20(USDT), IERC20(BTC), address(doppiCore), address(doppiLP), address(doppiRouter), address(impliedVol), address(doppiPoints));
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

    function test_Scenario_DoppiCore_CheckUpKeep_GasMaxBuy() public {
        IDoppiOpportunity opportunityStore = doppiCore.doppiOpportunity();
        
        uint256 depositLPAmount = 10_000_000 ether;
        uint256 depositBTCAmount = 10.0000 ether;

        deal(USDT, trader, 10_000_000 ether);            
            
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        vm.stopPrank();

        int256 startPrice = int256(9142000000000);
        _manipulateRealChainlink(startPrice, address(oracle));

        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 1);
        uint256 depositUSDT = 10_000 ether;
        uint256 max;
        uint256 min;

        for (uint256 i = 0; i < 1000; i++) {
            address l1 = address(uint160(0x110 + i));
            vm.startPrank(l1);
            deal(USDT, l1, 100_000 ether);  
            usdt.approve(address(doppiCore), depositUSDT);
            doppiCore.deposit_buy(DepositParams({
                amount: depositUSDT,
                strikeZone: 1,
                strikePrice: buyOffer.strikePrice,
                numDays: 1,
                apr: buyOffer.apr,
                expiry: buyOffer.expiry
            }));
            vm.stopPrank();
            if(max == 0) {
                max = buyOffer.strikePrice;
            }
            if(min == 0) {
                min = buyOffer.strikePrice;
            }
            if(max < buyOffer.strikePrice){
                max = buyOffer.strikePrice;
            }else if(min > buyOffer.strikePrice){
                min = buyOffer.strikePrice;
            }
            // console.log(l1);
            // Verify active
        }

        console.log(max, min, "max, min");

        // console.log(doppiCore.get_positions_buy(0x00000000000000000000000000000000000004f6).length);
        assertTrue(doppiCore.get_positions_buy(0x00000000000000000000000000000000000004f6).length > 0);
        
        int256 newPrice = int256(9152000000000);
        _manipulateRealChainlink(newPrice, address(oracle));

        (uint256 lowerBound, uint256 upperBound) = opportunityStore.getLowerUpperBound();
        assertEq(lowerBound, 9050000000000);
        assertEq(upperBound, 9050000000000);
        // 1 day fast forward and settle
        // 100 orders settled each time
        vm.warp(block.timestamp + 1 days + 1);
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();

        uint256 pos1day = doppiCore.getPositionLength(1);
        console.log("pos1day", pos1day);
        assertEq(pos1day, 0);
        // doppiCore.display();
        (lowerBound, upperBound) = opportunityStore.getLowerUpperBound();
        console.log(lowerBound, upperBound, "lowerBound, upperBound");
        assertEq(lowerBound, 0);
        assertEq(upperBound, 0);
    }

    function test_Scenario_DoppiCore_CheckUpKeep_GasMaxBuySell() public {
        IDoppiOpportunity opportunityStore = doppiCore.doppiOpportunity();
        
        uint256 depositLPAmount = 100_000_000 ether;
        uint256 depositBTCAmount = 30.0000 ether;

        deal(USDT, trader, depositLPAmount);            
        deal(BTC, trader, depositBTCAmount);            
            
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        uint256 depositBTC = 0.01 ether;
        uint256 totalDeposit = 500;
        uint256 priceChanges = 50; // Change price 50 times during test
        uint256 depPerPrice = totalDeposit / priceChanges;

        uint256 max;
        uint256 min;
        uint256 currentPrice = (100_000 * 10**8) * (10100 / 10000);
        for (uint256 priceChange = 0; priceChange < priceChanges; priceChange++) {
            
            int256 startPrice = int256(currentPrice);
            _manipulateRealChainlink(startPrice, address(oracle));            
            
            // Perform swaps at this price
            for (uint256 swapNum = 0; swapNum < depPerPrice; swapNum++) {
                address l1 = address(uint160(0x110 + priceChange));
                uint256 swapAmount = _generateRandomAmount(swapNum);
                
                bool isBuy = swapNum % 2 == 0;
                if(!isBuy){
                    DualAssetOffer memory sellOffer = impliedVol.getOffer(false, 1, 1);
                    uint256 amountinBTC = swapAmount * 1e8 / uint256(startPrice);
                    vm.startPrank(l1);
                    deal(BTC, l1, amountinBTC);  
                    btc.approve(address(doppiCore), amountinBTC);
                    doppiCore.deposit_sell(DepositParams({
                        amount: amountinBTC,
                        strikeZone: 1,
                        strikePrice: sellOffer.strikePrice,
                        numDays: 1,
                        apr: sellOffer.apr,
                        expiry: sellOffer.expiry
                    }));
                    vm.stopPrank(); 
                    if(max == 0) {
                        max = sellOffer.strikePrice;
                    }
                    if(min == 0) {
                        min = sellOffer.strikePrice;
                    }
                    if(max < sellOffer.strikePrice){
                        max = sellOffer.strikePrice;
                    }else if(min > sellOffer.strikePrice){
                        min = sellOffer.strikePrice;
                    }
                }else{

                    DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 1);
                    vm.startPrank(l1);
                    deal(USDT, l1, swapAmount);  
                    usdt.approve(address(doppiCore), swapAmount);
                    doppiCore.deposit_buy(DepositParams({
                        amount: swapAmount,
                        strikeZone: 1,
                        strikePrice: buyOffer.strikePrice,
                        numDays: 1,
                        apr: buyOffer.apr,
                        expiry: buyOffer.expiry
                    }));
                    vm.stopPrank();
                    if(max == 0) {
                        max = buyOffer.strikePrice;
                    }
                    if(min == 0) {
                        min = buyOffer.strikePrice;
                    }
                    if(max < buyOffer.strikePrice){
                        max = buyOffer.strikePrice;
                    }else if(min > buyOffer.strikePrice){
                        min = buyOffer.strikePrice;
                    }
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
        
        console.log(max, min, "max, min");
        int256 newPrice = int256(90556 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        // 1 day fast forward and settle
        (uint256 lowerBound, uint256 upperBound) = opportunityStore.getLowerUpperBound();
        assertEq(lowerBound, 9700000000000);
        assertEq(upperBound, 10300000000000);

        vm.warp(block.timestamp + 1 days + 1);
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        (lowerBound, upperBound) = opportunityStore.getLowerUpperBound();
        console.log(lowerBound, upperBound);
        assertEq(lowerBound, 0);
        assertEq(upperBound, 0);
        
    }

    function test_Scenario_DoppiCore_CheckUpKeep_GasMaxBuySell_1Day3Days() public {
        IDoppiOpportunity opportunityStore = doppiCore.doppiOpportunity();
        
        uint256 depositLPAmount = 100_000_000 ether;
        uint256 depositBTCAmount = 30.0000 ether;

        deal(USDT, trader, depositLPAmount);            
        deal(BTC, trader, depositBTCAmount);            
            
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        uint256 depositBTC = 0.01 ether;
        uint256 totalDeposit = 200;
        uint256 priceChanges = 50; // Change price 50 times during test
        uint256 depPerPrice = totalDeposit / priceChanges;

        uint256 currentPrice = (100_000 * 10**8) * (10100 / 10000);
        uint256 total1day;
        uint256 total3day;
        uint256 max;
        uint256 min;
        
        for (uint256 priceChange = 0; priceChange < priceChanges; priceChange++) {
            
            int256 startPrice = int256(currentPrice);
            _manipulateRealChainlink(startPrice, address(oracle));            
            
            // Perform swaps at this price
            for (uint256 swapNum = 0; swapNum < depPerPrice; swapNum++) {
                address l1 = address(uint160(0x110 + priceChange));
                uint256 swapAmount = _generateRandomAmount(swapNum);
                
                bool isBuy = swapNum % 2 == 0;
                uint8 day = swapNum % 2 != 0 ? 1 : 3;
                // console.log(priceChange, day, "day");
                day == 1 ? total1day++ : total3day++;
                
                if(!isBuy){
                    DualAssetOffer memory sellOffer = impliedVol.getOffer(false, day, 1);
                    uint256 amountinBTC = swapAmount * 1e8 / uint256(startPrice);
                    vm.startPrank(l1);
                    deal(BTC, l1, amountinBTC);  
                    btc.approve(address(doppiCore), amountinBTC);
                    // console.log(sellOffer.strikePrice, isBuy, day);
                    if(max == 0) {
                        max = sellOffer.strikePrice;
                    }
                    if(min == 0) {
                        min = sellOffer.strikePrice;
                    }
                    if(max < sellOffer.strikePrice){
                        max = sellOffer.strikePrice;
                    }else if(min > sellOffer.strikePrice){
                        min = sellOffer.strikePrice;
                    }

                    doppiCore.deposit_sell(DepositParams({
                        amount: amountinBTC,
                        strikeZone: 1,
                        strikePrice: sellOffer.strikePrice,
                        numDays: day,
                        apr: sellOffer.apr,
                        expiry: sellOffer.expiry
                    }));
                    vm.stopPrank(); 
                }else{

                    DualAssetOffer memory buyOffer = impliedVol.getOffer(true, day, 1);
                    vm.startPrank(l1);
                    deal(USDT, l1, swapAmount);  
                    usdt.approve(address(doppiCore), swapAmount);
                    // console.log(buyOffer.strikePrice, isBuy, day);
                    if(max == 0) {
                        max = buyOffer.strikePrice;
                    }
                    if(min == 0) {
                        min = buyOffer.strikePrice;
                    }
                    if(max < buyOffer.strikePrice){
                        max = buyOffer.strikePrice;
                    }else if(min > buyOffer.strikePrice){
                        min = buyOffer.strikePrice;
                    }
                    doppiCore.deposit_buy(DepositParams({
                        amount: swapAmount,
                        strikeZone: 1,
                        strikePrice: buyOffer.strikePrice,
                        numDays: day,
                        apr: buyOffer.apr,
                        expiry: buyOffer.expiry
                    }));
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
        console.log(min, max, "min and max strike price");
        console.log(total1day, total3day, "total1day and total3day");   
        uint256 pos1day = doppiCore.getPositionLength(1);
        uint256 pos3day = doppiCore.getPositionLength(3);
        // console.log(pos1day, "pos1day");
        // console.log(pos3day, "pos3day");
        assertEq(pos1day, 100); 
        assertEq(pos3day, 100); 
        
        int256 newPrice = int256(90556 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));
        // 1 day fast forward and settle
        (uint256 lowerBound, uint256 upperBound) = opportunityStore.getLowerUpperBound();
        _displayBound(lowerBound, upperBound);
        assertEq(lowerBound, 9700000000000);
        assertEq(upperBound, 10300000000000);

        vm.warp(block.timestamp + 1 days + 1);
        uint64 endPosId = doppiCore.getReadyAllPositions(1);
        uint64 endPosId2 = doppiCore.getReadyAllPositions(3);
        assertEq(endPosId, 100);
        assertEq(endPosId2, 0); // no yet ready to settle for 3 days position

        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();

        vm.warp(block.timestamp + 1 days + 1);
        endPosId = doppiCore.getReadyAllPositions(1);
        endPosId2 = doppiCore.getReadyAllPositions(3);
        
        // console.log(readyPositionId.length, "readyPositionId.length");
        assertEq(endPosId, 0); // 1 days position already settled
        assertEq(endPosId2, 0); // no yet ready to settle for 3 days position

        _doppiCoreCheckUpkeep_performUpkeep();

        (lowerBound, upperBound) = opportunityStore.getLowerUpperBound();
        _displayBound(lowerBound, upperBound);
        
        
        vm.warp(block.timestamp + 2 days + 1);
        endPosId2 = doppiCore.getReadyAllPositions(3);
        assertEq(endPosId2, 100);
        
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();
        _doppiCoreCheckUpkeep_performUpkeep();

        endPosId = doppiCore.getReadyAllPositions(1);
        endPosId2 = doppiCore.getReadyAllPositions(3);
        assertEq(endPosId, 0);    // all positions settled
        assertEq(endPosId2, 0); // all positions settled
        pos1day = doppiCore.getPositionLength(1);
        pos3day = doppiCore.getPositionLength(3);
        
        assertEq(pos1day, 0); 
        assertEq(pos3day, 0); 
        
        (lowerBound, upperBound) = opportunityStore.getLowerUpperBound();
        
        _displayBound(lowerBound, upperBound);
        
        assertEq(lowerBound, 0);
        assertEq(upperBound, 0);
        
    }

    function test_Scenario_DoppiCore_SettleManual() public {
        IDoppiOpportunity opportunityStore = doppiCore.doppiOpportunity();
        
        vm.startPrank(doppiCore.owner());
        doppiCore.setUpkeeps_per_check(5);
        vm.stopPrank();

        uint256 depositLPAmount = 100_000_000 ether;
        uint256 depositBTCAmount = 30.0000 ether;

        deal(USDT, trader, depositLPAmount);            
        deal(BTC, trader, depositBTCAmount);            
            
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        uint256 depositBTC = 0.01 ether;
        uint256 totalDeposit = 10;
        uint256 priceChanges = 5; // Change price 5 times during test
        uint256 depPerPrice = totalDeposit / priceChanges;

        uint256 currentPrice = (100_000 * 10**8) * (10100 / 10000);
        for (uint256 priceChange = 0; priceChange < priceChanges; priceChange++) {
            
            int256 startPrice = int256(currentPrice);
            _manipulateRealChainlink(startPrice, address(oracle));            
            
            // Perform swaps at this price
            for (uint256 swapNum = 0; swapNum < depPerPrice; swapNum++) {
                address l1 = address(uint160(0x110 + priceChange));
                uint256 swapAmount = _generateRandomAmount(swapNum);
                
                bool isBuy = swapNum % 2 == 0;
                if(!isBuy){
                    DualAssetOffer memory sellOffer = impliedVol.getOffer(false, 1, 1);
                    uint256 amountinBTC = swapAmount * 1e8 / uint256(startPrice);
                    vm.startPrank(l1);
                    deal(BTC, l1, amountinBTC);  
                    btc.approve(address(doppiCore), amountinBTC);
                    doppiCore.deposit_sell(DepositParams({
                        amount: amountinBTC,
                        strikeZone: 1,
                        strikePrice: sellOffer.strikePrice,
                        numDays: 1,
                        apr: sellOffer.apr,
                        expiry: sellOffer.expiry
                    }));
                    vm.stopPrank(); 
                }else{

                    DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 1);
                    vm.startPrank(l1);
                    deal(USDT, l1, swapAmount);  
                    usdt.approve(address(doppiCore), swapAmount);
                    doppiCore.deposit_buy(DepositParams({
                        amount: swapAmount,
                        strikeZone: 1,
                        strikePrice: buyOffer.strikePrice,
                        numDays: 1,
                        apr: buyOffer.apr,
                        expiry: buyOffer.expiry
                    }));
                    vm.stopPrank();
                }
            }

            // Generate random price between 100000 and 120000 
            if(priceChange > 2 && priceChange <= 5){
                currentPrice = currentPrice * 9950 / 10000;
            }else if(priceChange > 15 && priceChange <= 20){
                currentPrice = currentPrice * 10050 / 10000;
            }else if(priceChange > 20 && priceChange <= 25){
                currentPrice = currentPrice * 9910 / 10000;
            }else{
                currentPrice = currentPrice * 10010 / 10000;
            }
        }
        
        int256 newPrice = int256(90556 * 1e8);
        _manipulateRealChainlink(newPrice, address(oracle));

        
        (uint256 lowerBound, uint256 upperBound) = opportunityStore.getLowerUpperBound();
        _displayBound(lowerBound, upperBound);

        assertEq(lowerBound, 10000000000000);
        assertEq(upperBound, 10200000000000);

        // total 10 orders
        uint64 totalOrders = doppiCore.getPositionLength(1);
        assertEq(totalOrders, 10);
        uint64 endPosId = doppiCore.getReadyAllPositions(1);
        assertEq(endPosId, 0);

        vm.warp(block.timestamp + 1 days + 1);
        endPosId = doppiCore.getReadyAllPositions(1);
        assertEq(endPosId, 5); // first 5 (max 5 order each upkeep) orders ready to settle

        _doppiCoreCheckUpkeep_performUpkeep();

        // remaining 5 settle single middle posId, 7
        vm.startPrank(doppiCore.owner());
        doppiCore.settleOrders(1);
        vm.stopPrank();

        _doppiCoreCheckUpkeep_performUpkeep();

        totalOrders = doppiCore.getPositionLength(1);
        assertEq(totalOrders, 0);
        assertEq(doppiCore.nextPositionId(1), doppiCore.nextProcessId(1));

        (lowerBound, upperBound) = opportunityStore.getLowerUpperBound();
        assertEq(lowerBound, 0);
        assertEq(upperBound, 0);
        
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
        _doppiLP.lockEntryPoints();
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

    function _displayBound(uint256 lowerBound, uint256 upperBound) internal view {
        IDoppiOpportunity opportunityStore = doppiCore.doppiOpportunity();
        
        if(lowerBound == 0 && upperBound == 0) {
            console.log("No active positions");
            return;
        }

        for (uint256 price = upperBound; price >= lowerBound; ) {
            // console.log(price, "price");
            bool isBuy = true;
            OpportunityOrders memory order = opportunityStore.getBuyOpportunity(price);
            uint256 amount = order.amount;
            uint256 swappedAmount = order.swappedAmount;
            uint256 outAmount = order.outAmount;
            
            if(amount == 0){
                isBuy = false;
                order = opportunityStore.getSellOpportunity(price);
                amount = order.amount;
                swappedAmount = order.swappedAmount;
                outAmount = order.outAmount;
            }
            console.log(isBuy, price, amount, swappedAmount);
            price -= (500 * 1e8); 
        }

    }

    
}
