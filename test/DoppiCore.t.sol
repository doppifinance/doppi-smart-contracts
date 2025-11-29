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


contract DoppiCoreTest is Test {
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

    event Deposited(address indexed trader, uint64 positionId, address asset, uint256 amount, uint256 interest, uint256 strikePrice, uint32 apr, uint32 numDays);
    event Settled(address indexed trader, uint64 positionId, bool striked, bool isProfit, uint256 profitLoss, uint256 payout, uint256 interest, address profitToken, address payoutToken, address interestToken);
    event HedgeSettled(address indexed trader, uint64 positionId, bool isProfit, uint256 profitLoss, address profitToken);

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
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));
        
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

    function test_constructor() public view {
        assertEq(address(doppiCore.assetA()), address(usdt));
        assertEq(address(doppiCore.assetB()), address(btc));
        assertEq(address(doppiCore.doppiLP()), address(doppiLP));
        assertEq(address(doppiCore.doppiOffer()), address(impliedVol));
        assertEq(doppiCore.owner(), owner);
        assertTrue(doppiCore.opportunityBots(owner));
    }

    function test_setOpportunityBot() public {
        assertFalse(doppiCore.opportunityBots(user1));
        doppiCore.setOpportunityBot(user1, true);
        assertTrue(doppiCore.opportunityBots(user1));

        doppiCore.setOpportunityBot(user1, false);
        assertFalse(doppiCore.opportunityBots(user1));
    }

    function test_setOpportunityBot_onlyOwner() public {
        vm.startPrank(owner);
        doppiCore.setOpportunityBot(user2, true);
        vm.stopPrank();
    }

    function test_setTraderFactory() public {
        DoppiTraderFactory newFactory =
            new DoppiTraderFactory(IERC20(usdt), IERC20(btc), address(doppiCore), address(doppiLP), address(doppiRouter));
        doppiCore.setDoppiTraderFactory(newFactory);
        assertEq(address(doppiCore.doppiTraderFactory()), address(newFactory));
    }

    function test_deposit_buy_notOpen() public {
        
        doppiCore.setPublicOpen(false);

        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 0);
        DepositParams memory params = DepositParams({
            amount: 50_000 ether,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice + 1, // Invalid strike price
            numDays: 1,
            apr: buyOffer.apr,
            expiry: buyOffer.expiry
        });

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), params.amount);
        vm.expectRevert("not open");
        doppiCore.deposit_buy(params);
        vm.stopPrank();
    }


    function test_deposit_buy() public {
        _depositUSDT();

        assertEq(doppiCore.getBuyPositionCount(address(0)), 1);
        assertEq(usdt.balanceOf(user1), 200_000 ether - 50_000 ether);
    }

    function test_deposit_sell() public {
        _depositBTC();

        assertEq(doppiCore.getSellPositionCount(address(0)), 1);
        assertEq(btc.balanceOf(user1), 2 ether - 0.5 ether);
    }

    function test_deposit_buy_invalidStrikePrice() public {
        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 0);
        DepositParams memory params = DepositParams({
            amount: 50_000 ether,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice + 1, // Invalid strike price
            numDays: 1,
            apr: buyOffer.apr,
            expiry: buyOffer.expiry
        });

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), params.amount);
        vm.expectRevert("InvalidStrikePriceOrPrice()");
        doppiCore.deposit_buy(params);
        vm.stopPrank();
    }

    function test_deposit_buy_invalidAPR() public {
        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 0);
        DepositParams memory params = DepositParams({
            amount: 50_000 ether,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr + 1, // Invalid APR
            expiry: buyOffer.expiry
        });

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), params.amount);
        vm.expectRevert("InvalidAPR()");
        doppiCore.deposit_buy(params);
        vm.stopPrank();
    }

    function test_getReadyBuyPositions() public {
        // Deposit a position
        _depositUSDT();

        // Should not be ready yet
        uint256[] memory readyPositions = doppiCore.getReadyBuyPositions();
        assertEq(readyPositions.length, 0);

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);

        // Should be ready now
        readyPositions = doppiCore.getReadyBuyPositions();
        assertEq(readyPositions.length, 1);
    }

    function test_getReadySellPositions() public {
        // Deposit a position
        _depositBTC();

        // Should not be ready yet
        uint256[] memory readyPositions = doppiCore.getReadySellPositions();
        assertEq(readyPositions.length, 0);

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);

        // Should be ready now
        readyPositions = doppiCore.getReadySellPositions();
        assertEq(readyPositions.length, 1);
    }

    function test_settle_buys_priceAboveStrike() public {
        // Deposit a buy position
        _depositUSDT();

        // Fast forward time and keep price above strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE)); // Price stays same, above strike

        uint256[] memory readyPositions = doppiCore.getReadyBuyPositions();
        uint256 initialBalance = usdt.balanceOf(user1);

        vm.startPrank(owner);
        doppiCore.settle_buys(readyPositions);

        // Should receive original amount + interest
        assertGt(usdt.balanceOf(user1), initialBalance);
        assertEq(doppiCore.getBuyPositionCount(address(0)), 0);
    }

    function test_settle_buys_priceBelowStrike() public {
        // Deposit a buy position
        DualAssetOffer memory buyOffer = _depositUSDT();

        // Fast forward time and set price below strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(buyOffer.strikePrice - 1000 * 1e8));

        uint256[] memory readyPositions = doppiCore.getReadyBuyPositions();
        uint256 initialBtcBalance = btc.balanceOf(user1);
        uint256 initialUsdtBalance = usdt.balanceOf(user1);

        vm.startPrank(owner);
        doppiCore.settle_buys(readyPositions);

        // Should receive BTC (converted at strike price) + interest in USDT
        assertGt(btc.balanceOf(user1), initialBtcBalance);
        assertGt(usdt.balanceOf(user1), initialUsdtBalance);
        assertEq(doppiCore.getBuyPositionCount(address(0)), 0);
    }

    function test_settle_sells_priceBelowStrike() public {
        // Deposit a sell position
        _depositBTC();

        // Fast forward time and keep price below strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE)); // Price stays same, below strike

        uint256[] memory readyPositions = doppiCore.getReadySellPositions();
        uint256 initialBalance = btc.balanceOf(user1);

        vm.startPrank(owner);
        doppiCore.settle_sells(readyPositions);

        // Should receive original amount + interest
        assertGt(btc.balanceOf(user1), initialBalance);
        assertEq(doppiCore.getSellPositionCount(address(0)), 0);
    }

    function test_settle_sells_priceAboveStrike() public {
        // Deposit a sell position
        DualAssetOffer memory sellOffer = _depositBTC();
        
        // Fast forward time and set price above strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(sellOffer.strikePrice + 1000 * 1e8));

        uint256[] memory readyPositions = doppiCore.getReadySellPositions();
        uint256 initialUsdtBalance = usdt.balanceOf(user1);
        uint256 initialBtcBalance = btc.balanceOf(user1);

        vm.startPrank(owner);
        doppiCore.settle_sells(readyPositions);

        // Should receive USDT (converted at strike price) + interest in BTC
        assertGt(usdt.balanceOf(user1), initialUsdtBalance);
        assertGt(btc.balanceOf(user1), initialBtcBalance);
        assertEq(doppiCore.getSellPositionCount(address(0)), 0);
    }

    function test_opportunitySwap() public {
        // Deposit a buy position
        _depositUSDT();

        vm.startPrank(admin);
        (uint256 amountOut, ) = doppiCore.opportunitySwap(user1, 25_000 ether, INITIAL_PRICE, 0, true);
        vm.stopPrank();

        assertGt(amountOut, 0);

        // Check position is marked as traded
        DualAssetPosition memory position = doppiCore.get_buy(user1, 1);
        assertTrue(position.isTraded);
        assertEq(position.swappedAmount, amountOut);
    }

    function test_opportunityUnwind() public {
        // First setup a position and trade it
        _depositUSDT();

        oracle.setPrice(int256(98_000 * 1e8));
        // Admin swaps first
        vm.startPrank(admin);
        (uint256 swappedAmount,) = doppiCore.opportunitySwap(user1, 50_000 ether, 98_000 * 1e8, 0, true);
        vm.stopPrank();

        oracle.setPrice(int256(102_000 * 1e8));
        // Then admin unwinds
        vm.startPrank(admin);
        (uint256 amountOut,) = doppiCore.opportunityUnwind(user1, swappedAmount, 102_000 * 1e8, 0, false);
        vm.stopPrank();

        assertGt(amountOut, 0);

        // Check position is marked as not traded
        DualAssetPosition memory position = doppiCore.get_buy(user1, 1);
        assertFalse(position.isTraded);
        assertEq(position.swappedAmount, 0);
    }

    function test_checkUpkeep() public {
        // No positions initially
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertFalse(upkeepNeeded);

        // Deposit positions
        _depositUSDT();

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);

        (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
    }

    function test_performUpkeep_buy() public {
        // Deposit positions
        _depositUSDT();

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(96_500 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);

        uint256 initialPositionCount = doppiCore.getBuyPositionCount(address(0));
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

        // Position should be settled
        assertLt(doppiCore.getBuyPositionCount(address(0)), initialPositionCount);
    }

    function test_performUpkeep_sell() public {
        // Deposit positions
        _depositBTC();

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(106_500 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);

        uint256 initialPositionCount = doppiCore.getSellPositionCount(address(0));
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

        // Position should be settled
        assertLt(doppiCore.getSellPositionCount(address(0)), initialPositionCount);
    }

    function test_performUpkeep_buy_pagination() public {
        // Deposit positions
        _depositUSDT();
        _depositUSDT();
        _depositUSDT();

        doppiCore.setUpkeeps_per_check(2);
        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(96_500 * 1e8));
        
        // first checkUpkeep
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);

        (bool cached, , ) =
            abi.decode(performData, (bool, uint256[], uint256[]));
        
        assertFalse(cached);

        // uint256 initialPositionCount = doppiCore.getBuyPositionCount(address(0));
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

        (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);

        (cached) =
            abi.decode(performData, (bool));
        
        assertTrue(cached);
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

        (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        assertFalse(upkeepNeeded);
        
        // // Position should be settled
        assertEq(doppiCore.getBuyPositionCount(address(0)), 0);
    }

    function test_performUpkeep_buy_hedge_profit() public {
        
        // Deposit positions
        _depositUSDT();

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(96_500 * 1e8));
        (, bytes memory performData) = doppiCore.checkUpkeep("");
        
        // Expect HedgeSettled event
        vm.expectEmit(true, true, true, true);
        emit HedgeSettled(
            user1,
            1, // positionId
            true, // profit 
            3358772020725388, // profit amount
            address(btc) // profit in assetB
        );    

        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
    }

    function test_performUpkeep_sell_hedge_profit() public {
        // Deposit positions
        _depositBTC();

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(106_500 * 1e8));
        (, bytes memory performData) = doppiCore.checkUpkeep("");
        
        // Expect HedgeSettled event
        vm.expectEmit(true, true, true, true);
        emit HedgeSettled(
            user1,
            1, // positionId
            true, // profit 
            982798827500000000000, // profit amount
            address(usdt) // profit in assetA
        );    

        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);
        
    }

    function test_performUpkeep_buy_hedge_loss() public {
        // Deposit positions
        _depositUSDT();

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(106_500 * 1e8));
        (, bytes memory performData) = doppiCore.checkUpkeep("");
        
        // Expect HedgeSettled event
        vm.expectEmit(true, true, true, true);
        emit HedgeSettled(
            user1,
            1, // positionId
            false, // loss 
            17111535211267607, // loss  amount
            address(btc) // loss in assetB
        );    

        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

    }

    function test_performUpkeep_sell_hedge_loss() public {
        // Deposit positions
        _depositBTC();

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(96_500 * 1e8));
        (, bytes memory performData) = doppiCore.checkUpkeep("");
        
        // Expect HedgeSettled event
        vm.expectEmit(true, true, true, true);
        emit HedgeSettled(
            user1,
            1, // positionId
            false, // loss 
            1216055522500000000000, // loss  amount
            address(usdt) // loss in assetB
        );  

        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

    }

    function testFuzz_deposit_buy_amounts(uint256 amount) public {
        amount = bound(amount, 1000 ether, 100_000 ether);
        usdt.mint(user1, amount);

        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 0);
        
        DepositParams memory params = DepositParams({
            amount: amount,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            expiry: buyOffer.expiry
        });

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), amount);
        doppiCore.deposit_buy(params);
        vm.stopPrank();

        assertEq(doppiCore.getBuyPositionCount(address(0)), 1);
    }

    function testFuzz_deposit_sell_amounts(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 2 ether);
        btc.mint(user1, amount);

        DualAssetOffer[] memory sellOffers = impliedVol.getSellOffers(1);
        DepositParams memory params = DepositParams({
            amount: amount,
            strikeZone: 0,
            strikePrice: sellOffers[0].strikePrice,
            numDays: 1,
            apr: sellOffers[0].apr,
            expiry: sellOffers[0].expiry
        });

        vm.startPrank(user1);
        btc.approve(address(doppiCore), amount);
        doppiCore.deposit_sell(params);
        vm.stopPrank();

        assertEq(doppiCore.getSellPositionCount(address(0)), 1);
    }

    function test_get_positions() public {
        // Initially no positions

        DualAssetPosition[] memory buyPositions = doppiCore.get_positions_buy();
        DualAssetPosition[] memory sellPositions = doppiCore.get_positions_sell();
        assertEq(buyPositions.length, 0);
        assertEq(sellPositions.length, 0);

        // Deposit positions
        _depositUSDT();
        _depositBTC();

        // Check positions
        buyPositions = doppiCore.get_positions_buy(user1);
        sellPositions = doppiCore.get_positions_sell(user1);
        assertEq(buyPositions.length, 1);
        assertEq(sellPositions.length, 1);

        assertEq(buyPositions[0].amount, 50_000 ether);
        assertEq(buyPositions[0].owner, user1);
        assertEq(sellPositions[0].amount, 0.5 ether);
        assertEq(sellPositions[0].owner, user1);
    }

    function test_multiple_users_positions() public {
        DualAssetOffer[] memory buyOffers = impliedVol.getBuyOffers(1);

        // User1 deposits
        vm.startPrank(user1);
        usdt.approve(address(doppiCore), 50_000 ether);
        doppiCore.deposit_buy(
            DepositParams({
                amount: 50_000 ether,
                strikeZone: 0,
                strikePrice: buyOffers[0].strikePrice,
                numDays: 1,
                apr: buyOffers[0].apr,
                expiry: buyOffers[0].expiry
            })
        );
        vm.stopPrank();

        // User2 deposits
        vm.startPrank(user2);
        usdt.approve(address(doppiCore), 75_000 ether);
        doppiCore.deposit_buy(
            DepositParams({
                amount: 75_000 ether,
                strikeZone: 1,
                strikePrice: buyOffers[1].strikePrice,
                numDays: 1,
                apr: buyOffers[1].apr,
                expiry: buyOffers[1].expiry
            })
        );
        vm.stopPrank();

        DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        assertEq(positions.length, 2);
        assertEq(positions[0].owner, user1);
        assertEq(positions[1].owner, user2);
        assertEq(positions[0].amount, 50_000 ether);
        assertEq(positions[1].amount, 75_000 ether);

        positions = doppiCore.get_positions_buy(user1);
        assertEq(positions.length, 1);
        positions = doppiCore.get_positions_buy(user2);
        assertEq(positions.length, 1);
    }

    function test_settle_buys_interestFee() public {
        // Deposit a buy position
        _depositUSDT();

        // Fast forward time and keep price above strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE)); // Price stays same, above strike

        uint256[] memory readyPositions = doppiCore.getReadyBuyPositions();
        // uint256 initialBalance = usdt.balanceOf(user1);

        vm.startPrank(owner);
        doppiCore.settle_buys(readyPositions);
        assertEq(usdt.balanceOf(doppiCore.treasury()), 43012328767123287671); // 50000 * 313.99% / 365 * 10%
    }

    function test_opportunity_profit_fee() public {
        // First setup a position and trade it
        _depositUSDT();

        oracle.setPrice(int256(98_000 * 1e8));
        // Admin swaps first
        vm.startPrank(admin);
        (uint256 swappedAmount,) = doppiCore.opportunitySwap(user1, 50_000 ether, 98_000 * 1e8, 0, true);
        vm.stopPrank();

        oracle.setPrice(int256(102_000 * 1e8));
        // Then admin unwinds
        vm.startPrank(admin);
        (uint256 amountOut, uint256 profit) = doppiCore.opportunityUnwind(user1, swappedAmount, 102_000 * 1e8, 0, false);
        vm.stopPrank();

        // Check position is marked as not traded
        assertGt(amountOut, 0);
        // console.log(amountOut, "amountOut");
        uint256 fee = profit * 1000 / 10000;
        assertEq(usdt.balanceOf(doppiCore.treasury()), fee); 
    }

    function test_settle_buys_strike_profit_fee() public {
        // Deposit a buy position
        DualAssetOffer memory buyOffer = _depositUSDT();

        // Fast forward time and set price below strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(buyOffer.strikePrice - 1000 * 1e8));

        uint256[] memory readyPositions = doppiCore.getReadyBuyPositions();
        
        uint256 userUSDTbefore = usdt.balanceOf(user1);
        uint256 userBTCbefore = btc.balanceOf(user1);
        uint256 tresuryUSDTbefore = usdt.balanceOf(doppiCore.treasury());
        uint256 tresuryBTCbefore = btc.balanceOf(doppiCore.treasury());
        // uint256 lpBTCbefore = btc.balanceOf(address(doppiLP));
        // uint256 lpUSDTbefore = usdt.balanceOf(address(doppiLP));
        
        // settlement in doppiCore
        vm.startPrank(owner);
        doppiCore.settle_buys(readyPositions);

        
        uint256 userUSDTafter = usdt.balanceOf(user1);
        uint256 userBTCafter = btc.balanceOf(user1);
        uint256 tresuryUSDTafter = usdt.balanceOf(doppiCore.treasury());
        uint256 tresuryBTCafter = btc.balanceOf(doppiCore.treasury());
        uint256 lpBTCafter = btc.balanceOf(address(doppiLP));
        uint256 lpUSDTafter = usdt.balanceOf(address(doppiLP));
        
        uint256 APR_BASIS_POINTS = 31399; // 313.99% APR in basis points
        uint256 PRINCIPAL = 50_000 ether; // 50,000 USDT
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;

        uint256 usdtInterestReceived = APR_BASIS_POINTS * PRINCIPAL / BASIS_POINTS_DENOMINATOR / DAYS_IN_YEAR;
        
        uint256 btcPayout = 50_000 ether * 1e8 / buyOffer.strikePrice;
        uint256 btcPayoutSettle = 50_000 ether * 1e8 / (buyOffer.strikePrice - 1000 * 1e8);
        uint256 btcPayoutSettleProfit = btcPayoutSettle - btcPayout;
        
        uint256 usdtFee = usdtInterestReceived * 1000 / 10000;
        uint256 btcFee = btcPayoutSettleProfit * 1000 / 10000;
        
        // hedge position: selling 0.21465 btc into usdt
        // unwind hedge position: get back 0.21358 btc into usdt
        uint256 hedgeSoldBTC = 214650000000000000;
        uint256 hedgeSoldBTCunwind = 213582197969543146;
        
        // (,,, uint128 settleHedgeLossAssetB) = doppiCore.hedgeStats();        
        // assertEq(settleHedgeLossAssetB, hedgeSoldBTC - hedgeSoldBTCunwind);

        // confirm doppi LP usdt balance = APR payout in USDT + strike on receiving 50000 USDT 
        // confirm doppi LP btc balance = loss in hedge position + btc payout to trader + settlement profit gained in BTC minus 10% fee 
        uint256 expectedUSDTLPBal = 100_000 ether + 50_000 ether -  usdtInterestReceived;
        uint256 expectedBTCLPBal = 1 ether - hedgeSoldBTC + hedgeSoldBTCunwind - btcPayoutSettle + btcPayoutSettleProfit - btcFee;
        
        assertEq(lpBTCafter, expectedBTCLPBal);
        assertEq(lpUSDTafter, expectedUSDTLPBal);
        
        // confirm tresury wallet balance = 10% fee from APR received in USDT and 10% of settlement profit in BTC 
        assertEq(usdtFee, tresuryUSDTafter - tresuryUSDTbefore);
        assertEq(btcFee, tresuryBTCafter - tresuryBTCbefore);

        // confirm user wallet balance = interest received in USDT and payout in BTC 
        assertEq(usdtInterestReceived - usdtFee, userUSDTafter - userUSDTbefore);
        assertEq(btcPayout, userBTCafter - userBTCbefore);
        
    }

    function test_settle_sell_strike_profit_fee() public {
        // Deposit a buy position
        DualAssetOffer memory sellOffer = _depositBTC();

        // Fast forward time and set price below strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(sellOffer.strikePrice + 1000 * 1e8));

        uint256[] memory readyPositions = doppiCore.getReadySellPositions();
        
        uint256 userUSDTbefore = usdt.balanceOf(user1);
        uint256 userBTCbefore = btc.balanceOf(user1);
        uint256 tresuryUSDTbefore = usdt.balanceOf(doppiCore.treasury());
        uint256 tresuryBTCbefore = btc.balanceOf(doppiCore.treasury());
        // uint256 lpBTCbefore = btc.balanceOf(address(doppiLP));
        // uint256 lpUSDTbefore = usdt.balanceOf(address(doppiLP));
        
        // settlement in doppiCore
        vm.startPrank(owner);
        doppiCore.settle_sells(readyPositions);

        
        uint256 userUSDTafter = usdt.balanceOf(user1);
        uint256 userBTCafter = btc.balanceOf(user1);
        uint256 tresuryUSDTafter = usdt.balanceOf(doppiCore.treasury());
        uint256 tresuryBTCafter = btc.balanceOf(doppiCore.treasury());
        uint256 lpBTCafter = btc.balanceOf(address(doppiLP));
        uint256 lpUSDTafter = usdt.balanceOf(address(doppiLP));
        
        // console.log(sellOffer.apr, sellOffer.strikePrice);
        uint256 APR_BASIS_POINTS = 35700; // 357.00% APR in basis points
        uint256 PRINCIPAL = 0.5 ether; // 0.5 BTC
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;

        uint256 btcInterestReceived = APR_BASIS_POINTS * PRINCIPAL / BASIS_POINTS_DENOMINATOR / DAYS_IN_YEAR;
        uint256 usdtPayout = 0.5 ether * sellOffer.strikePrice / 1e8;
        uint256 usdtPayoutSettle = 0.5 ether * (sellOffer.strikePrice + 1000 * 1e8) / 1e8;
        uint256 usdtPayoutSettleProfit = usdtPayoutSettle - usdtPayout;
        
        uint256 usdtFee = usdtPayoutSettleProfit * 1000 / 10000;
        uint256 btcFee = btcInterestReceived * 1000 / 10000;
        
        // hedge position: selling 22435 usdt into btc
        // unwind hedge position: get back 22318 usdt into btc
        uint256 hedgeSoldUSDT = 22435000000000000000000;
        uint256 hedgeSoldUSDTunwind = 22318371652500000000000;
        
        // (,,uint128 settleHedgeLossAssetA, ) = doppiCore.hedgeStats();
        // assertEq(settleHedgeLossAssetA, hedgeSoldUSDT - hedgeSoldUSDTunwind);
        // confirm doppi LP btc balance = APR payout in btc + strike on receiving 0.5 btc 
        // confirm doppi LP usdt balance = loss in hedge position + usdt payout to trader + settlement profit gained in usdt minus 10% fee 
        uint256 expectedUSDTLPBal = 100_000 ether - hedgeSoldUSDT + hedgeSoldUSDTunwind - usdtPayoutSettle + usdtPayoutSettleProfit - usdtFee;
        uint256 expectedBTCLPBal = 1 ether + 0.5 ether - btcInterestReceived; 

        assertEq(lpBTCafter, expectedBTCLPBal);
        assertEq(lpUSDTafter, expectedUSDTLPBal);
        
        // confirm tresury wallet balance = 10% fee from APR received in btc and 10% of settlement profit in usdt 
        assertEq(usdtFee, tresuryUSDTafter - tresuryUSDTbefore);
        assertEq(btcFee, tresuryBTCafter - tresuryBTCbefore);

        // confirm user wallet balance = interest received in btc and payout in usdt 
        assertEq(btcInterestReceived - btcFee, userBTCafter - userBTCbefore);
        assertEq(usdtPayout, userUSDTafter - userUSDTbefore);
        
    }

    // Event emit test
    function test_DepositBuy_EmitsDepositedEvent() public {
        
        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 0);
        uint256 APR_BASIS_POINTS = 31399; // 313.99% APR in basis points
        uint256 PRINCIPAL = 50_000 ether; // 50,000 USDT
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;

        uint256 usdtInterestReceived = APR_BASIS_POINTS * PRINCIPAL / BASIS_POINTS_DENOMINATOR / DAYS_IN_YEAR;
        
        vm.startPrank(user1);
        usdt.approve(address(doppiCore), PRINCIPAL);
        
        DepositParams memory params = DepositParams({
            amount: PRINCIPAL,
            strikeZone: 0,
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
            false, // isProfit (varies based on implementation)
            0, // profitLoss
            expectedPayout, // expected payout
            usdtInterestReceived, // interest
            address(btc), // profitToken
            address(btc), // payoutToken
            address(usdt)  // interestToken
        );
        
        // Execute settlement
        uint256[] memory readyPositions = doppiCore.getReadyBuyPositions();
        doppiCore.settle_buys(readyPositions);
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
            false, // isProfit (varies based on implementation)
            0, // profitLoss
            expectedPayout, // expected payout
            btcInterestReceived, // interest
            address(usdt), // profitToken
            address(usdt), // payoutToken
            address(btc)  // interestToken
        );
        
        // Execute settlement
        uint256[] memory readyPositions = doppiCore.getReadySellPositions();
        doppiCore.settle_sells(readyPositions);
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
            false, // isProfit (varies based on implementation)
            0, // profitLoss
            0, // expected payout
            usdtInterestReceived, // interest
            address(usdt), // profitToken
            address(usdt), // payoutToken
            address(usdt)  // interestToken
        );
        
        // Execute settlement
        uint256[] memory readyPositions = doppiCore.getReadyBuyPositions();
        doppiCore.settle_buys(readyPositions);
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
            false, // isProfit (varies based on implementation)
            0, // profitLoss
            0, // expected payout
            btcInterestReceived, // interest
            address(btc), // profitToken
            address(btc), // payoutToken
            address(btc)  // interestToken
        );
        
        // Execute settlement
        uint256[] memory readyPositions = doppiCore.getReadySellPositions();
        doppiCore.settle_sells(readyPositions);
    }

    function test_SettleSellStrikedTraded_EmitsSettledEvent() public {
        
        DualAssetOffer memory sellOffer = _depositBTC();
        uint256 APR_BASIS_POINTS = 35700;
        uint256 PRINCIPAL = 0.5 ether; 
        uint256 BASIS_POINTS_DENOMINATOR = 10000;
        uint256 DAYS_IN_YEAR = 365;


        // ***** START perform opportunityBot.checkUpkeep
        vm.startPrank(admin);
        oracle.setPrice(int256(101_600 * 1e8));
        doppiCore.opportunitySwap(user1, PRINCIPAL, 101_600 * 1e8, 0, false);
        vm.stopPrank();

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
            true, // isProfit (varies based on implementation)
            499200000000000000000, // profitLoss
            expectedPayout, // expected payout
            btcInterestReceived, // interest
            address(usdt), // profitToken
            address(usdt), // payoutToken
            address(btc)  // interestToken
        );
        
        // Execute settlement
        uint256[] memory readyPositions = doppiCore.getReadySellPositions();
        doppiCore.settle_sells(readyPositions);
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
        doppiCore.opportunitySwap(user1, PRINCIPAL, 98_000 * 1e8, 0, true);
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
            true, // isProfit (varies based on implementation)
            7181314736950057, // profitLoss
            expectedPayout, // expected payout
            usdtInterestReceived, // interest
            address(btc), // profitToken
            address(btc), // payoutToken
            address(usdt)  // interestToken
        );
        
        // Execute settlement
        uint256[] memory readyPositions = doppiCore.getReadyBuyPositions();
        doppiCore.settle_buys(readyPositions);
    }

    function test_HedgedSettled_EmitsDepositedEvent() public {
        
        // Deposit positions
        _depositUSDT();

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(96_500 * 1e8));
        (, bytes memory performData) = doppiCore.checkUpkeep("");
        
        // Expect HedgeSettled event
        vm.expectEmit(true, true, true, true);
        emit HedgeSettled(
            user1,
            1, // positionId
            true,
            3358772020725388,
            address(btc)
        );    

        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

    }

    
    function test_settle_recordPoints() public {

        // Deposit a buy position
        _depositUSDT();
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE)); // Price stays same, above strike

        uint256[] memory readyPositions = doppiCore.getReadyBuyPositions();
        vm.startPrank(owner);
        doppiCore.settle_buys(readyPositions);

        (,, uint256 currentMonthPoint) = doppiPoints.getAllPointData(user1);
        assertEq(currentMonthPoint, 50000 ether);
        
        _updateIV();

        // Deposit a sell position
        _depositBTC();
        vm.warp(block.timestamp + 2 days + 1);
        oracle.setPrice(int256(99_000 * 1e8)); // Price stays same, above strike
        readyPositions = doppiCore.getReadySellPositions();
        vm.startPrank(owner);
        doppiCore.settle_sells(readyPositions);

        (,, currentMonthPoint) = doppiPoints.getAllPointData(user1);
        uint256 sellOrderPoints = 0.5 ether * (99_000 * 1e8) / 1e8;
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

        assertEq(doppiCore.getBuyPositionCount(address(0)), 0);
        assertEq(doppiCore.getSellPositionCount(address(0)), 0);

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
        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 0);
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
