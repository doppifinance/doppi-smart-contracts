// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
// import "../src/DoppiReferral.sol";
import {DoppiReferral} from "../src/mainnet/DoppiReferral.sol";
import {DoppiPoints} from "../src/mainnet/DoppiPoints.sol";

contract MockDoppiPoints {
    // monthId => trader => volume
    mapping(uint256 => mapping(address => uint256)) public volumes;
    uint256[] private monthIds;

    function setMonthlyVolume(address trader, uint256 monthId, uint256 volume) external {
        volumes[monthId][trader] = volume;
        bool exists = false;
        for (uint256 i; i < monthIds.length; i++) {
            if (monthIds[i] == monthId) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            monthIds.push(monthId);
        }
    }

    function getMonthlyVolume(address trader, uint256 monthId) external view returns (uint256) {
        return volumes[monthId][trader];
    }

    function getMonthIds() external view returns (uint256[] memory) {
        return monthIds;
    }
}

contract DoppiReferralTest is Test {
    DoppiReferral referral;
    DoppiPoints doppiPoints;
    MockDoppiPoints mockdoppiPoints;

    address mockDoppiCore = address(0x3);
    address alice = makeAddr("Alice");
    address bob = makeAddr("Bob");
    address charlie = makeAddr("Charlie");
    address dave = makeAddr("Dave");
    address jeff = makeAddr("Jeff");
    address cz = makeAddr("CZ");
    bytes32 aliceCode = keccak256("ALICE");
    bytes32 bobCode = keccak256("BOB");
    bytes32 charlieCode = keccak256("CHARLES");
    bytes32 jeffCode = keccak256("JEFF");

    function setUp() public {
        
        doppiPoints = new DoppiPoints();
        doppiPoints.setDoppiCore(mockDoppiCore, true);
        mockdoppiPoints = new MockDoppiPoints();
        referral = new DoppiReferral(
            address(doppiPoints),
            150, // 1.5%
            100, // 1.0%
            50   // 0.5%
        );
        // fast-forward to known start timestamp
        vm.warp(1735689600);
    }

    function test_Level1RewardsForAlice() public {
        
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _registerCode();

        vm.warp(vm.getBlockTimestamp() + 31 days);

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 10000 ether); // trader1 trades 100 USDT

        vm.warp(vm.getBlockTimestamp() + 31 days);
        (uint256 l1, uint256 l2, uint256 l3,,,) = referral.getTotalReferralRewards(alice);
        assertEq(l1, (10000 ether * 150) / 10000, "Alice L1 reward incorrect");
        assertEq(l2, 0, "No L2 yet");
        assertEq(l3, 0, "No L3 yet");
    }

    function test_Level2RewardsRequireMinVolume() public {
        
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _registerCode();

        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 600_000 ether); 

        vm.warp(vm.getBlockTimestamp() + 31 days);
        (uint256 l1, uint256 l2, uint256 l3,,,) = referral.getTotalReferralRewards(alice);
        uint256 expectedL2 = (600_000 ether * 100) / 10000;
        assertEq(l1, 0, "No L1");
        assertEq(l2, expectedL2, "Alice L2 wrong");
        assertEq(l3, 0, "No L3 yet");
    }

    function test_Level2RewardsRequireMinVolume_UnderMin() public {
        
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _registerCode();

        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 300_000 ether); 

        vm.warp(vm.getBlockTimestamp() + 31 days);
        (uint256 l1, uint256 l2, uint256 l3,,,) = referral.getTotalReferralRewards(alice);        
        assertEq(l1, 0, "No L1");
        assertEq(l2, 0, "No L2");
        assertEq(l3, 0, "No L3 yet");
    }

    function testThreeLevelReferralRewards() public {
        
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _registerCode();

        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 1_000_000 ether); 
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 1_500_000 ether); 
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(dave, 2_500_000 ether); 
        
        // New month. New Trades
        vm.warp(vm.getBlockTimestamp() + 31 days);
        
        // Step 5: Query Alice’s rewards
        (uint256 l1, uint256 l2, uint256 l3,,,) = referral.getTotalReferralRewards(alice);
        // Expectations:
        // Bob’s trades → Alice gets L1 (1.5% of 1M = 15,000 ether)
        // Charlie’s trades → Alice gets L2 (1.0% of 1.5M = 15,000 ether, above min 500k)
        // Dave’s trades → Alice gets L3 (0.5% of 2.5M = 12,500 ether, above min 1M)
        assertEq(l1, (1_000_000 ether * 150) / 10000);
        assertEq(l2, (1_500_000 ether * 100) / 10000);
        assertEq(l3, (2_500_000 ether * 50) / 10000);

        // Step 6: Reset claims
        vm.prank(address(this));
        referral.setDoppiClaim(address(this));
        referral.resetClaims(alice);

        DoppiReferral.ReferralInfo memory info = referral.getReferralInfo(alice);
        assertEq(info.claimedLevel1, l1);
        assertEq(info.claimedLevel2, l2);
        assertEq(info.claimedLevel3, l3);
    }

    function testThreeLevelReferralRewards_NextMonth() public {
        
        vm.warp(vm.getBlockTimestamp() + 31 days);

        testThreeLevelReferralRewards();

        // New month. New Trades
        vm.warp(vm.getBlockTimestamp() + 31 days);
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 2_000_000 ether); 
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 3_000_000 ether); 
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(dave, 5_000_000 ether); 

        // New month. New Trades
        vm.warp(vm.getBlockTimestamp() + 31 days);
        (uint256 l1, uint256 l2, uint256 l3,,,) = referral.getTotalReferralRewards(alice);
        assertEq(l1, (2_000_000 ether * 150) / 10000);
        assertEq(l2, (3_000_000 ether * 100) / 10000);
        assertEq(l3, (5_000_000 ether * 50) / 10000);

        // Step 6: Reset claims
        vm.prank(address(this));
        referral.setDoppiClaim(address(this));
        referral.resetClaims(alice);

        uint256 expectedl1 = ((2_000_000 ether * 150) / 10000) + ((1_000_000 ether * 150) / 10000);
        uint256 expectedl2 = ((3_000_000 ether * 100) / 10000) + ((1_500_000 ether * 100) / 10000);
        uint256 expectedl3 = ((5_000_000 ether * 50) / 10000) + ((2_500_000 ether * 50) / 10000);

        DoppiReferral.ReferralInfo memory info = referral.getReferralInfo(alice);
        uint256 currentMonthId = _currentMonthId();
        assertEq(info.claimedLevel1, expectedl1);
        assertEq(info.claimedLevel2, expectedl2);
        assertEq(info.claimedLevel3, expectedl3);
        assertEq(info.claimedMonthId, currentMonthId - 1);
    }

    function test_level2_traded_currentmonth_not_included() public {
        
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _registerCode();

        vm.warp(vm.getBlockTimestamp() + 31 days);

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 3_000_000 ether); 
        
        // still within active month id, expected 0
        (uint256 l1, uint256 l2, uint256 l3,,,) = referral.getTotalReferralRewards(alice);
        assertEq(l1, 0);
        assertEq(l2, 0);
        assertEq(l3, 0);
        
        // New month. New Trades
        vm.warp(vm.getBlockTimestamp() + 31 days);
        (l1, l2, l3,,,) = referral.getTotalReferralRewards(alice);
       
        assertEq(l1, 0);
        assertEq(l2, (3_000_000 ether * 100) / 10000);
        assertEq(l3, 0);
    }

    function test_ResetClaimsExcludesPreviousMonth() public {
        
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _registerCode();

        // Month 1: Dave trades
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(dave, 2_000_000 ether);

        // Move to next month
        vm.warp(vm.getBlockTimestamp() + 31 days);
        
        // Before reset: Alice should see only month 1
        (,,uint256 l3Before,,,) = referral.getTotalReferralRewards(alice);
        assertEq(l3Before, 10000000000000000000000);

        referral.setDoppiClaim(address(this));
        vm.prank(address(this));
        referral.resetClaims(alice);
        
        // after reset, it recorded in claimed info
        DoppiReferral.ReferralInfo memory info = referral.getReferralInfo(alice);
        assertEq(info.claimedMonthId, 1);
        assertEq(info.claimedLevel1, 0);
        assertEq(info.claimedLevel2, 0);
        assertEq(info.claimedLevel3, 10000000000000000000000);
        

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(dave, 4_000_000 ether);

        vm.warp(vm.getBlockTimestamp() + 31 days);
        (, , uint256 l3After,,,) = referral.getTotalReferralRewards(alice);
        uint256 expected = (4_000_000 ether * 50) / 10000;
        assertEq(l3After, expected);
        
        referral.setDoppiClaim(address(this));
        vm.prank(address(this));
        referral.resetClaims(alice);

        info = referral.getReferralInfo(alice);
        assertEq(info.claimedMonthId, 2);
        assertEq(info.claimedLevel1, 0);
        assertEq(info.claimedLevel2, 0);
        assertEq(info.claimedLevel3, 30000000000000000000000);

    }

    function test_Referral_Referee_L1Check() public {
        
        // alice use bob as referror
        // bob cannot register alice as referror
        
        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Step 1: Bob create code but no trade
        vm.startPrank(bob);
        referral.registerReferralCode(keccak256("BOB"));
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1 days);

        // Alice trades
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(alice, 2_000_000 ether);
        vm.stopPrank();
        
        vm.startPrank(alice);
        referral.registerReferrer(keccak256("BOB"));
        vm.stopPrank();
        
        // Bob should see current month
        (uint256 totalL1, uint256 totalL2, uint256 totalL3,
            uint256 currentL1, uint256 currentL2, uint256 currentL3) = referral.getTotalReferralRewards(bob);

        assertEq(currentL1, 30000000000000000000000);

        vm.startPrank(alice);
        referral.registerReferralCode(keccak256("ALICE"));
        vm.stopPrank();

        // bob as referror cannot register alice because alice is referee
        vm.startPrank(bob);
        vm.expectRevert("cannot register under your downline");
        referral.registerReferrer(keccak256("ALICE"));
        vm.stopPrank();


        (address upline,
            address[] memory level1Referees, 
            address[] memory level2Referees, 
            address[] memory level3Referees) = referral.getReferees(bob);

        assertEq(level1Referees.length, 1);
        assertEq(level2Referees.length, 0);
        assertEq(level3Referees.length, 0);
        

    }

    function test_Referral_Referee_L2Check() public {
        
        // bob -> alice -> charles -> dave -> jeff
        // L0 -> L1 -> L2 -> L3 -> (L4 : no support)

        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Step 1: Bob create code but no trade
        vm.startPrank(bob);
        referral.registerReferralCode(keccak256("BOB"));
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1 days);

        // Alice trades
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(alice, 2_000_000 ether);
        vm.stopPrank();
        
        // Step 1. Alice register BOB
        vm.startPrank(alice);
        referral.registerReferrer(keccak256("BOB"));
        vm.stopPrank();
        
        // Alice register code
        vm.startPrank(alice);
        referral.registerReferralCode(keccak256("ALICE"));
        vm.stopPrank();

        // Step 2. Charles register Alice
        // charlie register alice , he is indirect level 1 to bob
        vm.startPrank(charlie);
        referral.registerReferrer(keccak256("ALICE"));
        vm.stopPrank();

        // charlie register twice with different code
        vm.startPrank(charlie);
        vm.expectRevert("already register");
        referral.registerReferrer(keccak256("BOB"));
        vm.stopPrank();

        // charlie register code
        vm.startPrank(charlie);
        referral.registerReferralCode(keccak256("CHARLES"));
        vm.stopPrank();

        // alice as referror cannot register charlie because charlie is referee
        vm.startPrank(alice);
        vm.expectRevert("already register");
        referral.registerReferrer(keccak256("CHARLES"));
        vm.stopPrank();

        // bob as indirect referror cannot register charlie because charlie is indirect level 2 referee
        vm.startPrank(bob);
        vm.expectRevert("cannot register under your downline");
        referral.registerReferrer(keccak256("CHARLES"));
        vm.stopPrank();

        // Step 3. Dave register Charles
        // charlie register twice with different code
        vm.startPrank(dave);
        referral.registerReferrer(keccak256("CHARLES"));
        vm.stopPrank();

        vm.startPrank(dave);
        referral.registerReferralCode(keccak256("DAVE"));
        vm.stopPrank();

        // bob as indirect referror cannot register dave because dave is indirect level 3 referee
        vm.startPrank(bob);
        vm.expectRevert("cannot register under your downline");
        referral.registerReferrer(keccak256("DAVE"));
        vm.stopPrank();


        // charlie register twice with different code
        vm.startPrank(jeff);
        referral.registerReferrer(keccak256("DAVE"));
        vm.stopPrank();

        vm.startPrank(jeff);
        referral.registerReferralCode(keccak256("JEFF"));
        vm.stopPrank();

        // bob can register dave as referror because dave is indirect level 4 referee, which is OK
        vm.startPrank(bob);
        vm.expectRevert("cannot register under your downline");
        referral.registerReferrer(keccak256("JEFF"));
        vm.stopPrank();


        vm.startPrank(cz);
        referral.registerReferralCode(keccak256("CZ"));
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("cannot register upline");
        referral.registerReferrer(keccak256("CZ"));
        vm.stopPrank();

        // console.log("bob", bob);
        // console.log("alice", alice);
        // console.log("charlie", charlie);
        // console.log("dave", dave);
        // console.log("jeff", jeff);
        // console.log("cz", cz);
        
        _getReferee(bob, address(0), 1, 1, 1);
        _getReferee(alice, bob, 1, 1, 1);
        _getReferee(charlie, alice, 1, 1, 0);
        _getReferee(dave, charlie, 1, 0, 0);
        _getReferee(jeff, dave, 0, 0, 0);
        _getReferee(cz, address(0), 0, 0, 0);
        
    }

    // internal
    function _getReferee(address trader, address referror, uint256 l1, uint256 l2, uint256 l3) internal {
        
        (address upline,
            address[] memory level1Referees, 
            address[] memory level2Referees, 
            address[] memory level3Referees) = referral.getReferees(trader);

        // console.log(upline, level1Referees.length, level2Referees.length, level3Referees.length);
        
        // for(uint256 i=0; i< level1Referees.length; i++){
        //     console.log("l1", i+1, level1Referees[i]);
        // }
        // for(uint256 i=0; i< level2Referees.length; i++){
        //     console.log("l2", i+1, level2Referees[i]);
        // }
        // for(uint256 i=0; i< level3Referees.length; i++){
        //     console.log("l3", i+1, level3Referees[i]);
        // }
        assertEq(upline, referror);
        assertEq(level1Referees.length, l1);
        assertEq(level2Referees.length, l2);
        assertEq(level3Referees.length, l3);
    }

    function _registerCode() internal {

        // Step 1: Alice registers her code
        vm.prank(alice);
        referral.registerReferralCode(keccak256("ALICE"));

        // Step 2: Bob registers with Alice's code
        vm.startPrank(bob);
        referral.registerReferralCode(keccak256("BOB"));
        referral.registerReferrer(keccak256("ALICE"));
        vm.stopPrank();

        // Step 3: Charlie registers with Bob's code
        vm.startPrank(charlie);
        referral.registerReferralCode(keccak256("CHARLIE"));
        referral.registerReferrer(keccak256("BOB"));
        vm.stopPrank();

        // Step 4: Dave registers with Charlie's code
        vm.startPrank(dave);
        referral.registerReferralCode(keccak256("DAVE"));
        referral.registerReferrer(keccak256("CHARLIE"));
        vm.stopPrank();
    } 

    function _currentMonthId() internal view returns (uint24) {
        // 30-day rolling months
        uint256 startTimestamp = 1735689600; // Jan 1, 2025
        return uint24((block.timestamp - startTimestamp) / 30 days);
    }

}
