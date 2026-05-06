// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiOpportunity} from "../src/mainnet/DoppiOpportunity.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {DoppiOffer} from "../src/mainnet/DoppiOffer.sol";
import {IDoppiOffer} from "../src/Interface/IDoppiOffer.sol";
import {DoppiPoints} from "../src/mainnet/DoppiPoints.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {Swapper} from "../src/test/Swapper.sol";
import "../src/mainnet/DoppiCoreTypes.sol";
import {TestParamLib} from "../src/Library/TestParamLib.sol";
import "../src/mainnet/DoppiLiquidityTypes.sol";

contract DoppiOpportunityTest is Test {
    DoppiOpportunity doppiOpportunity;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiPoints doppiPoints;
    DoppiLiquidityRouter doppiRouter;
    BlackScholes blackScholes;
    DoppiOffer impliedVol;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    Swapper swapper;
    ConfigParam configLP;

    address owner = address(this);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address treasury = address(0x3);
    address mockForwarder = address(0x5);
    address trader = address(0x6);
    

    event OppPerformed(bool isBuy, uint256 price, uint256 amount, uint256 amountOut);
    event OppUnwindPerformed(bool isBuy, uint256 price, uint256 swappedAmount, uint256 amountOut, uint256 profit, address profitToken);
    
    function setUp() public {
        
        vm.warp(1735689600); 
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;

        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(int256(100_000 * 1e8), 8);

        blackScholes = new BlackScholes();
        impliedVol = new DoppiOffer(blackScholes, address(oracle), 500);
        impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);

        // Deploy Swapper that will act as both router and pool
        swapper = new Swapper(MockToken(usdt), MockToken(btc));
        swapper.setOracle(MockOracle(oracle));    
        doppiPoints = _deployDoppiPoints();
        doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(usdt), IERC20(btc));
        
        configLP = TestParamLib.get_configLP();
        configLP.chainLinkFeed = address(oracle);
        configLP.router = address(swapper);
        doppiLP.setConfig(configLP);
        doppiLP.approveRouter();
        // Create router and set entry points
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        
        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol, address(doppiPoints));
        doppiPoints.setDoppiCore(address(doppiCore), true);
        
        doppiLP.setDoppiCore(address(doppiCore));

        doppiOpportunity = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiCore.setOpportunityBot(address(doppiOpportunity), true);
        doppiCore.setTreasury(treasury, 1000);
        doppiOpportunity.setForwarderAddress(mockForwarder);
        
        // Mint tokens to a liquidity provider and properly deposit into LP
        address liquidityProvider = address(0x999);
        usdt.mint(liquidityProvider, 1_000_000 ether);
        btc.mint(liquidityProvider, 10 ether);

        usdt.mint(address(doppiLP), 1_000_000 ether);
        btc.mint(address(doppiLP), 10 ether);
        usdt.mint(user1, 200_000 ether);
        btc.mint(user1, 2 ether);
        usdt.mint(user2, 200_000 ether);
        btc.mint(user2, 2 ether);
    }

    function test_constructor() public view {
        assertEq(doppiOpportunity.owner(), owner);
        assertEq(address(doppiOpportunity.doppiLP()), address(doppiLP));
        assertEq(address(doppiOpportunity.doppiCore()), address(doppiCore));
    }

    function test_checkUpkeep_opportunityBuy() public {
        depositUSDT();
        assertEq(doppiCore.getBuyPositionCount(user1), 1);
        oracle.setPrice(int256(95_500  * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
    }

    function test_checkUpkeep_opportunitySell() public {
        depositBTC();
        assertEq(doppiCore.getSellPositionCount(user2), 1);
        oracle.setPrice(int256(104_000 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        assertTrue(upkeepNeeded);
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
    }

    function test_checkUpkeep_opportunityTakeSellProfit() public {
        
        vm.startPrank(doppiCore.owner());            
        doppiCore.setMaxSwap(200000 ether);
        vm.stopPrank();

        depositBTC();
        oracle.setPrice(int256(110_500  * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
        
        OpportunityOrders memory sell = doppiCore.getOpportunityOrders(false, 10050000000000);
        
        // unwind for profit opportunity
        oracle.setPrice(int256(98_500 * 1e8));
        (upkeepNeeded, performData) = doppiOpportunity.checkUpkeep("");
        
        vm.expectEmit(true, true, true, true);
        emit OppUnwindPerformed(
            false,
            98_500 * 1e8,
            109285605000000000000000,
            1097305139096954314,
            97305139096954314, // profit
            address(btc) // profit in asset A
        );
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
    }

    function test_checkUpkeep_opportunityTakeBuyProfit() public {
        depositUSDT();
        oracle.setPrice(int256(95_500 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);

        // unwind for profit opportunity
        oracle.setPrice(int256(100_500 * 1e8));
        (upkeepNeeded, performData) = doppiOpportunity.checkUpkeep("");
        vm.expectEmit(true, true, true, true);
        emit OppUnwindPerformed(
            true,
            100_500 * 1e8,
            517806282722513088,
            51467616963376963259625,
            1467616963376963259625,
            address(usdt) // profit in asset A
        );

        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
    }

    // Event emit test
    function test_OpportunityOppPerformed_EmitsEvent() public {
        
        depositUSDT();
        oracle.setPrice(int256(95_500 * 1e8));
        (, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        vm.expectEmit(true, true, true, true);
        emit OppPerformed(
            true,
            95_500 * 1e8,
            50_000 ether,
            517806282722513088
        );    
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
    }

    function test_OpportunityOppUnwindPerformed_EmitsEvent() public {
        
        depositUSDT();
        oracle.setPrice(int256(95_500 * 1e8));
        (, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);

        OpportunityOrders memory buy = doppiCore.getOpportunityOrders(true, 9950000000000);
        
        oracle.setPrice(int256(100_500 * 1e8));
        (, performData) = doppiOpportunity.checkUpkeep("");

        buy = doppiCore.getOpportunityOrders(true, 9950000000000);
        vm.expectEmit(true, true, true, true);
        emit OppUnwindPerformed(
            true,
            100_500 * 1e8,
            517806282722513088,
            51467616963376963259625,
            1467616963376963259625,
            address(usdt)
        );    

        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
    }

    // Gas Limit Test
    function test_Scenario_CheckUpKeep_DoppiOpportunity_GasMaxOnePrice_Sell() public {
        
        int256 startPrice = int256(9151519000000);
        oracle.setPrice(startPrice);
        
        uint256 depositLPAmount = 10_000_000 ether;
        uint256 depositBTCAmount = 10.0000 ether;

        usdt.mint(trader, depositLPAmount);
        btc.mint(trader, depositBTCAmount);
            
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        // doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        DualAssetOffer memory sellOffer = impliedVol.getOffer(false, 1, 1);
        uint256 depositBTC = 0.01 ether;
        // console.log(sellOffer.strikePrice, "sellOffer.strikePrice");
        for (uint256 i = 0; i < 1000; i++) {
            address l1 = address(uint160(0x110 + i));
            vm.startPrank(l1);
            btc.mint(l1, 1 ether);
            btc.approve(address(doppiCore), depositBTC);
            doppiCore.deposit_sell(DepositParams({
                amount: depositBTC,
                strikeZone: 1,
                strikePrice: sellOffer.strikePrice,
                numDays: 1,
                apr: sellOffer.apr,
                expiry: sellOffer.expiry
            }));
            vm.stopPrank();
        }

        startPrice = int256(9742000000000);
        oracle.setPrice(startPrice);
        
        _doppiOpportunityCheckUpkeep_performUpkeep();
        OpportunityOrders memory sell = doppiCore.getOpportunityOrders(false, 9250000000000);
        assertEq(sell.swappedAmount, 1026483268322726339);
        assertEq(sell.outAmount, 98900999999999999978675);
        // console.log(sell.swappedAmount, sell.outAmount, "sell.swappedAmount, sell.outAmount");

        // Not able to perform for now after changing swap logic with DEX
        // ************************************************************
        startPrice = int256(9142000000000);
        oracle.setPrice(startPrice);
        
        _doppiOpportunityCheckUpkeep_performUpkeep();
        sell = doppiCore.getOpportunityOrders(false, 9250000000000);
        // console.log(sell.swappedAmount, sell.outAmount, "sell.swappedAmount, sell.outAmount");
        assertEq(sell.swappedAmount, 0);
        assertEq(sell.outAmount, 0);

    }

    function test_Scenario_CheckUpKeep_DoppiOpportunity_GasMaxMultiplePrice() public {
        
        // int256 startPrice = int256(9151519000000);
        // oracle.setPrice(startPrice);
        
        uint256 depositLPAmount = 10_000_000 ether;
        uint256 depositBTCAmount = 10.0000 ether;

        usdt.mint(trader, depositLPAmount);
        btc.mint(trader, depositBTCAmount);
                  
            
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        vm.startPrank(doppiCore.owner());            
        doppiCore.setMaxSwap(100000 ether);
        vm.stopPrank();

        uint256 depositUSDT = 1000 ether;
        uint256 totalDeposit = 500;
        uint256 priceChanges = 50; // Change price 50 times during test
        uint256 depPerPrice = totalDeposit / priceChanges;

        uint256 currentPrice = (100_000 * 10**8) * (10100 / 10000);
        for (uint256 priceChange = 0; priceChange < priceChanges; priceChange++) {
            
            int256 startPrice = int256(currentPrice);
            oracle.setPrice(startPrice);
        
            DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 1);

            // Perform swaps at this price
            for (uint256 swapNum = 0; swapNum < depPerPrice; swapNum++) {
                address l1 = address(uint160(0x110 + priceChange));
                uint256 swapAmount = _generateRandomAmount(swapNum);
                vm.startPrank(l1);
                // deal(USDT, l1, swapAmount);  
                usdt.mint(l1, swapAmount);
        
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
        
        int256 newPrice = int256(90556 * 1e8);
        oracle.setPrice(newPrice);
        // _manipulateRealChainlink(newPrice, address(oracle));

        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();

        OpportunityOrders memory buy = doppiCore.getOpportunityOrders(true, 10100000000000);
        assertEq(buy.amount, 385000000000000000000000);
        assertEq(buy.swappedAmount, 35000000000000000000000);
        assertEq(buy.outAmount, 382253522682097266);
        
        buy = doppiCore.getOpportunityOrders(true, 10150000000000);
        assertEq(buy.amount, 165000000000000000000000);
        assertEq(buy.swappedAmount, 165000000000000000000000);
        assertEq(buy.outAmount, 1802052321215601394);

        newPrice = int256(102556 * 1e8);
        oracle.setPrice(newPrice);
        // _manipulateRealChainlink(newPrice, address(oracle));

        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();
        
        buy = doppiCore.getOpportunityOrders(true, 10100000000000);
        assertEq(buy.amount, 385000000000000000000000);
        assertEq(buy.swappedAmount, 0);
        assertEq(buy.outAmount, 0);
        // console.log(buy.amount, buy.swappedAmount, buy.outAmount);

        buy = doppiCore.getOpportunityOrders(true, 10150000000000);
        assertEq(buy.amount, 165000000000000000000000);
        assertEq(buy.swappedAmount, 0);
        assertEq(buy.outAmount, 0);
        
    }

    function test_Scenario_CheckUpKeep_DoppiOpportunity_GasMaxMultiplePrice_Sell() public {
        
        uint256 depositLPAmount = 10_000_000 ether;
        uint256 depositBTCAmount = 30.0000 ether;

        usdt.mint(trader, depositLPAmount);
        btc.mint(trader, depositBTCAmount);

        vm.startPrank(doppiCore.owner());            
        doppiCore.setMaxSwap(100000 ether);
        vm.stopPrank();

        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        // doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        uint256 depositBTC = 0.01 ether;
        uint256 totalDeposit = 500;
        uint256 priceChanges = 50; // Change price 50 times during test
        uint256 depPerPrice = totalDeposit / priceChanges;

        uint256 currentPrice = (100_000 * 10**8) * (10100 / 10000);
        for (uint256 priceChange = 0; priceChange < priceChanges; priceChange++) {
            
            int256 startPrice = int256(currentPrice);
            oracle.setPrice(startPrice);
                  
            DualAssetOffer memory sellOffer = impliedVol.getOffer(false, 1, 1);

            // Perform swaps at this price
            for (uint256 swapNum = 0; swapNum < depPerPrice; swapNum++) {
                address l1 = address(uint160(0x110 + priceChange));
                uint256 swapAmount = _generateRandomAmount(swapNum);
                uint256 amountinBTC = swapAmount * 1e8 / uint256(startPrice);
                vm.startPrank(l1);
                // deal(BTC, l1, amountinBTC);  
                btc.mint(l1, amountinBTC);
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
        
        int256 newPrice = int256(10242000000000);
        oracle.setPrice(newPrice);
        
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();

        OpportunityOrders memory sell = doppiCore.getOpportunityOrders(false, 9850000000000);
        assertEq(sell.swappedAmount, 2812255415357036449);
        assertEq(sell.outAmount, 284865736756814537436672);
        
        sell = doppiCore.getOpportunityOrders(false, 9900000000000);
        assertEq(sell.swappedAmount, 3356740024692983644);
        assertEq(sell.outAmount, 340018980855569066294013);

        newPrice = int256(93556 * 1e8);
        oracle.setPrice(newPrice);
        
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();
        
        sell = doppiCore.getOpportunityOrders(false, 9850000000000);
        assertEq(sell.swappedAmount, 0);
        assertEq(sell.outAmount, 0);
        
        sell = doppiCore.getOpportunityOrders(false, 9900000000000);
        assertEq(sell.swappedAmount, 0);
        assertEq(sell.outAmount, 0);
    }

    function test_Scenario_CheckUpKeep_DoppiOpportunity_GasMaxBuySell() public {
        
        uint256 depositLPAmount = 10_000_000 ether;
        uint256 depositBTCAmount = 30.0000 ether;

        usdt.mint(trader, depositLPAmount);
        btc.mint(trader, depositBTCAmount);
        
            
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

        uint256 currentPrice = (100_000 * 10**8) * (10100 / 10000);
        for (uint256 priceChange = 0; priceChange < priceChanges; priceChange++) {
            
            int256 startPrice = int256(currentPrice);
            oracle.setPrice(startPrice);

            // Perform swaps at this price
            for (uint256 swapNum = 0; swapNum < depPerPrice; swapNum++) {
                address l1 = address(uint160(0x110 + priceChange));
                uint256 swapAmount = _generateRandomAmount(swapNum);
                
                bool isBuy = swapNum % 2 == 0;
                if(!isBuy){
                    DualAssetOffer memory sellOffer = impliedVol.getOffer(false, 1, 1);
                    uint256 amountinBTC = swapAmount * 1e8 / uint256(startPrice);
                    vm.startPrank(l1);
                    btc.mint(l1, amountinBTC);
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
                    usdt.mint(l1, swapAmount);
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
        
        int256 newPrice = int256(90556 * 1e8);
        oracle.setPrice(newPrice);

        (uint256 lowerBound, uint256 upperBound) = doppiCore.getLowerUpperBound();
        console.log(lowerBound, upperBound, "lowerBound, upperBound");
        assertEq(lowerBound, 9700000000000);
        assertEq(upperBound, 10300000000000);

        _doppiOpportunityCheckUpkeep_performUpkeep();

        _displayBound(lowerBound, upperBound);
        
        OpportunityOrders memory buy = doppiCore.getOpportunityOrders(true, 10100000000000);
        console.log(buy.amount, buy.swappedAmount, buy.outAmount, "buy.amount, buy.swappedAmount, buy.outAmount");
        assertEq(buy.amount, 175000000000000000000000);
        assertEq(buy.swappedAmount, 25000000000000000000000);
        assertEq(buy.outAmount, 273038230487212333);
        
        buy = doppiCore.getOpportunityOrders(true, 10150000000000);
        assertEq(buy.amount, 75000000000000000000000);
        assertEq(buy.swappedAmount, 75000000000000000000000);
        assertEq(buy.outAmount, 819114691461636997);
        
        newPrice = int256(102556 * 1e8);
        oracle.setPrice(newPrice);
        
        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();

        buy = doppiCore.getOpportunityOrders(true, 10100000000000);
        assertEq(buy.swappedAmount, 0);
        assertEq(buy.outAmount, 0);
        buy = doppiCore.getOpportunityOrders(true, 10150000000000);
        assertEq(buy.swappedAmount, 0);
        assertEq(buy.outAmount, 0);

        OpportunityOrders memory sell = doppiCore.getOpportunityOrders(false, 9850000000000);
        assertEq(sell.swappedAmount, 1533957499285656245);
        assertEq(sell.outAmount, 155587636463928591999306);
        
        sell = doppiCore.getOpportunityOrders(false, 9900000000000);
        assertEq(sell.swappedAmount, 416196562885255257);
        assertEq(sell.outAmount, 42214363536071408152314);
        
        newPrice = int256(95556 * 1e8);
        oracle.setPrice(newPrice);

        _doppiOpportunityCheckUpkeep_performUpkeep();
        _doppiOpportunityCheckUpkeep_performUpkeep();

        sell = doppiCore.getOpportunityOrders(false, 9850000000000);
        assertEq(sell.swappedAmount, 0);
        assertEq(sell.outAmount, 0);
        
        sell = doppiCore.getOpportunityOrders(false, 9900000000000);
        assertEq(sell.swappedAmount, 0);
        assertEq(sell.outAmount, 0);

        buy = doppiCore.getOpportunityOrders(true, 10100000000000);
        assertEq(buy.swappedAmount, 125000000000000000000000);
        assertEq(buy.outAmount, 1293757063920632927);
        
        buy = doppiCore.getOpportunityOrders(true, 10150000000000);
        assertEq(buy.swappedAmount, 75000000000000000000000);
        assertEq(buy.outAmount, 776254238352379755);
        
        (lowerBound, upperBound) = doppiCore.getLowerUpperBound();
        assertEq(lowerBound, 9700000000000);
        assertEq(upperBound, 10300000000000);

        
    }

    function test_Scenario_CheckUpKeep_DoppiOpportunity_GasMaxOnePrice() public {
        
        int256 startPrice = int256(9151519000000);
        oracle.setPrice(startPrice);

        uint256 depositLPAmount = 10_000_000 ether;
        uint256 depositBTCAmount = 10.0000 ether;

        usdt.mint(trader, depositLPAmount);
        btc.mint(trader, depositBTCAmount);     
            
        vm.startPrank(trader);            
        usdt.approve(address(doppiRouter), depositLPAmount);        
        btc.approve(address(doppiRouter), depositBTCAmount);        
        doppiRouter.deposit(address(usdt), depositLPAmount);
        // doppiRouter.deposit(address(btc), depositBTCAmount);
        vm.stopPrank();

        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 1);
        uint256 depositUSDT = 1000 ether;
        for (uint256 i = 0; i < 1000; i++) {
            address l1 = address(uint160(0x110 + i));
            vm.startPrank(l1);
            usdt.mint(l1, 100_000 ether);
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
        }

        startPrice = int256(8542000000000);
        oracle.setPrice(startPrice);
        
        _doppiOpportunityCheckUpkeep_performUpkeep();

        OpportunityOrders memory buy = doppiCore.getOpportunityOrders(true, 9100000000000);
        assertEq(buy.amount, 1000000000000000000000000);
        assertEq(buy.swappedAmount, 100000000000000000000000);
        assertEq(buy.outAmount, 1157820182627019432);
        
        startPrice = int256(9942000000000);
        oracle.setPrice(startPrice);

        _doppiOpportunityCheckUpkeep_performUpkeep();

        buy = doppiCore.getOpportunityOrders(true, 9100000000000);
        assertEq(buy.amount, 1000000000000000000000000);
        assertEq(buy.swappedAmount, 13126938764525657328685);
        assertEq(buy.outAmount, 151986346376767974);
        
        _doppiOpportunityCheckUpkeep_performUpkeep();
        
        buy = doppiCore.getOpportunityOrders(true, 9100000000000);
        assertEq(buy.amount, 1000000000000000000000000);
        assertEq(buy.swappedAmount, 0);
        assertEq(buy.outAmount, 0);

    }

    // internal function
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

    function depositUSDT() internal {
        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 1);
        DepositParams memory params = DepositParams({
            amount: 50_000 ether,
            strikeZone: 1,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            expiry: buyOffer.expiry
        });

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), params.amount);
        doppiCore.deposit_buy(params);
        vm.stopPrank();
    }

    function depositBTC() internal {
        DualAssetOffer memory offer = impliedVol.getOffer(false, 1, 0);
        DepositParams memory params = DepositParams({
            amount: 1 ether,
            strikeZone: 0,
            strikePrice: offer.strikePrice,
            numDays: 1,
            apr: offer.apr,
            expiry: offer.expiry
        });

        vm.startPrank(user2);
        btc.approve(address(doppiCore), params.amount);
        doppiCore.deposit_sell(params);
        vm.stopPrank();
    }

    function _doppiOpportunityCheckUpkeep_performUpkeep() internal {
        
        uint256 gasBefore = gasleft();
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        uint256 gasUsed = gasBefore - gasleft();
        console.log(upkeepNeeded, gasUsed, "gasUsed in doppiOpportunity.checkUpkeep");
        assertLt(gasUsed, 500_000, "Gas usage too high");

        if(upkeepNeeded){
            vm.prank(mockForwarder);
            gasBefore = gasleft();
            doppiOpportunity.performUpkeep(performData);
            gasUsed = gasBefore - gasleft();
            console.log(gasUsed, "gasUsed in doppiOpportunity.performUpkeep");
            assertLt(gasUsed, 2_000_000, "Gas usage too high");
            vm.stopPrank();
        }
        
    }

    function _deployDoppiPoints() internal returns (DoppiPoints) {
        console.log("Deploying DoppiPoints...");
        DoppiPoints _doppiPoints = new DoppiPoints();
        console.log("DoppiPoints deployed at:", address(_doppiPoints));
        return _doppiPoints;
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
