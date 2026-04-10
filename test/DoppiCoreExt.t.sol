// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {DoppiTraderFactory} from "../src/mainnet/DoppiTraderFactory.sol";
import {DoppiTrader} from "../src/mainnet/DoppiTrader.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {DoppiOffer} from "../src/mainnet/DoppiOffer.sol";
import {IDoppiOffer} from "../src/Interface/IDoppiOffer.sol";
import {DoppiPoints} from "../src/mainnet/DoppiPoints.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
// import "forge-std/console.sol";
import {Swapper} from "../src/test/Swapper.sol";
import "../src/mainnet/DoppiCoreTypes.sol";
import {TestParamLib} from "../src/Library/TestParamLib.sol";
import "../src/mainnet/DoppiLiquidityTypes.sol";


contract DoppiCoreExtTest is Test {
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    DoppiTraderFactory traderFactory;
    BlackScholes blackScholes;
    DoppiOffer impliedVol;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    Swapper swapper;
    DoppiPoints doppiPoints;
    ConfigParam configLP;

    address owner = address(this);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address treasury = address(0x3);
    address admin = address(0x4);
    address mockForwarder = address(0x5);

    uint256 constant INITIAL_PRICE = 100_000 * 1e8;

    event Deposited(address indexed trader, uint64 positionId, address asset, uint256 amount, uint256 interest, uint256 strikePrice, uint32 apr, uint8 numDays);
    event Settled(address indexed trader, uint64 positionId, bool striked, uint256 strikePrice, uint256 marketPrice, bool isProfit, uint256 profitLoss, uint256 payout, uint256 interest, address payoutToken, address interestToken);
    
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
        oracle = new MockOracle(int256(INITIAL_PRICE), 8);

        blackScholes = new BlackScholes();
        impliedVol = new DoppiOffer(blackScholes, address(oracle), 500);
        impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);

        doppiPoints = new DoppiPoints();

        // Deploy Swapper that will act as both router and pool
        swapper = new Swapper(MockToken(usdt), MockToken(btc));
        swapper.setOracle(MockOracle(oracle));  
        
        configLP = TestParamLib.get_configLP();
        configLP.chainLinkFeed = address(oracle);
        configLP.quoter = address(swapper);
        configLP.router = address(swapper);
        
        doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(usdt), IERC20(btc));

        doppiLP.setConfig(configLP);
        doppiLP.approveRouter();
                
        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol, address(doppiPoints));
        doppiPoints.setDoppiCore(address(doppiCore), true);

        doppiLP.setDoppiCore(address(doppiCore));

        // Create router and set entry points
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        
        traderFactory =
            new DoppiTraderFactory(IERC20(usdt), IERC20(btc), address(doppiCore), address(doppiLP), address(doppiRouter));

        doppiCore.setDoppiTraderFactory(traderFactory);
        doppiCore.setOpportunityBot(admin, true);
        doppiCore.setForwarderAddress(mockForwarder);
        doppiCore.setTreasury(treasury, 1000);
        

        // Mint tokens
        usdt.mint(user1, 200_000 ether);
        btc.mint(user1, 2 ether);
        usdt.mint(user2, 200_000 ether);
        btc.mint(user2, 2 ether);
        usdt.mint(admin, 1_000_000 ether);
        btc.mint(admin, 20 ether);
        
        vm.startPrank(admin);
        usdt.approve(address(doppiRouter), 100_000 ether);
        btc.approve(address(doppiRouter), 1 ether);
        doppiRouter.deposit(address(usdt), 100_000 ether);
        doppiRouter.deposit(address(btc), 1 ether);
        vm.stopPrank();
    }

    // Event emit test
    function test_DepositBuy_EmitsDepositedEvent() public {
        
        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 1);
        uint256 APR_BASIS_POINTS = 31399; // 313.99% APR in basis points
        uint256 PRINCIPAL = 50_000 ether; // 50,000 USDT
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;

        uint256 usdtInterestReceived = APR_BASIS_POINTS * PRINCIPAL / BASIS_POINTS_DENOMINATOR / DAYS_IN_YEAR;
        
        vm.startPrank(user1);
        usdt.approve(address(doppiCore), PRINCIPAL);
        
        DepositParams memory params = DepositParams({
            amount: PRINCIPAL,
            strikeZone: 1,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            expiry: buyOffer.expiry
        });

        // Expect Deposited event
        vm.expectEmit(true, true, true, true);
        emit Deposited(
            user1,
            1, // positionId
            address(usdt),
            PRINCIPAL,
            usdtInterestReceived,
            buyOffer.strikePrice, // strikePrice
            buyOffer.apr, // apr
            1 // numDays
        );    
        // Execute deposit
        doppiCore.deposit_buy(params);

        vm.stopPrank();
    }

    function test_DepositSell_EmitsDepositedEvent() public {
        
        DualAssetOffer memory sellOffer = impliedVol.getOffer(false, 1, 0);

        uint256 APR_BASIS_POINTS = 35700;
        uint256 PRINCIPAL = 0.5 ether; 
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;

        uint256 btcInterestReceived = APR_BASIS_POINTS * PRINCIPAL / BASIS_POINTS_DENOMINATOR / DAYS_IN_YEAR;

        vm.startPrank(user1);
        btc.approve(address(doppiCore), PRINCIPAL);
        
        DepositParams memory params = DepositParams({
            amount: PRINCIPAL,
            strikeZone: 0,
            strikePrice: sellOffer.strikePrice,
            numDays: 1,
            apr: sellOffer.apr,
            expiry: sellOffer.expiry
        });

        // Expect Deposited event
        vm.expectEmit(true, true, true, true);
        emit Deposited(
            user1,
            1, // positionId
            address(btc),
            PRINCIPAL,
            btcInterestReceived,
            sellOffer.strikePrice, // strikePrice
            sellOffer.apr, // apr
            1 // numDays
        );    
        // Execute deposit
        doppiCore.deposit_sell(params);

        vm.stopPrank();
    }

    function test_SettleBuyStrikedNoTraded_EmitsSettledEvent() public {
        
        DualAssetOffer memory buyOffer = _depositUSDT();
        
        uint256 APR_BASIS_POINTS = 31399; // 313.99% APR in basis points
        uint256 PRINCIPAL = 50_000 ether; // 50,000 USDT
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;

        uint256 usdtInterestReceived = APR_BASIS_POINTS * PRINCIPAL / BASIS_POINTS_DENOMINATOR / DAYS_IN_YEAR;
        uint256 expectedPayout = PRINCIPAL * 1e8 / buyOffer.strikePrice; // expected payout

        // Fast forward to expiry
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE) - 2000 * 1e8); // Price stays same, above strike

        vm.prank(owner);
        // Expect Settled event for in-the-money position
        vm.expectEmit(true, true, true, true);

        emit Settled(
            user1,
            1, // positionId
            true, // striked
            99500 * 1e8, // strike price
            INITIAL_PRICE - 2000 * 1e8, // market price
            false, // isProfit (varies based on implementation)
            0, // profitLoss
            expectedPayout, // expected payout
            usdtInterestReceived, // interest
            address(btc), // payoutToken
            address(usdt)  // interestToken
        );
        
        // Execute settlement
        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions(1);
        doppiCore.settleOrders(readyPositions, settleAccu);
    }

    function test_SettleSellStrikedNoTraded_EmitsSettledEvent() public {
        
        DualAssetOffer memory sellOffer = _depositBTC();
        
        uint256 APR_BASIS_POINTS = 35700;
        uint256 PRINCIPAL = 0.5 ether; 
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;

        uint256 btcInterestReceived = APR_BASIS_POINTS * PRINCIPAL / BASIS_POINTS_DENOMINATOR / DAYS_IN_YEAR;
        uint256 expectedPayout = PRINCIPAL * sellOffer.strikePrice / 1e8;

        // Fast forward to expiry
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE) + 2000 * 1e8); // Price stays same, above strike

        vm.prank(owner);
        // Expect Settled event for in-the-money position
        vm.expectEmit(true, true, true, true);
        emit Settled(
            user1,
            1, // positionId
            true, // striked
            100500 * 1e8, // strike price
            INITIAL_PRICE + 2000 * 1e8, // market price
            false, // isProfit (varies based on implementation)
            0, // profitLoss
            expectedPayout, // expected payout
            btcInterestReceived, // interest
            address(usdt), // payoutToken
            address(btc)  // interestToken
        );
        
        // Execute settlement
        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions(1);
        doppiCore.settleOrders(readyPositions, settleAccu);
    }

    function test_SettleBuyNoStriked_EmitsSettledEvent() public {
        
        _depositUSDT();
        
        uint256 APR_BASIS_POINTS = 31399; // 313.99% APR in basis points
        uint256 PRINCIPAL = 50_000 ether; // 50,000 USDT
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;

        uint256 usdtInterestReceived = APR_BASIS_POINTS * PRINCIPAL / BASIS_POINTS_DENOMINATOR / DAYS_IN_YEAR;
        // uint256 expectedPayout = PRINCIPAL * 1e8 / buyOffer.strikePrice; // expected payout

        // Fast forward to expiry
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE) + 1 * 1e8); // price greater than strike price. No strike No traded

        vm.prank(owner);
        // Expect Settled event for in-the-money position
        vm.expectEmit(true, true, true, true);
        emit Settled(
            user1,
            1, // positionId
            false, // striked
            99500 * 1e8, // strike price
            INITIAL_PRICE + 1 * 1e8, // market price
            false, // isProfit (varies based on implementation)
            0, // profitLoss
            0, // expected payout
            usdtInterestReceived, // interest
            address(usdt), // payoutToken
            address(usdt)  // interestToken
        );
        
        // Execute settlement
        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions(1);
        doppiCore.settleOrders(readyPositions, settleAccu);
    }

    function test_SettleSellNoStriked_EmitsSettledEvent() public {
        
        _depositBTC();
        
        uint256 APR_BASIS_POINTS = 35700;
        uint256 PRINCIPAL = 0.5 ether; 
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;

        uint256 btcInterestReceived = APR_BASIS_POINTS * PRINCIPAL / BASIS_POINTS_DENOMINATOR / DAYS_IN_YEAR;
        // uint256 expectedPayout = PRINCIPAL * sellOffer.strikePrice / 1e8;

        // Fast forward to expiry
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE)); // No Strike

        vm.prank(owner);
        // Expect Settled event for in-the-money position
        vm.expectEmit(true, true, true, true);
        emit Settled(
            user1,
            1, // positionId
            false, // striked
            100500 * 1e8, // strike price
            INITIAL_PRICE, // market price
            false, // isProfit (varies based on implementation)
            0, // profitLoss
            0, // expected payout
            btcInterestReceived, // interest
            address(btc), // payoutToken
            address(btc)  // interestToken
        );
        
        // Execute settlement
        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions(1);
        doppiCore.settleOrders(readyPositions, settleAccu);
    }

    function test_SettleSellStrikedTraded_EmitsSettledEvent_NotEnoughOutAmountCase() public {
        
        DualAssetOffer memory sellOffer = _depositBTC();
        uint256 APR_BASIS_POINTS = 35700;
        uint256 PRINCIPAL = 0.5 ether; 
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;


        // ***** START perform opportunityBot.checkUpkeep
        vm.startPrank(admin);
        oracle.setPrice(int256(101_600 * 1e8));
        uint256[] memory targetprices = new uint256[](1);
        uint256[] memory targetPricesUnwind = new uint256[](0);
        uint256 totalAmountUnwind = 0;
        targetprices[0] = 100_500 * 1e8;
        uint256 totalAmount = PRINCIPAL;
        doppiCore.performOpportunity(targetprices, targetPricesUnwind, totalAmount, totalAmountUnwind, false);
        vm.stopPrank();

        OpportunityOrders memory opp = doppiCore.getOpportunityOrders(false, sellOffer.strikePrice);
        console.log(opp.amount, opp.outAmount, opp.swappedAmount);
        
        uint256 btcInterestReceived = APR_BASIS_POINTS * PRINCIPAL / BASIS_POINTS_DENOMINATOR / DAYS_IN_YEAR;
        uint256 expectedPayout = PRINCIPAL * sellOffer.strikePrice / 1e8;

        // Fast forward to expiry
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(101_900 * 1e8)); // settled sell + traded + strike

        vm.prank(owner);
        // Expect Settled event for in-the-money position
        vm.expectEmit(true, true, true, true);
        emit Settled(
            user1,
            1, // positionId
            true, // striked
            100500 * 1e8, // strike price
            101900 * 1e8, // market price
            false, // isProfit (varies based on implementation)
            0, // profitLoss
            expectedPayout, // expected payout
            btcInterestReceived, // interest
            address(usdt), // payoutToken
            address(btc)  // interestToken
        );
        
        // Execute settlement
        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions(1);
        doppiCore.settleOrders(readyPositions, settleAccu);
    }

    function test_SettleBuyStrikedTraded_EmitsSettledEvent() public {
        
        DualAssetOffer memory buyOffer = _depositUSDT();
        uint256 APR_BASIS_POINTS = 31399; // 313.99% APR in basis points
        uint256 PRINCIPAL = 50_000 ether; // 50,000 USDT
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;


        // ***** START perform opportunityBot.checkUpkeep
        vm.startPrank(admin);
        oracle.setPrice(int256(98_000 * 1e8));
        uint256[] memory targetprices = new uint256[](1);
        uint256[] memory targetPricesUnwind = new uint256[](0);
        uint256 totalAmount = PRINCIPAL;
        uint256 totalAmountUnwind = 0;
        targetprices[0] = 99_500 * 1e8;
        doppiCore.performOpportunity(targetprices, targetPricesUnwind, totalAmount, totalAmountUnwind, true);
        vm.stopPrank();

        uint256 usdtInterestReceived = APR_BASIS_POINTS * PRINCIPAL / BASIS_POINTS_DENOMINATOR / DAYS_IN_YEAR;
        uint256 expectedPayout = PRINCIPAL * 1e8 / buyOffer.strikePrice; // expected payout

        // Fast forward to expiry
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE) - 1000 * 1e8);

        // Expect Settled event for in-the-money position
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit Settled(
            user1,
            1, // positionId
            true, // striked
            99500 * 1e8, // strike price
            INITIAL_PRICE - 1000 * 1e8, // market price
            true, // isProfit (varies based on implementation)
            2084375961439852, // profitLoss
            expectedPayout, // expected payout
            usdtInterestReceived, // interest
            address(btc), // payoutToken
            address(usdt)  // interestToken
        );
        
        // Execute settlement
        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions(1);
        doppiCore.settleOrders(readyPositions, settleAccu);
    }

    
    function test_settle_recordPoints() public {

        // Deposit a buy position
        _depositUSDT();
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE)); // Price stays same, above strike

        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions(1);
        vm.startPrank(owner);
        doppiCore.settleOrders(readyPositions, settleAccu);

        (,, uint256 currentMonthPoint) = doppiPoints.getAllPointData(user1);
        assertEq(currentMonthPoint, 50000 ether);
        
        _updateIV();

        // Deposit a sell position
        _depositBTC();
        vm.warp(block.timestamp + 2 days + 1);
        oracle.setPrice(int256(99_000 * 1e8)); // Price stays same, above strike
        (readyPositions, settleAccu) = doppiCore.getReadyAllPositions(1);
        vm.startPrank(owner);
        doppiCore.settleOrders(readyPositions, settleAccu);

        (,, currentMonthPoint) = doppiPoints.getAllPointData(user1);
        uint256 sellOrderPoints = 0.5 ether * INITIAL_PRICE / 1e8;
        assertEq(currentMonthPoint, 50000 ether + sellOrderPoints);

    }

    function test_emergencyWithdraw() public {

        // Deposit a buy position
        _depositUSDT();
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE)); // Price stays same, above strike

        _updateIV();

        // Deposit a sell position
        _depositBTC();
        
        vm.startPrank(owner);
        doppiCore.setPause();
        doppiCore.setEmergencyMode(true);
        vm.stopPrank();

        uint256 start_usdtbal = usdt.balanceOf(user1);
        uint256 start_btcbal = btc.balanceOf(user1);
        // emergency withdraw buy and sell
        vm.startPrank(user1);
        doppiCore.emergencyWithdraw();
        vm.stopPrank();

        uint256 pos1day = doppiCore.getPositionLength(1);
        console.log(pos1day);
        uint256 countB = doppiCore.getBuyPositionCount(user1);
        console.log(countB, "count buy");
        uint256 count = doppiCore.getSellPositionCount(user1);
        console.log(count, "count sell");

        assertEq(doppiCore.getBuyPositionCount(user1), 0);
        assertEq(doppiCore.getSellPositionCount(user1), 0);

        uint256 end_usdtbal = usdt.balanceOf(user1);
        uint256 end_btcbal = btc.balanceOf(user1);
        
        assertEq(end_usdtbal, start_usdtbal + 50_000 ether);
        assertEq(end_btcbal, start_btcbal + 0.5 ether);
        
    }

    function test_maxDepositBuy() public {

        configLP.maxDepositPercentage = 10000;
        doppiLP.setConfig(configLP);
        // Deposit a buy position
        
        // 1st order 50k
        DualAssetOffer memory buyOffer = _depositUSDT();
        // 2nd order 50k
        _depositUSDT();
        // 3rd order 50k
        _depositUSDT();
        _depositUSDT();
        
        // 4th order 50k, should fail
        DepositParams memory params = DepositParams({
            amount: 50_000 ether,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            expiry: buyOffer.expiry
        });
        vm.startPrank(user1);
        usdt.approve(address(doppiCore), params.amount);
        vm.expectRevert("ExceedsPoolCap()");
        doppiCore.deposit_buy(params);

        vm.stopPrank();

    }

    function test_maxDepositSell() public {

        configLP.maxDepositPercentage = 10000;
        doppiLP.setConfig(configLP);
        
        // 1st order 0.5
        DualAssetOffer memory sellOffer = _depositBTC();
        // 2nd order 0.5
        _depositBTC();
        // 3rd order 0.5
        _depositBTC();
        _depositBTC();
        
        // 4th order 0.5, should fail
        DepositParams memory params = DepositParams({
            amount: 0.5 ether,
            strikeZone: 0,
            strikePrice: sellOffer.strikePrice,
            numDays: 1,
            apr: sellOffer.apr,
            expiry: sellOffer.expiry
        });
        vm.startPrank(user1);
        usdt.approve(address(doppiCore), params.amount);
        vm.expectRevert("ExceedsPoolCap()");
        doppiCore.deposit_sell(params);

        vm.stopPrank();

    }

    function _depositBTC() internal returns (DualAssetOffer memory) {

        DualAssetOffer memory sellOffer = impliedVol.getOffer(false, 1, 0);
        DepositParams memory params = DepositParams({
            amount: 0.5 ether,
            strikeZone: 0,
            strikePrice: sellOffer.strikePrice,
            numDays: 1,
            apr: sellOffer.apr,
            expiry: sellOffer.expiry
        });

        vm.startPrank(user1);
        btc.approve(address(doppiCore), params.amount);
        doppiCore.deposit_sell(params);
        vm.stopPrank();
        return sellOffer;
    }

    function _depositUSDT() internal returns (DualAssetOffer memory) {

        // Deposit a position
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

        return buyOffer;

    }

    function _updateIV() internal {
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;
        impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
    }
}
