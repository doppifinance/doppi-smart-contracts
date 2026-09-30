// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {Swapper} from "../src/test/Swapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestParamLib} from "../src/Library/TestParamLib.sol";
import "../src/mainnet/DoppiLiquidityTypes.sol";


contract DoppiLiquidityTest is Test {
    DoppiLiquidity public doppiLP;
    DoppiLiquidityRouter public router;
    MockToken public usdt;
    MockToken public btc;
    MockOracle public oracle;
    Swapper public swapper;
    ConfigParam configLP;

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

    event Swapped(address indexed trader, address assetIn, address assetOut, uint256 amountIn, uint256 amountOut, uint256 price);
    event UnwindPerformed(bool isNetBuy, uint256 totalAmount, uint256 totalAmountOut);
    
    function setUp() public {

        vm.warp(1735689600);
 
        // Deploy mock tokens
        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");

        // Deploy mock oracle with 100,000 USDT per BTC price
        oracle = new MockOracle(int256(100_000 * 1e8), 8);

        // Deploy Swapper that will act as both router and pool
        swapper = new Swapper(usdt, btc);
        swapper.setOracle(oracle);
        
        // Deploy doppiLP
        doppiLP =
            new DoppiLiquidity("Dual Asset LP", "DALP", address(usdt), address(btc));

        // Set the mock oracle, router, and pool
        configLP = TestParamLib.get_configLP();
        configLP.chainLinkFeed = address(oracle);
        configLP.router = address(swapper);
        doppiLP.setConfig(configLP);
        doppiLP.setDoppiCore(mockDualAsset);
        doppiLP.approveRouter();
        doppiLP.setForwarderAddress(mockForwarder);
        
        // Deploy doppiLPRouter
        router = new DoppiLiquidityRouter(IERC20(address(usdt)), IERC20(address(btc)), doppiLP);

        // Set router entry points as valid entry points in liquidity contract
        doppiLP.setEntryPoint(address(router.entryPointA()), true);
        doppiLP.setEntryPoint(address(router.entryPointB()), true);

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

    // ===== BASIC FUNCTIONALITY TESTS =====

    function test_setConfig_acceptsMaxSlippage() public {
        configLP.slippage = doppiLP.MAX_SLIPPAGE_BPS();
        doppiLP.setConfig(configLP);
    }

    function test_setConfig_revertsAboveMaxSlippage() public {
        configLP.slippage = doppiLP.MAX_SLIPPAGE_BPS() + 1;
        vm.expectRevert(DoppiLiquidity.SlippageTooHigh.selector);
        doppiLP.setConfig(configLP);
    }

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
        uint256 expectedAmountOut = (SWAP_AMOUNT_USDT - expectedFee) * 10 ** 8 / currentPrice;
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
        uint256 expectedSellAmountOut = (SWAP_AMOUNT_BTC - expectedSellFee) * currentPrice / 10 ** 8;
        // extra fee + slippage when swap outside of doppiLP (-1%)
        uint256 expectedSellAmountOutAfterDexFee = expectedSellAmountOut * 9900 / 10000;
        assertEq(sellAmountOut, expectedSellAmountOutAfterDexFee, "Sell swap output should match calculation");
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
        uint256 expectedTotalInAssetA = usdtAmount + (btcAmount * currentPrice / 10 ** 8);
        uint256 expectedTotalInAssetB = btcAmount + (usdtAmount * 10 ** 8 / currentPrice);

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


        uint256 preUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 preUpkeepBTC = btc.balanceOf(address(doppiLP));
        console.log(preUpkeepUSDT, preUpkeepBTC, "preUpkeepUSDT, preUpkeepBTC");

        // Step 1: Create price orders through swaps at different price points
        // Swap at current price
        oracle.setPrice(int256(currentPrice));
        uint256 payout = SWAP_AMOUNT_USDT * 1e8 / currentPrice; 
        vm.prank(mockDualAsset);
        doppiLP.settle(SWAP_AMOUNT_USDT, payout, currentPrice, true);
        
        // Swap at +5% price
        uint256 priceUp5Percent = currentPrice * 105 / 100;
        payout = SWAP_AMOUNT_USDT * 1e8 / priceUp5Percent; 
        oracle.setPrice(int256(priceUp5Percent));
        vm.prank(mockDualAsset);
        doppiLP.settle(SWAP_AMOUNT_USDT, payout, priceUp5Percent, true);
        
        // Swap at -5% price
        uint256 priceDown5Percent = currentPrice * 95 / 100;
        oracle.setPrice(int256(priceDown5Percent));

        (uint256 lowerBound, uint256 upperBound) = doppiLP.getLowerUpperBound();
        console.log(lowerBound, upperBound, "lowerBound, upperBound");
        assertEq(lowerBound, 10000000000000);
        assertEq(upperBound, 10500000000000);
        
        // _displayBound(lowerBound, upperBound);
        // Check if price change triggers unwind opportunity
        (bool upkeepNeededAfterPriceChange, bytes memory newPerformData) = doppiLP.checkUpkeep("");
        assertTrue(upkeepNeededAfterPriceChange, "Upkeep should be needed after price change");
        
        // Price change created unwind opportunity
        preUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        preUpkeepBTC = btc.balanceOf(address(doppiLP));
        console.log(preUpkeepUSDT, preUpkeepBTC, "preUpkeepUSDT, preUpkeepBTC");
        
        vm.prank(mockForwarder);
        doppiLP.performUpkeep(newPerformData);

        (lowerBound, upperBound) = doppiLP.getLowerUpperBound();
        console.log(lowerBound, upperBound, "lowerBound, upperBound");
        // _displayBound(lowerBound, upperBound);

        uint256 postUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 postUpkeepBTC = btc.balanceOf(address(doppiLP));
        console.log(postUpkeepUSDT, postUpkeepBTC, "postUpkeepUSDT, postUpkeepBTC");
        assertGt(postUpkeepBTC, preUpkeepBTC, "BTC balance should increase after unwind");
        assertEq(postUpkeepUSDT, LARGE_USDT_AMOUNT * 5, "USDT balance back to initial position");

    }

    function testCheckUpkeep_performUp_sell() public {
        uint256 currentPrice = doppiLP.getPrice();
        // Setup substantial liquidity for testing
        _setupLiquidity(LARGE_USDT_AMOUNT * 5, LARGE_BTC_AMOUNT * 5);
        _setupSwapTest(SWAP_AMOUNT_USDT * 4, SWAP_AMOUNT_BTC * 4, mockDualAsset);

        // Swap at current price
        oracle.setPrice(int256(currentPrice));
        uint256 payout = SWAP_AMOUNT_BTC * currentPrice / 1e8; 
        vm.prank(mockDualAsset);
        doppiLP.settle(SWAP_AMOUNT_BTC, payout, currentPrice, false);
        
        // Swap at +5% price
        uint256 priceUp5Percent = currentPrice * 105 / 100;
        oracle.setPrice(int256(priceUp5Percent));

        // Check if price change triggers arbitrage opportunity
        (bool upkeepNeededAfterPriceChange, bytes memory newPerformData) = doppiLP.checkUpkeep("");
        assertTrue(upkeepNeededAfterPriceChange, "Upkeep should be needed after price change");

        // Price change created arbitrage opportunity
        uint256 preUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 preUpkeepBTC = btc.balanceOf(address(doppiLP));
        
        vm.prank(mockForwarder);
        doppiLP.performUpkeep(newPerformData);

        uint256 postUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 postUpkeepBTC = btc.balanceOf(address(doppiLP));

        assertGt(postUpkeepUSDT, preUpkeepUSDT, "USDT balance should increase after unwind");
        assertEq(postUpkeepBTC, LARGE_BTC_AMOUNT * 5, "BTC balance back to initial position");

    }

    function testCheckUpkeep_performUp_buysell() public {
        uint256 currentPrice = doppiLP.getPrice();
        // Setup substantial liquidity for testing
        _setupLiquidity(LARGE_USDT_AMOUNT * 5, LARGE_BTC_AMOUNT * 5);
        _setupSwapTest(SWAP_AMOUNT_USDT * 4, SWAP_AMOUNT_BTC * 4, mockDualAsset);

        // Step 1: Create price orders through swaps at different price points
        // Swap at current price
        uint256 payout = SWAP_AMOUNT_USDT * 1e8 / currentPrice;
        oracle.setPrice(int256(currentPrice));
        vm.prank(mockDualAsset);
        doppiLP.settle(SWAP_AMOUNT_USDT, payout, currentPrice, true);
        
        payout = SWAP_AMOUNT_BTC * currentPrice / 1e8;
        vm.prank(mockDualAsset);
        doppiLP.settle(SWAP_AMOUNT_BTC, payout, currentPrice, false);

        // Swap at +5% price
        uint256 priceUp5Percent = currentPrice * 102 / 100;
        oracle.setPrice(int256(priceUp5Percent));
        vm.prank(mockDualAsset);
        payout = SWAP_AMOUNT_USDT * 1e8 / priceUp5Percent;
        doppiLP.settle(SWAP_AMOUNT_USDT, payout, priceUp5Percent, true);

        // Swap at -5% price
        uint256 priceDown5Percent = currentPrice * 101 / 100;
        oracle.setPrice(int256(priceDown5Percent));

        // Price change created arbitrage opportunity
        uint256 preUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 preUpkeepBTC = btc.balanceOf(address(doppiLP));

        // Check if price change triggers arbitrage opportunity
        (bool upkeepNeededAfterPriceChange, bytes memory newPerformData) = doppiLP.checkUpkeep("");
        assertTrue(upkeepNeededAfterPriceChange, "Upkeep should be needed after price change");
        vm.prank(mockForwarder);
        doppiLP.performUpkeep(newPerformData);

        uint256 postUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        uint256 postUpkeepBTC = btc.balanceOf(address(doppiLP));
        
        // price down to 95000, unwind the last order
        priceDown5Percent = currentPrice * 95 / 100;
        oracle.setPrice(int256(priceDown5Percent));

        // Price change created arbitrage opportunity
        preUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        preUpkeepBTC = btc.balanceOf(address(doppiLP));

        // Check if price change triggers arbitrage opportunity
        (upkeepNeededAfterPriceChange, newPerformData) = doppiLP.checkUpkeep("");
        assertTrue(upkeepNeededAfterPriceChange, "Upkeep should be needed after price change");
        vm.prank(mockForwarder);
        doppiLP.performUpkeep(newPerformData);
        
        postUpkeepUSDT = usdt.balanceOf(address(doppiLP));
        postUpkeepBTC = btc.balanceOf(address(doppiLP));

        assertGt(postUpkeepBTC, LARGE_BTC_AMOUNT * 5, "BTC balance should increase after unwind");
        assertGt(postUpkeepUSDT, LARGE_USDT_AMOUNT * 5, "USDT balance should increase after unwind");
    }

    // Event Emit 
    function test_Swapped_BUY_DEX_EmitsEvent() public {
        uint256 currentPrice = doppiLP.getPrice();

        _setupSwapTest(SWAP_AMOUNT_USDT * 2, SWAP_AMOUNT_BTC * 2, mockDualAsset);

        vm.expectEmit(true, true, true, true);
        emit Swapped(
            address(mockDualAsset),
            address(usdt),
            address(btc),
            SWAP_AMOUNT_USDT,
            494505000000000000,
            10101010101010
        );    

        vm.prank(mockDualAsset);
        uint256 amountOut = doppiLP.swap(SWAP_AMOUNT_USDT, currentPrice, true);
        // console.log(amountOut);
    }

    function test_Swapped_SELL_DEX_EmitsEvent() public {
        
        uint256 currentPrice = doppiLP.getPrice();
        _setupSwapTest(SWAP_AMOUNT_USDT * 4, SWAP_AMOUNT_BTC * 4, mockDualAsset);

        // Swap at current price
        oracle.setPrice(int256(currentPrice));
        
        vm.expectEmit(true, true, true, true);
        emit Swapped(
            address(mockDualAsset),
            address(btc),
            address(usdt),
            SWAP_AMOUNT_BTC,
            49450500000000000000000,
            99_000 * 1e8
        );    

        vm.prank(mockDualAsset);
        uint256 amountOut = doppiLP.swap(SWAP_AMOUNT_BTC, currentPrice, false); // Sell order at current price
        // console.log(amountOut);
    }

    function test_UnwindPerformedSwapped_EmitsEvent() public {
        uint256 currentPrice = doppiLP.getPrice();

        // Setup liquidity for swaps
        _setupLiquidity(LARGE_USDT_AMOUNT, LARGE_BTC_AMOUNT);
        _setupSwapTest(SWAP_AMOUNT_USDT * 2, SWAP_AMOUNT_BTC * 2, mockDualAsset);

        uint256 payout = SWAP_AMOUNT_USDT * 1e8 / currentPrice; 
        vm.prank(mockDualAsset);
        doppiLP.settle(SWAP_AMOUNT_USDT, payout, currentPrice, true);
        
        // Swap at -5% price
        uint256 priceDown5Percent = currentPrice * 95 / 100;
        oracle.setPrice(int256(priceDown5Percent));

        // Check if price change triggers arbitrage opportunity
        (bool upkeepNeededAfterPriceChange, bytes memory newPerformData) = doppiLP.checkUpkeep("");
        
        vm.expectEmit(true, true, true, true);
        emit UnwindPerformed(
            true,
            50000000000000000000000,
            521052631578947367
        );   

        vm.prank(mockForwarder);
        doppiLP.performUpkeep(newPerformData);

    }

    function test_UnwindPerformedSwapped_SELL_EmitsEvent() public {
        
        uint256 currentPrice = doppiLP.getPrice();
        // Setup substantial liquidity for testing
        _setupLiquidity(LARGE_USDT_AMOUNT * 5, LARGE_BTC_AMOUNT * 5);
        _setupSwapTest(SWAP_AMOUNT_USDT * 4, SWAP_AMOUNT_BTC * 4, mockDualAsset);

        // Swap at current price
        oracle.setPrice(int256(currentPrice));

        uint256 payout = SWAP_AMOUNT_BTC * currentPrice / 1e8; 
        vm.prank(mockDualAsset);
        doppiLP.settle(SWAP_AMOUNT_BTC, payout, currentPrice, false);
        
        // Swap at +5% price
        uint256 priceDown5Percent = currentPrice * 105 / 100;
        oracle.setPrice(int256(priceDown5Percent));

        // Check if price change triggers arbitrage opportunity
        (bool upkeepNeededAfterPriceChange, bytes memory newPerformData) = doppiLP.checkUpkeep("");
        
        vm.expectEmit(true, true, true, true);
        emit UnwindPerformed(
            false,
            500000000000000000,
            51975000000000000000000
        );   

        vm.prank(mockForwarder);
        doppiLP.performUpkeep(newPerformData);
    }

    function _displayBound(uint256 lowerBound, uint256 upperBound) internal view {
        
        if(lowerBound == 0 && upperBound == 0) return;
        for (uint256 price = upperBound; price >= lowerBound; ) {
            // console.log(price, "price");
            bool isBuy = true;
            uint256 amount = doppiLP.amountToBuy(price);
            
            if(amount == 0){
                isBuy = false;
                amount = doppiLP.amountToSell(price);
            }
            console.log(isBuy, price, amount);
            price -= (500 * 1e8); 
        }

    }
}
