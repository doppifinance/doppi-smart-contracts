// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC7575} from "../src/Interface/IERC7575.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {Swapper} from "../src/test/Swapper.sol";
import {TestParamLib} from "../src/Library/TestParamLib.sol";
import "../src/mainnet/DoppiLiquidityTypes.sol";


contract DoppiLiquidityRouterTest is Test {
    DoppiLiquidityRouter public router;
    DoppiLiquidity public doppiLP;
    MockToken public usdt;
    MockToken public btc;
    MockOracle public oracle;
    Swapper public swapper;
    ConfigParam configLP;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);

    event Deposited(address indexed user, uint256 amount, address asset, uint256 shares);
    event Redeemed(address indexed user, uint256 shares, uint256 assetsA, uint256 assetsB);
    
    function setUp() public {
        vm.warp(1735689600);
        vm.startPrank(owner);
        
        // Deploy mock tokens
        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");

        // Deploy mock oracle with 100,000 USDT per BTC price
        oracle = new MockOracle(int256(100_000 * 1e8), 8);
        // Deploy Swapper that will act as both router and pool
        swapper = new Swapper(usdt, btc);
        swapper.setOracle(MockOracle(oracle)); 
        
        // Deploy doppiLP
        doppiLP =
            new DoppiLiquidity("Dual Asset LP", "DALP", IERC20(address(usdt)), IERC20(address(btc)));

        // Deploy doppiLPRouter
        router = new DoppiLiquidityRouter(IERC20(address(usdt)), IERC20(address(btc)), doppiLP);

        
        // Setup liquidity pool
        configLP = TestParamLib.get_configLP();
        configLP.chainLinkFeed = address(oracle);
        configLP.quoter = address(swapper);
        configLP.router = address(swapper);
        doppiLP.setConfig(configLP);

        doppiLP.setDoppiCore(address(0x4)); // Mock core address
        doppiLP.setDoppiTraderFactory(address(0x5)); // Mock factory address
        doppiLP.approveRouter();
        doppiLP.setEntryPoint(address(router.entryPointA()), true);
        doppiLP.setEntryPoint(address(router.entryPointB()), true);

        // Approve router for tokens
        usdt.approve(address(router), type(uint256).max);
        btc.approve(address(router), type(uint256).max);
        
        // Transfer tokens to users
        usdt.mint(user1, 10000000 * 10 ** usdt.decimals());
        usdt.mint(user2, 10000000 * 10 ** usdt.decimals());
        btc.mint(user1, 1000 * 10 ** btc.decimals());
        btc.mint(user2, 1000 * 10 ** btc.decimals());
        
        vm.stopPrank();
    }

    function test_Constructor() public {
        assertEq(address(router.doppiLP()), address(doppiLP));
        assertEq(router.assetA(), address(usdt));
        assertEq(router.assetB(), address(btc));
        assertTrue(address(router.entryPointA()) != address(0));
        assertTrue(address(router.entryPointB()) != address(0));
    }

    function test_Depositusdt() public {
        vm.startPrank(user1);
        
        uint256 depositAmount = 100 * 10 ** usdt.decimals();
        uint256 initialBalance = usdt.balanceOf(user1);
        
        // Approve router to spend tokens
        usdt.approve(address(router), depositAmount);
        
        // Deposit Asset A
        uint256 shares = router.deposit(address(usdt), depositAmount);
        
        // Check balances
        assertEq(usdt.balanceOf(user1), initialBalance - depositAmount);
        assertTrue(shares > 0);
        
        // Check that user received LP tokens
        uint256 lpBalance = doppiLP.balanceOf(user1);
        assertEq(lpBalance, shares);
        
        vm.stopPrank();
    }

    function test_Depositbtc() public {
        vm.startPrank(user1);
        
        uint256 depositAmount = 100 * 10 ** btc.decimals();
        uint256 initialBalance = btc.balanceOf(user1);
        
        // Approve router to spend tokens
        btc.approve(address(router), depositAmount);
        
        // Deposit Asset B
        uint256 shares = router.deposit(address(btc), depositAmount);
        
        // Check balances
        assertEq(btc.balanceOf(user1), initialBalance - depositAmount);
        assertTrue(shares > 0);
        
        // Check that user received LP tokens
        uint256 lpBalance = doppiLP.balanceOf(user1);
        assertEq(lpBalance, shares);
        
        vm.stopPrank();
    }

    function test_DepositRevertsWithInvalidAsset() public {
        vm.startPrank(user1);
        
        address invalidAsset = address(0x999);
        uint256 depositAmount = 100 * 10 ** 18;
        
        vm.expectRevert();
        router.deposit(invalidAsset, depositAmount);
        
        vm.stopPrank();
    }

    function test_DepositRevertsWhenPaused() public {
        vm.startPrank(owner);
        router.setPause();
        vm.stopPrank();
        
        vm.startPrank(user1);
        uint256 depositAmount = 100 * 10 ** usdt.decimals();
        usdt.approve(address(router), depositAmount);
        
        vm.expectRevert("EnforcedPause()");
        router.deposit(address(usdt), depositAmount);
        
        vm.stopPrank();
    }

    function test_Redeem() public {
        // First deposit some assets
        vm.startPrank(user1);
        
        uint256 depositAmount = 100 * 10 ** usdt.decimals();
        usdt.approve(address(router), depositAmount);
        uint256 shares = router.deposit(address(usdt), depositAmount);
        
        // Approve router to spend LP tokens
        doppiLP.approve(address(router), shares);
        
        // Get initial balances
        uint256 initialusdtBalance = usdt.balanceOf(user1);
        uint256 initialLPBalance = doppiLP.balanceOf(user1);
        
        // Redeem
        router.redeem(shares);
        
        // Check balances after redemption
        assertEq(doppiLP.balanceOf(user1), initialLPBalance - shares);
        assertTrue(usdt.balanceOf(user1) > initialusdtBalance);
        
        vm.stopPrank();
    }

    function test_RedeemPartial() public {
        vm.startPrank(user1);
        
        uint256 depositAmount = 100 * 10 ** usdt.decimals();
        usdt.approve(address(router), depositAmount);
        uint256 shares = router.deposit(address(usdt), depositAmount);
        
        // Redeem half
        uint256 redeemAmount = shares / 2;
        doppiLP.approve(address(router), redeemAmount);
        
        uint256 initialLPBalance = doppiLP.balanceOf(user1);
        router.redeem(redeemAmount);
        
        assertEq(doppiLP.balanceOf(user1), initialLPBalance - redeemAmount);
        
        vm.stopPrank();
    }

    function test_MultipleUsersDeposit() public {
        // User 1 deposits Asset A
        vm.startPrank(user1);
        uint256 depositAmount1 = 100 * 10 ** usdt.decimals();
        usdt.approve(address(router), depositAmount1);
        uint256 shares1 = router.deposit(address(usdt), depositAmount1);
        vm.stopPrank();
        
        // User 2 deposits Asset B
        vm.startPrank(user2);
        uint256 depositAmount2 = 50 * 10 ** btc.decimals();
        btc.approve(address(router), depositAmount2);
        uint256 shares2 = router.deposit(address(btc), depositAmount2);
        vm.stopPrank();
        
        // Check that both users received LP tokens
        assertTrue(shares1 > 0);
        assertTrue(shares2 > 0);
        assertEq(doppiLP.balanceOf(user1), shares1);
        assertEq(doppiLP.balanceOf(user2), shares2);
    }

    function test_PauseUnpause() public {
        vm.startPrank(owner);
        
        // Check initial state is unpaused
        assertFalse(router.paused());
        
        // Pause
        router.setPause();
        assertTrue(router.paused());
        
        // Unpause
        router.setUnPause();
        assertFalse(router.paused());
        
        vm.stopPrank();
    }

    function test_OnlyOwnerCanPause() public {
        vm.startPrank(user1);
        
        vm.expectRevert();
        router.setPause();
        
        vm.expectRevert();
        router.setUnPause();
        
        vm.stopPrank();
    }

    function test_EntryPointContracts() public {
        // Test that entry points are properly configured
        IERC7575 entryPointA = router.entryPointA();
        IERC7575 entryPointB = router.entryPointB();
        
        assertTrue(address(entryPointA) != address(0));
        assertTrue(address(entryPointB) != address(0));
        assertTrue(address(entryPointA) != address(entryPointB));
    }

    function test_RedeemWithoutApprovalReverts() public {
        vm.startPrank(user1);
        
        uint256 depositAmount = 100 * 10 ** usdt.decimals();
        usdt.approve(address(router), depositAmount);
        uint256 shares = router.deposit(address(usdt), depositAmount);
        
        // Try to redeem without approval
        vm.expectRevert();
        router.redeem(shares);
        
        vm.stopPrank();
    }

    function test_Fuzz_DepositVariousAmounts(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1000 * 10 ** usdt.decimals());
        vm.assume(amount <= usdt.balanceOf(user1));
        
        vm.startPrank(user1);
        usdt.approve(address(router), amount);
        
        uint256 initialBalance = usdt.balanceOf(user1);
        uint256 shares = router.deposit(address(usdt), amount);
        
        assertEq(usdt.balanceOf(user1), initialBalance - amount);
        assertTrue(shares > 0);
        assertEq(doppiLP.balanceOf(user1), shares);
        
        vm.stopPrank();
    }

    function test_OwnershipPercentageWithMixedDeposits() public {
        // User 1 deposits small amount of Asset A
        vm.startPrank(user1);
        uint256 smallDeposit = 10 * 10 ** usdt.decimals();
        usdt.approve(address(router), smallDeposit);
        uint256 shares1 = router.deposit(address(usdt), smallDeposit);
        vm.stopPrank();

        // User 2 deposits large amount of Asset B
        vm.startPrank(user2);
        uint256 largeDeposit = 1 * 10 ** btc.decimals();
        btc.approve(address(router), largeDeposit);
        uint256 shares2 = router.deposit(address(btc), largeDeposit);
        vm.stopPrank();

        // Get total supply and check ownership percentages
        uint256 totalShares = doppiLP.totalSupply();
        
        // Calculate expected ownership percentages
        uint256 expectedPercentageUser1 = shares1 * 10000000 / totalShares; // basis points
        uint256 expectedPercentageUser2 = shares2 * 10000000 / totalShares; // basis points
        
        // User 1 should have very small percentage (~0.0099%)
        assertApproxEqRel(
            expectedPercentageUser1, 
            999, // ~0.0099% in basis points (10 / 100010 ≈ 0.0099%)
            1000, // 0.001% tolerance
            "User 1 should have ~0.0099% ownership"
        );
        
        // User 2 should have very large percentage (~99.9900010%)
        assertApproxEqRel(
            expectedPercentageUser2, 
            9999000, // ~99.990% in basis points ( 100,000 / 100,010 ≈ 99.990%)
            1000, // 1% tolerance
            "User 2 should have ~99.990% ownership"
        );

        // Verify the percentages add up to 100%
        assertEq(expectedPercentageUser1 + expectedPercentageUser2, 9999999, "Percentages should sum to 100% rounded effect");

        // User 2 deposits medium amount of Asset A
        vm.startPrank(user2); // Using user2 again for simplicity
        uint256 mediumDeposit = 10000 * 10 ** usdt.decimals();
        usdt.approve(address(router), mediumDeposit);
        uint256 shares3 = router.deposit(address(usdt), mediumDeposit);
        vm.stopPrank();

        // Check updated ownership percentages
        uint256 newTotalShares = doppiLP.totalSupply();
        uint256 newPercentageUser1 = shares1 * 10000000 / newTotalShares;
        uint256 newPercentageUser2 = (shares2 + shares3) * 10000000 / newTotalShares;

        // console.log(shares1, shares2, shares3, newTotalShares);
        // console.log(newPercentageUser1, newPercentageUser2);
        
        // User 1 should have even smaller percentage now (~0.9%)
        assertApproxEqRel(
            newPercentageUser1, 
            909, // ~0.9% in basis points (10 /  110,009.999999999 ≈ 0.00909%)
            10000, // 1% tolerance
            "User 1 should have ~0.00909% ownership after third deposit"
        );
        
        // User 2 should still have majority (~99.1%)
        assertApproxEqRel(
            newPercentageUser2, 
            9999090, // ~99.1% in basis points (110000 / 110,009.999999999 ≈ 99.99090992%)
            10000, // 1% tolerance
            "User 2 should have ~99.99090% ownership after third deposit"
        );

        // Test redemption maintains proper percentages
        vm.startPrank(user2);
        doppiLP.approve(address(router), shares3);
        router.redeem(shares3);
        vm.stopPrank();

        uint256 finalTotalShares = doppiLP.totalSupply();
        uint256 finalPercentageUser1 = shares1 * 10000000 / finalTotalShares;
        uint256 finalPercentageUser2 = shares2 * 10000000 / finalTotalShares;

        // console.log(shares1, shares2, shares3, finalTotalShares);
        // console.log(finalPercentageUser1, finalPercentageUser2);
        
        // After redemption, percentages should return to original ratios
        assertApproxEqRel(
            finalPercentageUser1, 
            999, // ~0.99%
            10000,
            "User 1 percentage should return to ~0.99% after redemption"
        );
        
        assertApproxEqRel(
            finalPercentageUser2, 
            9999000, // ~99.01%
            10000,
            "User 2 percentage should return to ~99.01% after redemption"
        );
    }

    function test_ExtremeDepositAmountsOwnership() public {
        // User 1 deposits tiny amount
        vm.startPrank(user1);
        uint256 tinyDeposit = 1; // 1 wei
        usdt.approve(address(router), tinyDeposit);
        uint256 shares1 = router.deposit(address(usdt), tinyDeposit);
        vm.stopPrank();

        // User 2 deposits huge amount
        vm.startPrank(user2);
        uint256 hugeDeposit = 990000 * 10 ** usdt.decimals(); // 1 million tokens
        usdt.approve(address(router), hugeDeposit);
        uint256 shares2 = router.deposit(address(usdt), hugeDeposit);
        vm.stopPrank();

        uint256 totalShares = doppiLP.totalSupply();
        
        // User 1 should have almost 0% ownership
        uint256 percentageUser1 = shares1 * 10000000 / totalShares;
        assertLt(percentageUser1, 1, "User 1 should have less than 0.01% ownership"); // < 0.01%
        
        // User 2 should have almost 100% ownership
        uint256 percentageUser2 = shares2 * 10000000 / totalShares;
        assertGe(percentageUser2, 9999999, "User 2 should have more than 99.99% ownership"); // > 99.99%

    }

    function test_MultipleSmallDepositsVsOneLargeDeposit() public {
        // User 1 makes 10 small deposits
        vm.startPrank(user1);
        uint256 smallDepositAmount = 10 * 10 ** usdt.decimals();
        usdt.approve(address(router), type(uint256).max);
        
        uint256 totalUser1Shares = 0;
        for (uint256 i = 0; i < 10; i++) {
            uint256 shares = router.deposit(address(usdt), smallDepositAmount);
            totalUser1Shares += shares;
        }
        vm.stopPrank();

        // User 2 makes 1 large deposit (same total amount)
        vm.startPrank(user2);
        uint256 largeDepositAmount = 10 * smallDepositAmount;
        usdt.approve(address(router), largeDepositAmount);
        uint256 totalUser2Shares = router.deposit(address(usdt), largeDepositAmount);
        vm.stopPrank();

        // Both users should have approximately the same ownership percentage
        uint256 totalShares = doppiLP.totalSupply();
        uint256 percentageUser1 = totalUser1Shares * 10000000 / totalShares;
        uint256 percentageUser2 = totalUser2Shares * 10000000 / totalShares;

        // console.log(percentageUser1, percentageUser2);
        
        // They should have roughly equal ownership (within 1% tolerance)
        assertApproxEqRel(
            percentageUser1,
            percentageUser2,
            10000000, // 1% tolerance
            "Multiple small deposits should result in same ownership as one large deposit"
        );

        // Each should have approximately 50%
        assertApproxEqRel(
            percentageUser1,
            5000000, // 50%
            100,
            "Both users should have approximately 50% ownership"
        );
    }

    function test_RedeemAndRedepositOwnershipConsistency() public {
        // Initial deposits
        vm.startPrank(user1);
        uint256 deposit1 = 100 * 10 ** usdt.decimals();
        usdt.approve(address(router), type(uint256).max);
        uint256 shares1 = router.deposit(address(usdt), deposit1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 deposit2 = 200 * 10 ** usdt.decimals();
        usdt.approve(address(router), type(uint256).max);
        uint256 shares2 = router.deposit(address(usdt), deposit2);
        vm.stopPrank();

        // Record initial percentages
        uint256 initialTotalShares = doppiLP.totalSupply();
        uint256 initialPercentageUser1 = shares1 * 10000000 / initialTotalShares;
        uint256 initialPercentageUser2 = shares2 * 10000000 / initialTotalShares;

        // console.log(initialTotalShares, initialPercentageUser1, initialPercentageUser2);

        // User 1 redeems half and redeposits
        vm.startPrank(user1);
        uint256 redeemAmount = shares1 / 2;
        doppiLP.approve(address(router), redeemAmount);
        router.redeem(redeemAmount);
        
        // Redeposit the same amount
        uint256 redepositAmount = deposit1 / 2;
        usdt.approve(address(router), redepositAmount);
        uint256 newShares1 = router.deposit(address(usdt), redepositAmount);
        vm.stopPrank();

        // Check that ownership percentage remains approximately the same
        uint256 newTotalShares = doppiLP.totalSupply();
        uint256 newPercentageUser1 = (shares1 - redeemAmount + newShares1) * 10000000 / newTotalShares;

        // console.log(newTotalShares, newPercentageUser1);
        
        assertApproxEqRel(
            newPercentageUser1,
            initialPercentageUser1,
            100, // 1% tolerance
            "User 1 ownership percentage should remain consistent after redeem/redeposit"
        );
    }

    // Event emit test
    function test_Deposit_EmitsDepositedEvent() public {
        
        vm.startPrank(user1);
        
        uint256 depositAmount = 100 * 10 ** usdt.decimals();
        uint256 initialBalance = usdt.balanceOf(user1);
        
        // Approve router to spend tokens
        usdt.approve(address(router), depositAmount);
        
        // Expect Deposited event
        vm.expectEmit(true, true, true, true);
        emit Deposited(
            user1,
            depositAmount, // amount
            address(usdt), // asset
            100000000000000000000
        );    
        // Deposit Asset A
        router.deposit(address(usdt), depositAmount);
        
        vm.stopPrank();
    }

    function test_Redeem_EmitsRedeemedEvent() public {
        
        vm.startPrank(user1);
        
        uint256 depositAmount = 100 * 10 ** usdt.decimals();
        usdt.approve(address(router), depositAmount);
        uint256 shares = router.deposit(address(usdt), depositAmount);
        
        // Approve router to spend LP tokens
        doppiLP.approve(address(router), shares);
        
        // Expect Deposited event
        vm.expectEmit(true, true, true, true);
        emit Redeemed(
            user1,
            shares, // amount
            100000000000000000000, // asset
            0
        );    
        // Redeem
        router.redeem(shares);
        vm.stopPrank();
    }


}