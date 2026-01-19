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
        assertEq(doppiCore.getBuyPositionCount(user1), 1);
        assertEq(usdt.balanceOf(user1), 200_000 ether - 50_000 ether);
    }

    function test_deposit_sell() public {
        _depositBTC();

        assertEq(doppiCore.getSellPositionCount(user1), 1);
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
        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions();
        assertEq(readyPositions.length, 0);

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);

        // Should be ready now
        (readyPositions, settleAccu) = doppiCore.getReadyAllPositions();
        assertEq(readyPositions.length, 1);
    }

    function test_getReadySellPositions() public {
        // Deposit a position
        _depositBTC();

        // Should not be ready yet
        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions();
        assertEq(readyPositions.length, 0);

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);

        // Should be ready now
        (readyPositions, settleAccu) = doppiCore.getReadyAllPositions();
        assertEq(readyPositions.length, 1);
    }

    function test_settle_buys_priceAboveStrike() public {
        // Deposit a buy position
        _depositUSDT();

        // Fast forward time and keep price above strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE)); // Price stays same, above strike

        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions();
        uint256 initialBalance = usdt.balanceOf(user1);

        vm.startPrank(owner);
        doppiCore.settleOrders(readyPositions, settleAccu);

        // Should receive original amount + interest
        assertGt(usdt.balanceOf(user1), initialBalance);
        assertEq(doppiCore.getBuyPositionCount(user1), 0);
    }

    function test_settle_buys_priceBelowStrike() public {
        // Deposit a buy position
        DualAssetOffer memory buyOffer = _depositUSDT();

        // Fast forward time and set price below strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(buyOffer.strikePrice - 1000 * 1e8));

        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions();
        console.log(readyPositions.length, settleAccu.totalInterestA);
        uint256 initialBtcBalance = btc.balanceOf(user1);
        uint256 initialUsdtBalance = usdt.balanceOf(user1);

        vm.startPrank(owner);
        doppiCore.settleOrders(readyPositions, settleAccu);

        // Should receive BTC (converted at strike price) + interest in USDT
        assertGt(btc.balanceOf(user1), initialBtcBalance);
        assertGt(usdt.balanceOf(user1), initialUsdtBalance);
        assertEq(doppiCore.getBuyPositionCount(user1), 0);
    }

    function test_settle_sells_priceBelowStrike() public {
        // Deposit a sell position
        _depositBTC();

        // Fast forward time and keep price below strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE)); // Price stays same, below strike

        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions();
        uint256 initialBalance = btc.balanceOf(user1);

        vm.startPrank(owner);
        doppiCore.settleOrders(readyPositions, settleAccu);

        // Should receive original amount + interest
        assertGt(btc.balanceOf(user1), initialBalance);
        assertEq(doppiCore.getSellPositionCount(user1), 0);
    }

    function test_settle_sells_priceAboveStrike() public {
        // Deposit a sell position
        DualAssetOffer memory sellOffer = _depositBTC();
        
        // Fast forward time and set price above strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(sellOffer.strikePrice + 1000 * 1e8));

        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions();
        uint256 initialUsdtBalance = usdt.balanceOf(user1);
        uint256 initialBtcBalance = btc.balanceOf(user1);

        vm.startPrank(owner);
        doppiCore.settleOrders(readyPositions, settleAccu);

        // Should receive USDT (converted at strike price) + interest in BTC
        assertGt(usdt.balanceOf(user1), initialUsdtBalance);
        assertGt(btc.balanceOf(user1), initialBtcBalance);
        assertEq(doppiCore.getSellPositionCount(user1), 0);
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

        uint256 initialPositionCount = doppiCore.getBuyPositionCount(user1);
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

        // Position should be settled
        assertLt(doppiCore.getBuyPositionCount(user1), initialPositionCount);
    }

    function test_performUpkeep_sell() public {
        // Deposit positions
        _depositBTC();

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(106_500 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);

        uint256 initialPositionCount = doppiCore.getSellPositionCount(user1);
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

        // Position should be settled
        assertLt(doppiCore.getSellPositionCount(user1), initialPositionCount);
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

        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

        (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);

        (uint64[] memory allPositions) = abi.decode(performData, (uint64[]));
        
        assertGt(allPositions.length, 0);
        vm.prank(mockForwarder);
        doppiCore.performUpkeep(performData);

        (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
        assertFalse(upkeepNeeded);
        
        // // Position should be settled
        assertEq(doppiCore.getBuyPositionCount(user1), 0);
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

        assertEq(doppiCore.getBuyPositionCount(user1), 1);
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

        assertEq(doppiCore.getSellPositionCount(user1), 1);
    }

    function test_get_positions() public {
        // Initially no positions

        DualAssetPosition[] memory buyPositions = doppiCore.get_positions_buy(user1);
        DualAssetPosition[] memory sellPositions = doppiCore.get_positions_sell(user1);
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

        DualAssetPosition[] memory positions = doppiCore.get_positions_buy(user1);
        DualAssetPosition[] memory positions2= doppiCore.get_positions_buy(user2);
        // assertEq(positions.length, 2);
        assertEq(positions[0].owner, user1);
        assertEq(positions2[0].owner, user2);
        assertEq(positions[0].amount, 50_000 ether);
        assertEq(positions2[0].amount, 75_000 ether);

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

        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions();
        // uint256 initialBalance = usdt.balanceOf(user1);

        vm.startPrank(owner);
        doppiCore.settleOrders(readyPositions, settleAccu);
        assertEq(usdt.balanceOf(doppiCore.treasury()), 43012328767123287671); // 50000 * 313.99% / 365 * 10%
    }

    function test_settle_buys_strike_profit_fee() public {
        // Deposit a buy position
        DualAssetOffer memory buyOffer = _depositUSDT();

        // Fast forward time and set price below strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(buyOffer.strikePrice - 1000 * 1e8));
        
        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions();
        
        uint256 userUSDTbefore = usdt.balanceOf(user1);
        uint256 userBTCbefore = btc.balanceOf(user1);
        uint256 tresuryUSDTbefore = usdt.balanceOf(doppiCore.treasury());
        uint256 tresuryBTCbefore = btc.balanceOf(doppiCore.treasury());
        uint256 lpBTCbefore = btc.balanceOf(address(doppiLP));
        uint256 lpUSDTbefore = usdt.balanceOf(address(doppiLP));
        
        // settlement in doppiCore
        vm.startPrank(owner);
        doppiCore.settleOrders(readyPositions, settleAccu);

        
        uint256 userUSDTafter = usdt.balanceOf(user1);
        uint256 userBTCafter = btc.balanceOf(user1);
        uint256 tresuryUSDTafter = usdt.balanceOf(doppiCore.treasury());
        uint256 tresuryBTCafter = btc.balanceOf(doppiCore.treasury());
        uint256 lpBTCafter = btc.balanceOf(address(doppiLP));
        uint256 lpUSDTafter = usdt.balanceOf(address(doppiLP));
        
        uint256 APR_BASIS_POINTS = 31399; // 313.99% APR in basis points
        uint256 usdtInterestReceived = (APR_BASIS_POINTS * 50_000 ether) / 10000 / 365;
        uint256 btcPayout = (50_000 ether * 1e8) / buyOffer.strikePrice;
        uint256 btcPayoutSettle = (50_000 ether * 1e8) / (buyOffer.strikePrice - 1000 * 1e8);
        uint256 btcPayoutSettleProfit = btcPayoutSettle - btcPayout;
        
        uint256 usdtFee = usdtInterestReceived * 1000 / 10000;
        uint256 btcFee = btcPayoutSettleProfit * 1000 / 10000;
        
        // hedge position: selling 0.21465 btc into usdt
        // unwind hedge position: get back 0.21358 btc into usdt
        uint256 hedgeSoldBTC = 0; // 214650000000000000;
        uint256 hedgeSoldBTCunwind = 0; // 213582197969543146;
        
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

        (uint64[] memory readyPositions, SettleAccumulate memory settleAccu) = doppiCore.getReadyAllPositions();
        
        uint256 userUSDTbefore = usdt.balanceOf(user1);
        uint256 userBTCbefore = btc.balanceOf(user1);
        uint256 tresuryUSDTbefore = usdt.balanceOf(doppiCore.treasury());
        uint256 tresuryBTCbefore = btc.balanceOf(doppiCore.treasury());
        uint256 lpBTCbefore = btc.balanceOf(address(doppiLP));
        uint256 lpUSDTbefore = usdt.balanceOf(address(doppiLP));
        
        // settlement in doppiCore
        vm.startPrank(owner);
        doppiCore.settleOrders(readyPositions, settleAccu);

        
        uint256 userUSDTafter = usdt.balanceOf(user1);
        uint256 userBTCafter = btc.balanceOf(user1);
        uint256 tresuryUSDTafter = usdt.balanceOf(doppiCore.treasury());
        uint256 tresuryBTCafter = btc.balanceOf(doppiCore.treasury());
        uint256 lpBTCafter = btc.balanceOf(address(doppiLP));
        uint256 lpUSDTafter = usdt.balanceOf(address(doppiLP));
        
        uint256 APR_BASIS_POINTS = 35700; // 357.00% APR in basis points
        uint256 btcInterestReceived = APR_BASIS_POINTS * 0.5 ether / 10000 / 365;
        uint256 usdtPayout = 0.5 ether * sellOffer.strikePrice / 1e8;
        uint256 usdtPayoutSettle = 0.5 ether * (sellOffer.strikePrice + 1000 * 1e8) / 1e8;
        uint256 usdtPayoutSettleProfit = usdtPayoutSettle - usdtPayout;
        
        uint256 usdtFee = usdtPayoutSettleProfit * 1000 / 10000;
        uint256 btcFee = btcInterestReceived * 1000 / 10000;
        
        // hedge position: selling 22435 usdt into btc
        // unwind hedge position: get back 22318 usdt into btc
        uint256 hedgeSoldUSDT = 0; // 22435000000000000000000;
        uint256 hedgeSoldUSDTunwind = 0; // 22318371652500000000000;
        
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
