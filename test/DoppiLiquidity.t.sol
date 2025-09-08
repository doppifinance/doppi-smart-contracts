// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiConfig} from "../src/mainnet/DoppiConfig.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {Swapper} from "../src/test/Swapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DoppiLiquidityTest is Test {
    DoppiLiquidity public doppiLP;
    DoppiLiquidityRouter public router;
    DoppiConfig public doppiConfig;
    MockToken public usdt;
    MockToken public btc;
    MockOracle public oracle;
    Swapper public swapper;

    address public owner = address(this);
    address public user = address(0x1);
    address public treasury = address(0x2);
    address public mockDualAsset = address(0x3);
    address mockForwarder = address(0x5);

    // Price: 100,000 USDT per BTC
    int256 constant ORACLE_PRICE = 100_000e8; // 8 decimals (Chainlink standard)
    uint256 constant USDT_DEPOSIT = 100_000e18; // 100,000 USDT
    uint256 constant BTC_DEPOSIT = 1e18; // 1 BTC

    // Common test amounts
    uint256 constant LARGE_USDT_AMOUNT = 1_000_000e18;
    uint256 constant LARGE_BTC_AMOUNT = 10e18;
    uint256 constant SWAP_AMOUNT_USDT = 50_000e18;
    uint256 constant SWAP_AMOUNT_BTC = 0.5e18;
    uint256 constant LIQUIDITY_FEE = 1000; // 0.1% in basis points (out of 1,000,000)

    function setUp() public {
        // Deploy mock tokens
        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");

        // Deploy mock oracle with 100,000 USDT per BTC price
        oracle = new MockOracle(int256(100_000 ether), 18);

        // deploy doppiConfig
        doppiConfig = new DoppiConfig();

        // Deploy Swapper that will act as both router and pool
        swapper = new Swapper(usdt, btc);
        swapper.setOracle(oracle);
        doppiConfig.setRouter(address(swapper));
        doppiConfig.setQuoter(address(swapper));
        doppiConfig.setTreasury(treasury);
        doppiConfig.setOracle(address(oracle));

        // Deploy doppiLP
        doppiLP =
            new DoppiLiquidity("Dual Asset LP", "DALP", IERC20(address(usdt)), IERC20(address(btc)));

        // Set the mock oracle, router, pool, and quoter
        doppiLP.setDoppiConfig(doppiConfig);
        doppiLP.setDoppiCore(mockDualAsset);
        doppiLP.approveRouter();
        doppiLP.setForwarderAddress(mockForwarder);
        
        // Deploy doppiLPRouter
        router = new DoppiLiquidityRouter(IERC20(address(usdt)), IERC20(address(btc)), doppiLP);

        // Set router entry points as valid entry points in liquidity contract
        doppiLP.setEntryPoint(address(router.entryPointA()), true);
        doppiLP.setEntryPoint(address(router.entryPointB()), true);
        doppiLP.approveEntryPoint(address(router.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(router.entryPointB()), address(btc));

        // Mint tokens to user
        usdt.mint(user, USDT_DEPOSIT * 2); // Extra for multiple tests
        btc.mint(user, BTC_DEPOSIT * 2);

        // Start with empty vaults
    }

    // ===== HELPER FUNCTIONS =====

    function _setupLiquidity(uint256 usdtAmount, uint256 btcAmount) internal {
        usdt.mint(address(doppiLP), usdtAmount);
        btc.mint(address(doppiLP), btcAmount);
        usdt.mint(address(swapper), usdtAmount);
        btc.mint(address(swapper), btcAmount);
    }

    function _setupSwapTest(uint256 usdtAmount, uint256 btcAmount, address actor) internal {
        usdt.mint(actor, usdtAmount);
        btc.mint(actor, btcAmount);
        vm.startPrank(actor);
        usdt.approve(address(doppiLP), usdtAmount);
        btc.approve(address(doppiLP), btcAmount);
        vm.stopPrank();
    }

    // // ===== BASIC FUNCTIONALITY TESTS =====

    function testEqualSharesForEquivalentDeposits() public {
        vm.startPrank(user);

        // Approve router to spend tokens
        usdt.approve(address(router), USDT_DEPOSIT);
        btc.approve(address(router), BTC_DEPOSIT);

        // Record initial state
        uint256 initialTotalSupply = doppiLP.totalSupply();

        // Deposit 100,000 USDT
        uint256 usdtShares = router.deposit(address(usdt), USDT_DEPOSIT);

        // Record state after first deposit
        uint256 totalSupplyAfterUSDT = doppiLP.totalSupply();

        // Deposit 1 BTC (equivalent to 100,000 USDT at current price)
        uint256 btcShares = router.deposit(address(btc), BTC_DEPOSIT);

        // Record final state
        uint256 finalTotalSupply = doppiLP.totalSupply();

        vm.stopPrank();

        // Verify that both deposits return nearly equal shares (within 0.01% tolerance)
        uint256 tolerance = usdtShares / 10000; // 0.01% tolerance
        uint256 difference = usdtShares > btcShares ? usdtShares - btcShares : btcShares - usdtShares;
        assertLt(difference, tolerance, "USDT and BTC deposits should return nearly equal shares");

        // Verify total supply increased correctly
        assertEq(totalSupplyAfterUSDT - initialTotalSupply, usdtShares, "Total supply should increase by USDT shares");
        assertEq(finalTotalSupply - totalSupplyAfterUSDT, btcShares, "Total supply should increase by BTC shares");

        // Verify user's share balances
        assertEq(
            doppiLP.balanceOf(user),
            usdtShares + btcShares,
            "User should have total shares from both deposits"
        );

        // // Log the results for verification
        // emit log_named_uint("USDT shares received", usdtShares);
        // emit log_named_uint("BTC shares received", btcShares);
        // emit log_named_uint("Price used (8 decimals)", uint256(ORACLE_PRICE));
        // emit log_named_uint("USDT deposit amount", USDT_DEPOSIT);
        // emit log_named_uint("BTC deposit amount", BTC_DEPOSIT);
    }

    // ===== SWAP FUNCTIONALITY TESTS =====

    function test_swap_with_liqudity() public {
        uint256 currentPrice = doppiLP.getPrice();

        // Setup liquidity for swaps
        _setupLiquidity(LARGE_USDT_AMOUNT, LARGE_BTC_AMOUNT);
        _setupSwapTest(SWAP_AMOUNT_USDT * 2, SWAP_AMOUNT_BTC * 2, mockDualAsset);

        // Test Buy: USDT for BTC
        uint256 initialUSDTBalance = usdt.balanceOf(mockDualAsset);
        uint256 initialBTCBalance = btc.balanceOf(mockDualAsset);
        uint256 initialTreasuryBalance = usdt.balanceOf(treasury);

        vm.prank(mockDualAsset);
        uint256 amountOut = doppiLP.swap(SWAP_AMOUNT_USDT, currentPrice, true);

        // Verify buy swap results
        assertEq(
            usdt.balanceOf(mockDualAsset),
            initialUSDTBalance - SWAP_AMOUNT_USDT,
            "USDT should be transferred from caller"
        );
        assertGt(btc.balanceOf(mockDualAsset), initialBTCBalance, "BTC should be received by caller");
        
        uint256 expectedFee = SWAP_AMOUNT_USDT * LIQUIDITY_FEE / 1000000;
        uint256 expectedAmountOut = (SWAP_AMOUNT_USDT - expectedFee) * 10 ** 18 / currentPrice;
        assertEq(amountOut, expectedAmountOut, "Buy swap output should match calculation");

        // Test Sell: BTC for USDT
        uint256 usdtBeforeSell = usdt.balanceOf(mockDualAsset);
        uint256 btcBeforeSell = btc.balanceOf(mockDualAsset);
        uint256 treasuryBTCBefore = btc.balanceOf(treasury);

        vm.prank(mockDualAsset);
        uint256 sellAmountOut = doppiLP.swap(SWAP_AMOUNT_BTC, currentPrice, false);

        // Verify sell swap results
        assertEq(btc.balanceOf(mockDualAsset), btcBeforeSell - SWAP_AMOUNT_BTC, "BTC should be transferred from caller");
        assertGt(usdt.balanceOf(mockDualAsset), usdtBeforeSell, "USDT should be received by caller");
        
        uint256 expectedSellFee = SWAP_AMOUNT_BTC * LIQUIDITY_FEE / 1000000;
        uint256 expectedSellAmountOut = (SWAP_AMOUNT_BTC - expectedSellFee) * currentPrice / 10 ** 18;
        assertEq(sellAmountOut, expectedSellAmountOut, "Sell swap output should match calculation");
    }

    function test_swap_without_liqudity() public {
        uint256 currentPrice = doppiLP.getPrice();

        // Setup liquidity for swaps
        _setupSwapTest(SWAP_AMOUNT_USDT * 2, SWAP_AMOUNT_BTC * 2, mockDualAsset);

        // Test DoppiLP has no liquidty
        uint256 initialUSDTBalance = usdt.balanceOf(address(doppiLP));
        uint256 initialBTCBalance = btc.balanceOf(address(doppiLP));
        assertEq(initialUSDTBalance, 0);
        assertEq(initialBTCBalance, 0);
        
        // Test BUY: USDT for BTC
        vm.prank(mockDualAsset);
        uint256 amountOut = doppiLP.swap(SWAP_AMOUNT_USDT, currentPrice, true);
        uint256 expectedFee = SWAP_AMOUNT_USDT * LIQUIDITY_FEE / 1000000;
        uint256 expectedAmountOut = (SWAP_AMOUNT_USDT - expectedFee) * 10 ** 18 / currentPrice;
        // extra fee + slippage when swap outside of doppiLP (-1%)
        uint256 expectedAmountOutAfterDexFee = expectedAmountOut * 9900 / 10000;
        assertEq(amountOut, expectedAmountOutAfterDexFee, "Buy swap output should match calculation");

        // Test Sell: BTC for USDT
        uint256 usdtBeforeSell = usdt.balanceOf(mockDualAsset);
        uint256 btcBeforeSell = btc.balanceOf(mockDualAsset);
        uint256 treasuryBTCBefore = btc.balanceOf(treasury);

        vm.prank(mockDualAsset);
        uint256 sellAmountOut = doppiLP.swap(SWAP_AMOUNT_BTC, currentPrice, false);
        uint256 expectedSellFee = SWAP_AMOUNT_BTC * LIQUIDITY_FEE / 1000000;
        uint256 expectedSellAmountOut = (SWAP_AMOUNT_BTC - expectedSellFee) * currentPrice / 10 ** 18;
        // extra fee + slippage when swap outside of doppiLP (-1%)
        uint256 expectedSellAmountOutAfterDexFee = expectedSellAmountOut * 9900 / 10000;
        assertEq(sellAmountOut, expectedSellAmountOutAfterDexFee, "Sell swap output should match calculation");
    }

    // ===== HEDGE SWAP FUNCTIONALITY TESTS =====

    function test_hedgeswap_with_balance() public {
        
        _setupLiquidity(LARGE_USDT_AMOUNT, LARGE_BTC_AMOUNT);
        uint256 currentPrice = doppiLP.getPrice();

        // Test hedge swap buy calculation
        uint256 hedgeBuyAmount = 25_000e18;
        vm.prank(mockDualAsset);
        (uint256 swappedHedgeAmount, uint256 hedgePrice) = doppiLP.hedgeSwap(hedgeBuyAmount, currentPrice, true);

        uint256 expectedBuyAmountOut = hedgeBuyAmount * 10 ** 18 / currentPrice;
        expectedBuyAmountOut = expectedBuyAmountOut *  9900 / 10000;
        assertEq(swappedHedgeAmount, expectedBuyAmountOut, "Hedge swap buy output should match calculation");

        // Test hedge swap sell calculation
        uint256 hedgeSellAmount = 0.25e18;
        vm.prank(mockDualAsset);
        (swappedHedgeAmount, hedgePrice) =  doppiLP.hedgeSwap(hedgeSellAmount, currentPrice, false);

        uint256 expectedSellAmountOut = hedgeSellAmount * currentPrice / 10 ** 18;
        expectedSellAmountOut = expectedSellAmountOut *  9900 / 10000;
        assertEq(swappedHedgeAmount, expectedSellAmountOut, "Hedge swap sell output should match calculation");
    }

    function test_hedgeswap_with_no_balance() public {
        
        uint256 currentPrice = doppiLP.getPrice();

        // Test hedge swap buy calculation
        uint256 hedgeBuyAmount = 25_000e18;
        vm.prank(mockDualAsset);
        (uint256 swappedHedgeAmount, uint256 hedgePrice) = doppiLP.hedgeSwap(hedgeBuyAmount, currentPrice, true);
        assertEq(swappedHedgeAmount, 0, "Hedge swap buy output should be zero");

        // Test hedge swap sell calculation
        uint256 hedgeSellAmount = 0.25e18;
        vm.prank(mockDualAsset);
        (swappedHedgeAmount, hedgePrice) =  doppiLP.hedgeSwap(hedgeSellAmount, currentPrice, false);
        assertEq(swappedHedgeAmount, 0, "Hedge swap sell output should be 0");
    }

    // ===== UPKEEP SYSTEM TESTS =====

    function testCheckUpkeepWithNoPriceOrders() public view {
        (bool upkeepNeeded, bytes memory performData) = doppiLP.checkUpkeep("");

        assertFalse(upkeepNeeded, "Should not need upkeep with no price orders");
        assertEq(performData, bytes(""), "PerformData should be empty");
    }

    // ===== UTILITY FUNCTION TESTS =====

    function testTotalAssetsCalculation() public {
        // Add some assets to the contract
        uint256 usdtAmount = 100_000e18;
        uint256 btcAmount = 1e18;

        usdt.mint(address(doppiLP), usdtAmount);
        btc.mint(address(doppiLP), btcAmount);

        uint256 totalInAssetA = doppiLP.totalAssetsInAssetA();
        uint256 totalInAssetB = doppiLP.totalAssetsInAssetB();
        uint256 currentPrice = doppiLP.getPrice();

        // Verify calculations
        uint256 expectedTotalInAssetA = usdtAmount + (btcAmount * currentPrice / 10 ** 18);
        uint256 expectedTotalInAssetB = btcAmount + (usdtAmount * 10 ** 18 / currentPrice);

        assertEq(totalInAssetA, expectedTotalInAssetA, "Total assets in USDT should be correct");
        assertEq(totalInAssetB, expectedTotalInAssetB, "Total assets in BTC should be correct");

        // emit log_named_uint("Total assets in USDT", totalInAssetA);
        // emit log_named_uint("Total assets in BTC", totalInAssetB);
    }
    // ===== INTEGRATION TESTS =====
    function testCheckUpkeep_performUp_buy() public {
        uint256 currentPrice = doppiLP.getPrice();
        // Setup substantial liquidity for testing
        _setupLiquidity(LARGE_USDT_AMOUNT * 5, LARGE_BTC_AMOUNT * 5);
        _setupSwapTest(SWAP_AMOUNT_USDT * 4, SWAP_AMOUNT_BTC * 4, mockDualAsset);

        // Step 1: Create price orders through swaps at different price points
        // Swap at current price
        
        oracle.setPrice(int256(currentPrice));
        vm.prank(mockDualAsset);
        doppiLP.swap(SWAP_AMOUNT_USDT, currentPrice, true); // Buy order at current price

        // Swap at +5% price
        uint256 priceUp5Percent = currentPrice * 105 / 100;
        oracle.setPrice(int256(priceUp5Percent));
        vm.prank(mockDualAsset);
        doppiLP.swap(SWAP_AMOUNT_USDT, priceUp5Percent, true); // Buy at +5%

        // Swap at -5% price
        uint256 priceDown5Percent = currentPrice * 95 / 100;
        oracle.setPrice(int256(priceDown5Percent));

        // Check if price change triggers arbitrage opportunity
        (bool upkeepNeededAfterPriceChange, bytes memory newPerformData) = doppiLP.checkUpkeep("");
        assertTrue(upkeepNeededAfterPriceChange, "Upkeep should be needed after price change");
        
        // Price change created arbitrage opportunity
        uint256 preUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 preUpkeepBTC = btc.balanceOf(address(doppiLP));
        uint256 preUpkeepToBuyPricesLength = doppiLP.getToBuyPricesLength();

        vm.prank(mockForwarder);
        doppiLP.performUpkeep(newPerformData);

        uint256 postUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 postUpkeepBTC = btc.balanceOf(address(doppiLP));
        uint256 postUpkeepToBuyPricesLength = doppiLP.getToBuyPricesLength();
        
        assertGt(postUpkeepBTC, preUpkeepBTC, "BTC balance should increase after unwind");
        assertEq(postUpkeepToBuyPricesLength, preUpkeepToBuyPricesLength - 2, "ToBuyPrices length should decrease after upkeep");
        assertEq(postUpkeepUSDT, LARGE_USDT_AMOUNT * 5, "USDT balance back to initial position");

    }

    function testCheckUpkeep_performUp_sell() public {
        uint256 currentPrice = doppiLP.getPrice();
        // Setup substantial liquidity for testing
        _setupLiquidity(LARGE_USDT_AMOUNT * 5, LARGE_BTC_AMOUNT * 5);
        _setupSwapTest(SWAP_AMOUNT_USDT * 4, SWAP_AMOUNT_BTC * 4, mockDualAsset);

        // Swap at current price
        oracle.setPrice(int256(currentPrice));
        vm.prank(mockDualAsset);
        doppiLP.swap(SWAP_AMOUNT_BTC, currentPrice, false); // Sell order at current price

        // Swap at +5% price
        uint256 priceUp5Percent = currentPrice * 105 / 100;
        oracle.setPrice(int256(priceUp5Percent));

        // Check if price change triggers arbitrage opportunity
        (bool upkeepNeededAfterPriceChange, bytes memory newPerformData) = doppiLP.checkUpkeep("");
        assertTrue(upkeepNeededAfterPriceChange, "Upkeep should be needed after price change");

        // Price change created arbitrage opportunity
        uint256 preUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 preUpkeepBTC = btc.balanceOf(address(doppiLP));
        uint256 preUpkeepToSellPricesLength = doppiLP.getToSellPricesLength();
        
        vm.prank(mockForwarder);
        doppiLP.performUpkeep(newPerformData);

        uint256 postUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 postUpkeepBTC = btc.balanceOf(address(doppiLP));
        uint256 postUpkeepToSellPricesLength = doppiLP.getToSellPricesLength();

        assertGt(postUpkeepUSDT, preUpkeepUSDT, "USDT balance should increase after unwind");
        assertEq(postUpkeepToSellPricesLength, preUpkeepToSellPricesLength - 1, "ToSellPrices length should decrease after upkeep");
        assertEq(postUpkeepBTC, LARGE_BTC_AMOUNT * 5, "BTC balance back to initial position");

    }

    function testCheckUpkeep_performUp_buysell() public {
        uint256 currentPrice = doppiLP.getPrice();
        // Setup substantial liquidity for testing
        _setupLiquidity(LARGE_USDT_AMOUNT * 5, LARGE_BTC_AMOUNT * 5);
        _setupSwapTest(SWAP_AMOUNT_USDT * 4, SWAP_AMOUNT_BTC * 4, mockDualAsset);

        // Step 1: Create price orders through swaps at different price points
        // Swap at current price
        oracle.setPrice(int256(currentPrice));
        vm.prank(mockDualAsset);
        doppiLP.swap(SWAP_AMOUNT_USDT, currentPrice, true); // Buy order at current price
        vm.prank(mockDualAsset);
        doppiLP.swap(SWAP_AMOUNT_BTC, currentPrice, false); // Sell order at current price

        // Swap at +5% price
        uint256 priceUp5Percent = currentPrice * 102 / 100;
        oracle.setPrice(int256(priceUp5Percent));
        vm.prank(mockDualAsset);
        doppiLP.swap(SWAP_AMOUNT_USDT, priceUp5Percent, true); // Buy at +5%

        // Swap at -5% price
        uint256 priceDown5Percent = currentPrice * 101 / 100;
        oracle.setPrice(int256(priceDown5Percent));

        // Price change created arbitrage opportunity
        uint256 preUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 preUpkeepBTC = btc.balanceOf(address(doppiLP));
        uint256 preUpkeepToBuyPricesLength = doppiLP.getToBuyPricesLength();

        // Check if price change triggers arbitrage opportunity
        (bool upkeepNeededAfterPriceChange, bytes memory newPerformData) = doppiLP.checkUpkeep("");
        assertTrue(upkeepNeededAfterPriceChange, "Upkeep should be needed after price change");
        vm.prank(mockForwarder);
        doppiLP.performUpkeep(newPerformData);

        uint256 postUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 postUpkeepBTC = btc.balanceOf(address(doppiLP));
        uint256 postUpkeepToBuyPricesLength = doppiLP.getToBuyPricesLength();
        
        // price down to 95000, unwind the last order
        priceDown5Percent = currentPrice * 95 / 100;
        oracle.setPrice(int256(priceDown5Percent));

        // Price change created arbitrage opportunity
        preUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        preUpkeepBTC = btc.balanceOf(address(doppiLP));
        preUpkeepToBuyPricesLength = doppiLP.getToBuyPricesLength();

        // Check if price change triggers arbitrage opportunity
        (upkeepNeededAfterPriceChange, newPerformData) = doppiLP.checkUpkeep("");
        assertTrue(upkeepNeededAfterPriceChange, "Upkeep should be needed after price change");
        vm.prank(mockForwarder);
        doppiLP.performUpkeep(newPerformData);
        
        postUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        postUpkeepBTC = btc.balanceOf(address(doppiLP));
        postUpkeepToBuyPricesLength = doppiLP.getToBuyPricesLength();
        uint256 postUpkeepToSellPricesLength = doppiLP.getToSellPricesLength();

        assertGt(postUpkeepBTC, LARGE_BTC_AMOUNT * 5, "BTC balance should increase after unwind");
        assertGt(postUpkeepUSDT, LARGE_USDT_AMOUNT * 5, "USDT balance should increase after unwind");
        assertEq(postUpkeepToBuyPricesLength, 0, "ToBuyPrices length should decrease after upkeep");
        assertEq(postUpkeepToSellPricesLength, 0, "ToSellPrices length should decrease after upkeep");
    }

}
