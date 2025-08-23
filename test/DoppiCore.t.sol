// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {DoppiTraderFactory} from "../src/mainnet/DoppiTraderFactory.sol";
import {DoppiTrader} from "../src/mainnet/DoppiTrader.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {ImpliedVol} from "../src/mainnet/ImpliedVol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
// import "forge-std/console.sol";

contract DoppiCoreTest is Test {
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    DoppiTraderFactory traderFactory;
    BlackScholes blackScholes;
    ImpliedVol impliedVol;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;

    address owner = address(this);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address treasury = address(0x3);
    address admin = address(0x4);

    uint256 constant INITIAL_PRICE = 100_000 ether;
    uint24[] weights;

    event Deposited(address indexed user, uint256 amountA, uint256 amountB);
    event Settled(address indexed user, uint256 payoutA, uint256 payoutB);
    event BulkDeposited(address indexed user, uint256 totalAmount, bool isBuy);
    event BulkSettled(uint256 settledCount, bool isBuy);

    function setUp() public {
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;

        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(int256(INITIAL_PRICE), 18);

        blackScholes = new BlackScholes();
        impliedVol = new ImpliedVol(blackScholes);
        impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);

        doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(usdt), IERC20(btc), treasury);
        doppiLP.setOracle(address(oracle));

        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);

        doppiLP.setDualAsset(address(doppiCore));

        // Create router and set entry points
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));

        traderFactory =
            new DoppiTraderFactory(IERC20(usdt), IERC20(btc), doppiCore, doppiLP, doppiRouter);

        doppiCore.setTraderFactory(traderFactory);
        doppiCore.setAdmin(admin, true);

        weights.push(500);
        weights.push(1000);
        weights.push(1500);
        weights.push(2500);
        weights.push(4500);

        // Mint tokens
        // usdt.mint(address(doppiLP), 1_000_000 ether);
        // btc.mint(address(doppiLP), 10 ether);
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
        assertEq(address(doppiCore.impliedVol()), address(impliedVol));
        assertEq(doppiCore.owner(), owner);
        assertTrue(doppiCore.admins(owner));
    }

    function test_setAdmin() public {
        assertFalse(doppiCore.admins(user1));
        doppiCore.setAdmin(user1, true);
        assertTrue(doppiCore.admins(user1));

        doppiCore.setAdmin(user1, false);
        assertFalse(doppiCore.admins(user1));
    }

    function test_setAdmin_onlyAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert("only admin");
        doppiCore.setAdmin(user2, true);
        vm.stopPrank();
    }

    function test_setTraderFactory() public {
        DoppiTraderFactory newFactory =
            new DoppiTraderFactory(IERC20(usdt), IERC20(btc), doppiCore, doppiLP, doppiRouter);
        doppiCore.setTraderFactory(newFactory);
        assertEq(address(doppiCore.traderFactory()), address(newFactory));
    }

    function test_setPriceGap() public {
        doppiCore.setPriceGap(1000);
        assertEq(doppiCore.PRICE_GAP_PEROFFER(), 1000);
    }

    function test_getBuyOffers() public view {
        DoppiCore.DualAssetOffer[] memory buyOffers = doppiCore.getBuyOffers(1);

        assertEq(buyOffers.length, 5);
        for (uint256 i = 0; i < buyOffers.length; i++) {
            // console.log(buyOffers[i].strikePrice, buyOffers[i].apr);
            assertEq(buyOffers[i].price, INITIAL_PRICE);
            assertLt(buyOffers[i].strikePrice, INITIAL_PRICE);
            assertGt(buyOffers[i].apr, 0);
            assertGt(buyOffers[i].validUntilTimestamp, block.timestamp);
        }

        // Strike prices should be decreasing (further from current price)
        for (uint256 i = 1; i < buyOffers.length; i++) {
            assertLt(buyOffers[i].strikePrice, buyOffers[i - 1].strikePrice);
        }
    }

    function test_getSellOffers() public view {
        DoppiCore.DualAssetOffer[] memory sellOffers = doppiCore.getSellOffers(1);

        assertEq(sellOffers.length, 5);
        for (uint256 i = 0; i < sellOffers.length; i++) {
            assertEq(sellOffers[i].price, INITIAL_PRICE);
            assertGt(sellOffers[i].strikePrice, INITIAL_PRICE);
            assertGt(sellOffers[i].apr, 0);
            assertGt(sellOffers[i].validUntilTimestamp, block.timestamp);
        }

        // Strike prices should be increasing (further from current price)
        for (uint256 i = 1; i < sellOffers.length; i++) {
            assertGt(sellOffers[i].strikePrice, sellOffers[i - 1].strikePrice);
        }
    }

    function test_getAllOffers() public view {
        (DoppiCore.DualAssetOffer[] memory buyOffers, DoppiCore.DualAssetOffer[] memory sellOffers) =
            doppiCore.getAllOffers(1);

        assertEq(buyOffers.length, 5);
        assertEq(sellOffers.length, 5);

        for (uint256 i = 0; i < 5; i++) {
            assertEq(buyOffers[i].price, INITIAL_PRICE);
            assertEq(sellOffers[i].price, INITIAL_PRICE);
            assertLt(buyOffers[i].strikePrice, INITIAL_PRICE);
            assertGt(sellOffers[i].strikePrice, INITIAL_PRICE);
        }
    }

    function test_deposit_buy() public {
        _depositUSDT();

        assertEq(doppiCore.getBuyPositionCount(), 1);
        assertEq(usdt.balanceOf(user1), 200_000 ether - 50_000 ether);
    }

    function test_deposit_sell() public {
        _depositBTC();

        assertEq(doppiCore.getSellPositionCount(), 1);
        assertEq(btc.balanceOf(user1), 2 ether - 0.5 ether);
    }

    function test_bulkDepositBuys() public {
        DoppiCore.DualAssetOffer[] memory buyOffers = doppiCore.getBuyOffers(1);
        DoppiCore.DepositParams[] memory params = new DoppiCore.DepositParams[](2);

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < 2; i++) {
            uint256 amount = 25_000 ether;
            params[i] = DoppiCore.DepositParams({
                amount: amount,
                strikeZone: uint8(i),
                strikePrice: buyOffers[i].strikePrice,
                numDays: 1,
                apr: buyOffers[i].apr,
                validityTime: buyOffers[i].validUntilTimestamp
            });
            totalAmount += amount;
        }

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), totalAmount);
        doppiCore.bulkDepositBuys(params, buyOffers);
        vm.stopPrank();

        assertEq(doppiCore.getBuyPositionCount(), 2);
        assertEq(usdt.balanceOf(user1), 200_000 ether - totalAmount);
    }

    function test_bulkDepositSells() public {
        DoppiCore.DualAssetOffer[] memory sellOffers = doppiCore.getSellOffers(1);
        DoppiCore.DepositParams[] memory params = new DoppiCore.DepositParams[](2);

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < 2; i++) {
            uint256 amount = 0.25 ether;
            params[i] = DoppiCore.DepositParams({
                amount: amount,
                strikeZone: uint8(i),
                strikePrice: sellOffers[i].strikePrice,
                numDays: 1,
                apr: sellOffers[i].apr,
                validityTime: sellOffers[i].validUntilTimestamp
            });
            totalAmount += amount;
        }

        vm.startPrank(user1);
        btc.approve(address(doppiCore), totalAmount);
        doppiCore.bulkDepositSells(params, sellOffers);
        vm.stopPrank();

        assertEq(doppiCore.getSellPositionCount(), 2);
        assertEq(btc.balanceOf(user1), 2 ether - totalAmount);
    }

    function test_deposit_buy_invalidStrikePrice() public {
        DoppiCore.DualAssetOffer memory buyOffer = doppiCore.getOffer(true, 1, 0);
        DoppiCore.DepositParams memory params = DoppiCore.DepositParams({
            amount: 50_000 ether,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice + 1, // Invalid strike price
            numDays: 1,
            apr: buyOffer.apr,
            validityTime: buyOffer.validUntilTimestamp
        });

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), params.amount);
        vm.expectRevert("incorrect strikePrice");
        doppiCore.deposit_buy(params);
        vm.stopPrank();
    }

    function test_deposit_buy_invalidAPR() public {
        DoppiCore.DualAssetOffer memory buyOffer = doppiCore.getOffer(true, 1, 0);
        DoppiCore.DepositParams memory params = DoppiCore.DepositParams({
            amount: 50_000 ether,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr + 1, // Invalid APR
            validityTime: buyOffer.validUntilTimestamp
        });

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), params.amount);
        vm.expectRevert("incorrect apr");
        doppiCore.deposit_buy(params);
        vm.stopPrank();
    }

    function test_deposit_buy_expiredOffer() public {
        DoppiCore.DualAssetOffer memory buyOffer = doppiCore.getOffer(true, 1, 0);
        // Fast forward time
        vm.warp(block.timestamp + 2 minutes);

        DoppiCore.DepositParams memory params = DoppiCore.DepositParams({
            amount: 50_000 ether,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            validityTime: buyOffer.validUntilTimestamp
        });

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), params.amount);
        vm.expectRevert("offer expired");
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

        doppiCore.settle_buys(readyPositions);

        // Should receive original amount + interest
        assertGt(usdt.balanceOf(user1), initialBalance);
        assertEq(doppiCore.getBuyPositionCount(), 0);
    }

    function test_settle_buys_priceBelowStrike() public {
        // Deposit a buy position
        DoppiCore.DualAssetOffer memory buyOffer = _depositUSDT();

        // Fast forward time and set price below strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(buyOffer.strikePrice - 1000 ether));

        uint256[] memory readyPositions = doppiCore.getReadyBuyPositions();
        uint256 initialBtcBalance = btc.balanceOf(user1);
        uint256 initialUsdtBalance = usdt.balanceOf(user1);

        doppiCore.settle_buys(readyPositions);

        // Should receive BTC (converted at strike price) + interest in USDT
        assertGt(btc.balanceOf(user1), initialBtcBalance);
        assertGt(usdt.balanceOf(user1), initialUsdtBalance);
        assertEq(doppiCore.getBuyPositionCount(), 0);
    }

    function test_settle_sells_priceBelowStrike() public {
        // Deposit a sell position
        _depositBTC();

        // Fast forward time and keep price below strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(INITIAL_PRICE)); // Price stays same, below strike

        uint256[] memory readyPositions = doppiCore.getReadySellPositions();
        uint256 initialBalance = btc.balanceOf(user1);

        doppiCore.settle_sells(readyPositions);

        // Should receive original amount + interest
        assertGt(btc.balanceOf(user1), initialBalance);
        assertEq(doppiCore.getSellPositionCount(), 0);
    }

    function test_settle_sells_priceAboveStrike() public {
        // Deposit a sell position
        DoppiCore.DualAssetOffer memory sellOffer = _depositBTC();
        
        // Fast forward time and set price above strike
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(sellOffer.strikePrice + 1000 ether));

        uint256[] memory readyPositions = doppiCore.getReadySellPositions();
        uint256 initialUsdtBalance = usdt.balanceOf(user1);
        uint256 initialBtcBalance = btc.balanceOf(user1);

        doppiCore.settle_sells(readyPositions);

        // Should receive USDT (converted at strike price) + interest in BTC
        assertGt(usdt.balanceOf(user1), initialUsdtBalance);
        assertGt(btc.balanceOf(user1), initialBtcBalance);
        assertEq(doppiCore.getSellPositionCount(), 0);
    }

    function test_adminSwap() public {
        // Deposit a buy position
        _depositUSDT();

        vm.startPrank(admin);
        uint256 amountOut = doppiCore.adminSwap(user1, 25_000 ether, INITIAL_PRICE, 0, true);
        vm.stopPrank();

        assertGt(amountOut, 0);

        // Check position is marked as traded
        DoppiCore.DualAssetPosition memory position = doppiCore.get_buy(user1, 1);
        assertTrue(position.isTraded);
        assertEq(position.swappedAmount, amountOut);
    }

    function test_adminUnwind() public {
        // First setup a position and trade it
        _depositUSDT();

        oracle.setPrice(int256(98_000 ether));
        // Admin swaps first
        vm.startPrank(admin);
        uint256 swappedAmount = doppiCore.adminSwap(user1, 50_000 ether, 98_000 ether, 0, true);
        vm.stopPrank();

        oracle.setPrice(int256(102_000 ether));
        // Then admin unwinds
        vm.startPrank(admin);
        uint256 amountOut = doppiCore.adminUnwind(user1, swappedAmount, 102_000 ether, 0, false);
        vm.stopPrank();

        assertGt(amountOut, 0);

        // Check position is marked as not traded
        DoppiCore.DualAssetPosition memory position = doppiCore.get_buy(user1, 1);
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

    function test_performUpkeep() public {
        // Deposit positions
        _depositUSDT();

        // Fast forward time
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(96_500 ether));
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        assertTrue(upkeepNeeded);

        uint256 initialPositionCount = doppiCore.getBuyPositionCount();
        doppiCore.performUpkeep(performData);

        // Position should be settled
        assertLt(doppiCore.getBuyPositionCount(), initialPositionCount);
    }

    function testFuzz_deposit_buy_amounts(uint256 amount) public {
        amount = bound(amount, 1000 ether, 100_000 ether);
        usdt.mint(user1, amount);

        DoppiCore.DualAssetOffer memory buyOffer = doppiCore.getOffer(true, 1, 0);
        
        DoppiCore.DepositParams memory params = DoppiCore.DepositParams({
            amount: amount,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            validityTime: buyOffer.validUntilTimestamp
        });

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), amount);
        doppiCore.deposit_buy(params);
        vm.stopPrank();

        assertEq(doppiCore.getBuyPositionCount(), 1);
    }

    function testFuzz_deposit_sell_amounts(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 2 ether);
        btc.mint(user1, amount);

        DoppiCore.DualAssetOffer[] memory sellOffers = doppiCore.getSellOffers(1);
        DoppiCore.DepositParams memory params = DoppiCore.DepositParams({
            amount: amount,
            strikeZone: 0,
            strikePrice: sellOffers[0].strikePrice,
            numDays: 1,
            apr: sellOffers[0].apr,
            validityTime: sellOffers[0].validUntilTimestamp
        });

        vm.startPrank(user1);
        btc.approve(address(doppiCore), amount);
        doppiCore.deposit_sell(params);
        vm.stopPrank();

        assertEq(doppiCore.getSellPositionCount(), 1);
    }

    function test_get_positions() public {
        // Initially no positions

        DoppiCore.DualAssetPosition[] memory buyPositions = doppiCore.get_positions_buy();
        DoppiCore.DualAssetPosition[] memory sellPositions = doppiCore.get_positions_sell();
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
        DoppiCore.DualAssetOffer[] memory buyOffers = doppiCore.getBuyOffers(1);

        // User1 deposits
        vm.startPrank(user1);
        usdt.approve(address(doppiCore), 50_000 ether);
        doppiCore.deposit_buy(
            DoppiCore.DepositParams({
                amount: 50_000 ether,
                strikeZone: 0,
                strikePrice: buyOffers[0].strikePrice,
                numDays: 1,
                apr: buyOffers[0].apr,
                validityTime: buyOffers[0].validUntilTimestamp
            })
        );
        vm.stopPrank();

        // User2 deposits
        vm.startPrank(user2);
        usdt.approve(address(doppiCore), 75_000 ether);
        doppiCore.deposit_buy(
            DoppiCore.DepositParams({
                amount: 75_000 ether,
                strikeZone: 1,
                strikePrice: buyOffers[1].strikePrice,
                numDays: 1,
                apr: buyOffers[1].apr,
                validityTime: buyOffers[1].validUntilTimestamp
            })
        );
        vm.stopPrank();

        DoppiCore.DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
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


    function _depositBTC() internal returns (DoppiCore.DualAssetOffer memory) {

        DoppiCore.DualAssetOffer memory sellOffer = doppiCore.getOffer(false, 1, 0);
        DoppiCore.DepositParams memory params = DoppiCore.DepositParams({
            amount: 0.5 ether,
            strikeZone: 0,
            strikePrice: sellOffer.strikePrice,
            numDays: 1,
            apr: sellOffer.apr,
            validityTime: sellOffer.validUntilTimestamp
        });

        vm.startPrank(user1);
        btc.approve(address(doppiCore), params.amount);
        doppiCore.deposit_sell(params);
        vm.stopPrank();
        return sellOffer;
    }
    function _depositUSDT() internal returns (DoppiCore.DualAssetOffer memory) {

        // Deposit a position
        DoppiCore.DualAssetOffer memory buyOffer = doppiCore.getOffer(true, 1, 0);
        DoppiCore.DepositParams memory params = DoppiCore.DepositParams({
            amount: 50_000 ether,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            validityTime: buyOffer.validUntilTimestamp
        });

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), params.amount);
        doppiCore.deposit_buy(params);
        vm.stopPrank();

        return buyOffer;

    }
}
