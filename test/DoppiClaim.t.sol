// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DoppiClaim} from "../src/mainnet/DoppiClaim.sol";
import {DoppiReferral} from "../src/mainnet/DoppiReferral.sol";
import {DoppiPoints} from "../src/mainnet/DoppiPoints.sol";
import {DOPPI} from "../src/test/Doppi.sol";


contract DoppiClaimTest is Test {
    DOPPI public token;
    DoppiClaim public doppiClaim;
    DoppiPoints public doppiPoints;
    DoppiReferral public referral;
    address public alice = address(0xABCD);
    address public bob = address(0x10);
    address mockDoppiCore = address(0x3);
    address mockDoppiClaim = address(0x4);


    function setUp() public {
        vm.warp(1735689600);
        // Deploy token & doppiClaim
        token = new DOPPI("Doppi Token", "DOPPI");
        doppiPoints = new DoppiPoints();
        referral = new DoppiReferral(
            address(doppiPoints),
            150, // 1.5%
            100, // 1.0%
            50   // 0.5%
        );

        doppiClaim = new DoppiClaim(
            address(token),
            address(doppiPoints),
            address(referral),
            1 // 1 token per point
        );
        doppiPoints.setDoppiCore(mockDoppiCore);
        doppiPoints.setDoppiClaim(address(doppiClaim));
        referral.setDoppiClaim(address(doppiClaim));

        // Give DoppiClaim minting rights
        token.addMinter(address(doppiClaim));

        // Deal some ETH to alice so she can tx
        vm.deal(alice, 10 ether);
        vm.warp(vm.getBlockTimestamp() + 31 days);
        
    }

    function testClaimWithOnlyTradePoints() public {
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(alice, 100 ether); // trader1 trades 100 USDT
        
        vm.prank(alice);
        doppiClaim.claim();

        (uint256 totalPoints, ) = doppiPoints.getPoints(alice);
        assertEq(token.balanceOf(alice), 100 ether, "Alice should get 100 tokens");
        assertEq(totalPoints, 0, "Points should reset");
    }

    function testClaimWithOnlyReferralRewards() public {
        
        _registerCode();

        vm.warp(vm.getBlockTimestamp() + 31 days);

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 10000 ether); // trader1 trades 100 USDT

        vm.warp(vm.getBlockTimestamp() + 31 days);
        (uint256 l1, uint256 l2, uint256 l3) = referral.getTotalReferralRewards(alice);
        assertEq(l1, 150 ether, "Alice expected to get 150 tokens");

        vm.prank(alice);
        doppiClaim.claim();

        DoppiReferral.ReferralInfo memory info = referral.getReferralInfo(alice);
        assertEq(info.claimedLevel1, l1);
        assertEq(info.claimedLevel2, 0);
        assertEq(info.claimedLevel3, 0);
        assertEq(token.balanceOf(alice), l1, "Alice claimed 150 tokens successfully");

        (l1, , ) = referral.getTotalReferralRewards(alice);
        assertEq(l1, 0);
    }

    function testClaimWithBoth() public {
        
        _registerCode();

        // trade points
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(alice, 100 ether); // trader1 trades 100 USDT

        // referral rewards
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 10000 ether); // trader1 trades 100 USDT

        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(alice);
        doppiClaim.claim();

        (uint256 totalPoints, ) = doppiPoints.getPoints(alice);
        assertEq(token.balanceOf(alice), 250 ether, "Alice should get 250 tokens total");
        assertEq(totalPoints, 0, "Points reset");
        (uint256 l1,uint256 l2,uint256 l3) = referral.getTotalReferralRewards(alice);
        assertEq(l1+l2+l3, 0, "Referral rewards reset");
    }

    function testRevertWhenNoPoints() public {
        vm.prank(alice);
        vm.expectRevert("no points to claim");
        doppiClaim.claim();
    }

    function testPauseUnpause() public {
        doppiClaim.pause();

        vm.prank(alice);
        vm.expectRevert("EnforcedPause()");
        doppiClaim.claim();

        doppiClaim.unpause();

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(alice, 100 ether); // trader1 trades 100 USDT

        vm.prank(alice);
        doppiClaim.claim();

        assertEq(token.balanceOf(alice), 100 ether);
    }

    function testEventEmitted() public {
        
         _registerCode();

        // trade points
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(alice, 100 ether); // trader1 trades 100 USDT

        // referral rewards
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 10000 ether); // trader1 trades 100 USDT

        vm.warp(vm.getBlockTimestamp() + 31 days);
        
        vm.expectEmit(true, false, false, true);
        emit Claimed(alice, 100 ether, 150 ether, 0, 0, 250 ether);

        vm.prank(alice);
        doppiClaim.claim();
    }

    event Claimed(
        address indexed user,
        uint256 tradePoints,
        uint256 referralL1,
        uint256 referralL2,
        uint256 referralL3,
        uint256 mintedAmount
    );

    // internal
    function _registerCode() internal {

        // Step 1: Alice registers her code
        vm.prank(alice);
        referral.registerReferralCode(keccak256("ALICE"));

        // Step 2: Bob registers with Alice's code
        vm.startPrank(bob);
        referral.registerReferralCode(keccak256("BOB"));
        referral.registerReferrer(keccak256("ALICE"));
        vm.stopPrank();

        
    } 
}
