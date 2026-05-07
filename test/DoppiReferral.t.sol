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
        doppiPoints.setDoppiReferral(address(referral));
        referral.setMinVolumeForL2L3(1_000 ether, 2_000 ether);
    }

    
    function test_Level1To3RewardsForAlice() public {
        
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _registerCode();

        vm.warp(vm.getBlockTimestamp() + 31 days);

        console.log(alice, "alice");
        console.log(bob, "bob");
        console.log(charlie, "charlie");

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 10000 ether); // trader1 trades 100 USDT

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 10000 ether); // trader1 trades 100 USDT

        vm.warp(vm.getBlockTimestamp() + 31 days);
        (uint256 l1, uint256 l2, uint256 l3, uint256 c1, uint256 c2, uint256 c3) = referral.getTotalReferralRewards(charlie);
        assertEq(l1, 0);
        assertEq(l2, 0);
        assertEq(l3, 0);
        assertEq(c1, 0);
        assertEq(c2, 0);
        assertEq(c3, 0);

        (l1, l2, l3, c1, c2, c3) = referral.getTotalReferralRewards(bob);
        assertEq(l1, 150000000000000000000);
        assertEq(l2, 0);
        assertEq(l3, 0);
        assertEq(c1, 0);
        assertEq(c2, 0);
        assertEq(c3, 0);

        (l1, l2, l3, c1, c2, c3) = referral.getTotalReferralRewards(alice);
        
        assertEq(l1, 150000000000000000000);
        assertEq(l2, 100000000000000000000);
        assertEq(l3, 0);
        assertEq(c1, 0);
        assertEq(c2, 0);
        assertEq(c3, 0);

        
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
        
        vm.startPrank(referral.owner());
        referral.setMinVolumeForL2L3(500_000 ether, 2_000_000 ether);
        vm.stopPrank();

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
        
        vm.startPrank(referral.owner());
        referral.setMinVolumeForL2L3(500_000 ether, 2_000_000 ether);
        vm.stopPrank();

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

    function testUplineReferralRewards() public {
        
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _registerCode();

        vm.warp(vm.getBlockTimestamp() + 31 days);

        uint256 gasBefore = gasleft();
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(dave, 2_000_000 ether); 
        uint256 gasUsed = gasBefore - gasleft();
        console.log(gasUsed, "gasUsed in recordTrade");
        
        // New month. New Trades
        vm.warp(vm.getBlockTimestamp() + 31 days);
        
        // Step 5: Query Alice’s rewards
        (uint256 l1, uint256 l2, uint256 l3,,,) = referral.getTotalReferralRewards(alice);
        assertEq(l1, 0);
        assertEq(l2, 0);
        assertEq(l3, (2_000_000 ether * 50) / 10000);

        (l1, l2, l3,,,) = referral.getTotalReferralRewards(bob);
        assertEq(l1, 0);
        assertEq(l2, (2_000_000 ether * 100) / 10000);
        assertEq(l3, 0);


         (l1, l2, l3,,,) = referral.getTotalReferralRewards(charlie);
        assertEq(l1, (2_000_000 ether * 150) / 10000);
        assertEq(l2, 0);
        assertEq(l3, 0);

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
        (uint256 l1, uint256 l2, uint256 l3, uint256 currentL1, uint256 currentL2, uint256 currentL3) = referral.getTotalReferralRewards(alice);
        
        assertEq(l1, 0);
        assertEq(l2, 0);
        assertEq(l3, 0);
        assertEq(currentL1, 0);
        assertEq(currentL2, (3_000_000 ether * 100) / 10000);
        assertEq(currentL3, 0);
        
        // New month. New Trades
        vm.warp(vm.getBlockTimestamp() + 31 days);
        (l1, l2, l3, currentL1, currentL2, currentL3) = referral.getTotalReferralRewards(alice);
       
        assertEq(l1, 0);
        assertEq(l2, (3_000_000 ether * 100) / 10000);
        assertEq(l3, 0);
        assertEq(currentL1, 0);
        assertEq(currentL2, 0);
        assertEq(currentL3, 0);
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
        // trade done by bob is before alice register bob, so it should not be included in alice's reward
        (uint256 totalL1, uint256 totalL2, uint256 totalL3,
            uint256 currentL1, uint256 currentL2, uint256 currentL3) = referral.getTotalReferralRewards(bob);

        assertEq(currentL1, 0);

        vm.startPrank(alice);
        referral.registerReferralCode(keccak256("ALICE"));
        vm.stopPrank();

        // bob as referror cannot register alice because alice is referee
        vm.startPrank(bob);
        vm.expectRevert("cannot register upline");
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
        vm.expectRevert("cannot register upline");
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
        vm.expectRevert("cannot register upline");
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
        vm.expectRevert("cannot register upline");
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

    // ========== Rate Scheduling Tests ==========

    function testRateSchedulingEffectiveNextMonth() public {
        // Test that rate changes take effect only from next month forward
        vm.warp(vm.getBlockTimestamp() + 31 days);
        _registerCode();

        // Month 1: Trade with initial rates (1.5%, 1.0%, 0.5%)
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 10_000 ether);

        // Schedule new rates for next month
        vm.prank(referral.owner());
        referral.setRates(100, 50, 25); // 1.0%, 0.5%, 0.25%

        // Verify checkpoint was added
        assertEq(referral.getRateCheckpointCount(), 2, "Should have 2 checkpoints");

        // Month 2: Trade with scheduled rates
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 10_000 ether);

        // Move to month 3 to view claimable rewards
        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Month 1 rewards should use old rate (1.5%)
        // Month 2 rewards should use new rate (1.0%)
        (uint256 l1Total, , , , , ) = referral.getTotalReferralRewards(alice);
        uint256 month1L1 = (10_000 ether * 150) / 10000; // Old rate
        uint256 month2L1 = (10_000 ether * 100) / 10000; // New rate
        assertEq(l1Total, month1L1 + month2L1, "L1 should have mixed rates");
    }

    function testGetNextMonthStartTimestamp() public {
        vm.warp(1735689600 + 45 days);

        uint24 currentMonth = _currentMonthId();
        uint24 expectedNextMonth = currentMonth + 1;
        uint256 expectedNextMonthStart = 1735689600 + (uint256(expectedNextMonth) * 30 days);

        (uint24 nextMonthId, uint256 nextMonthStartTimestamp) = referral.getNextMonthStartTimestamp();
        assertEq(nextMonthId, expectedNextMonth, "next month id mismatch");
        assertEq(nextMonthStartTimestamp, expectedNextMonthStart, "next month start timestamp mismatch");

        uint256 month0Start = referral.getMonthStartTimestamp(0);
        assertEq(month0Start, 1735689600, "month 0 start mismatch");
    }

    function testRatePreservedForPreviousMonths() public {
        // Verify that changing rates doesn't affect already-earned rewards
        vm.warp(vm.getBlockTimestamp() + 31 days);
        _registerCode();

        // Month 1: Earn rewards with initial rates
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 10_000 ether);

        vm.warp(vm.getBlockTimestamp() + 31 days);
        (uint256 l1First,,,,,) = referral.getTotalReferralRewards(alice);
        uint256 expectedFirst = (10_000 ether * 150) / 10000;
        assertEq(l1First, expectedFirst, "First month should use initial rate");

        // Now drastically change rates
        vm.prank(referral.owner());
        referral.setRates(500, 300, 100); // Much higher rates

        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Month 2 with new high rates
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 10_000 ether);

        vm.warp(vm.getBlockTimestamp() + 31 days);
        (uint256 l1Total,,,,,) = referral.getTotalReferralRewards(alice);

        // First month should still be 150, not affected by new rates
        uint256 expectedSecond = (10_000 ether * 500) / 10000;
        assertEq(l1Total, expectedFirst + expectedSecond, "Old month rates should be preserved");
    }

    function testRateScheduledEvent() public {
        vm.warp(vm.getBlockTimestamp() + 31 days);

        vm.prank(referral.owner());
        vm.expectEmit(true, true, true, true);
        emit DoppiReferral.RatesScheduled(150, 100, 50, 200, 150, 75, _currentMonthId() + 1);
        referral.setRates(200, 150, 75);
    }

    function testOverwritePendingRateUpdate() public {
        // Test that setting rates twice in same effective month overwrites the first
        vm.warp(vm.getBlockTimestamp() + 31 days);

        uint24 effectiveMonth = _currentMonthId() + 1;
        assertEq(referral.getRateCheckpointCount(), 1, "Should start with 1 checkpoint");

        // First rate change scheduled for next month
        vm.prank(referral.owner());
        referral.setRates(100, 50, 25);
        assertEq(referral.getRateCheckpointCount(), 2, "Should add checkpoint");

        (uint24 month1, uint16 l1_1, uint16 l2_1, uint16 l3_1) = referral.getRateCheckpoint(1);
        assertEq(month1, effectiveMonth, "Month should match");
        assertEq(l1_1, 100, "First update");

        // Second rate change for same month overwrites
        vm.prank(referral.owner());
        referral.setRates(200, 100, 50);
        assertEq(referral.getRateCheckpointCount(), 2, "Should not add another checkpoint");

        (uint24 month2, uint16 l1_2, uint16 l2_2, uint16 l3_2) = referral.getRateCheckpoint(1);
        assertEq(month2, effectiveMonth, "Month should still match");
        assertEq(l1_2, 200, "Should be overwritten");
        assertEq(l2_2, 100, "Should be overwritten");
        assertEq(l3_2, 50, "Should be overwritten");
    }

    function testGetRatesForMonth() public {
        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Month 0-1 should use initial rates
        (uint16 l1, uint16 l2, uint16 l3) = referral.getRatesForMonth(0);
        assertEq(l1, 150, "Month 0 L1");
        assertEq(l2, 100, "Month 0 L2");
        assertEq(l3, 50, "Month 0 L3");

        // Schedule new rates for month 2
        uint24 currentMonth = _currentMonthId();
        vm.prank(referral.owner());
        referral.setRates(100, 75, 25);

        // Month 0-1 still use old rates
        (l1, l2, l3) = referral.getRatesForMonth(1);
        assertEq(l1, 150, "Month 1 still old rate");

        // Month 2+ use new rates
        (l1, l2, l3) = referral.getRatesForMonth(currentMonth + 1);
        assertEq(l1, 100, "Month 2+ new L1");
        assertEq(l2, 75, "Month 2+ new L2");
        assertEq(l3, 25, "Month 2+ new L3");
    }

    function testGetRateCheckpoint() public {
        assertEq(referral.getRateCheckpointCount(), 1, "Initial checkpoint");

        (uint24 month0, uint16 l1_0, uint16 l2_0, uint16 l3_0) = referral.getRateCheckpoint(0);
        assertEq(month0, 0, "First checkpoint at month 0");
        assertEq(l1_0, 150, "Initial L1");
        assertEq(l2_0, 100, "Initial L2");
        assertEq(l3_0, 50, "Initial L3");

        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(referral.owner());
        referral.setRates(200, 150, 75);

        (uint24 month1, uint16 l1_1, uint16 l2_1, uint16 l3_1) = referral.getRateCheckpoint(1);
        assertEq(month1, _currentMonthId() + 1, "Second checkpoint at next month");
        assertEq(l1_1, 200, "Updated L1");
        assertEq(l2_1, 150, "Updated L2");
        assertEq(l3_1, 75, "Updated L3");
    }

    function testMixedRateConversionMultipleMonths() public {
        // Comprehensive test: multiple rate changes over time with varied trading
        vm.warp(vm.getBlockTimestamp() + 31 days);
        _registerCode();

        // Set min volume for L2 to 500k to test volume gating
        vm.prank(referral.owner());
        referral.setMinVolumeForL2L3(500_000 ether, 2_000_000 ether);

        // Month 1: Trade with initial rates (150, 100, 50)
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 10_000 ether);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 600_000 ether); // Above L2 min

        // Move to month 2 and schedule new rates for month 3
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(referral.owner());
        referral.setRates(100, 75, 25); // 1%, 0.75%, 0.25%

        // Month 2: Trade with initial rates (still effective)
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 5_000 ether);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 550_000 ether); // Above L2 min

        // Move to month 3: New rates now effective
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(bob, 8_000 ether);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 700_000 ether); // Above L2 min

        // Move to month 4: Verify all accumulated rewards with mixed rates
        vm.warp(vm.getBlockTimestamp() + 31 days);

        (uint256 l1Total, uint256 l2Total, , , , ) = referral.getTotalReferralRewards(alice);

        // Calculate expected:
        // L1 (from Bob's trades):
        //   Month 1: 10k * 150 / 10000 = 150
        //   Month 2: 5k * 150 / 10000 = 75
        //   Month 3: 8k * 100 / 10000 = 80
        // Total: 305
        uint256 expectedL1 = (10_000 ether * 150 / 10000) +
                             (5_000 ether * 150 / 10000) +
                             (8_000 ether * 100 / 10000);
        assertEq(l1Total, expectedL1, "L1 mixed rates");

        // L2 (from Charlie's trades, needs min volume 500k ether):
        //   Month 1: 600k >= 500k, rate 100 → 600k * 100 / 10000 = 6000
        //   Month 2: 550k >= 500k, rate 100 → 550k * 100 / 10000 = 5500
        //   Month 3: 700k >= 500k, rate 75 → 700k * 75 / 10000 = 5250
        // Total: 16750
        uint256 expectedL2 = (600_000 ether * 100 / 10000) +
                             (550_000 ether * 100 / 10000) +
                             (700_000 ether * 75 / 10000);
        assertEq(l2Total, expectedL2, "L2 mixed rates with volume gating");
    }

    function testRateChangeWithMinVolumeSchedule() public {
        // Test that rate changes and min volume changes are independent
        vm.warp(vm.getBlockTimestamp() + 31 days);
        _registerCode();

        // Initial min volumes
        vm.prank(referral.owner());
        referral.setMinVolumeForL2L3(500_000 ether, 2_000_000 ether);

        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Month 1: Trade
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 600_000 ether); // Above L2 min

        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Should qualify for L2 with initial rate (100)
        (,uint256 l2_old,,,,) = referral.getTotalReferralRewards(alice);
        uint256 expectedOld = (600_000 ether * 100) / 10000;
        assertEq(l2_old, expectedOld, "Should qualify with old rate");

        // Schedule new rates for month 3
        vm.prank(referral.owner());
        referral.setRates(200, 150, 75);

        // IMPORTANT: Must warp to month 3 BEFORE trading so new rates apply
        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Month 3: Same volume (now using new rates 150)
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 600_000 ether);

        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Should now see new rate applied to month 3
        (,uint256 l2_new,,,,) = referral.getTotalReferralRewards(alice);
        uint256 expectedNew = expectedOld + (600_000 ether * 150) / 10000;
        assertEq(l2_new, expectedNew, "Should use new rate in month 3");
    }

    // ========== Min Volume Checkpoint Tests ==========

    function testMinVolumeSchedulingEffectiveNextMonth() public {
        // Test that min volume changes take effect only from next month forward
        vm.warp(vm.getBlockTimestamp() + 31 days);
        _registerCode();

        // Month 1: Trade with initial min volumes
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 600_000 ether); // Above initial L2 min (500k)

        // Schedule new min volumes for next month (1M)
        vm.prank(referral.owner());
        referral.setMinVolumeForL2L3(1_000_000 ether, 2_000_000 ether);

        // setUp already creates a month-1 checkpoint (1k/2k), so this adds a third
        assertEq(referral.getMinVolumeCheckpointCount(), 3, "Should have 3 checkpoints");

        // Month 2: Trade with new min volumes (now requires 1M, so 600k won't qualify)
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 600_000 ether);

        // Move to month 3 to view claimable rewards
        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Month 1 rewards should use old min (500k) → qualifies
        // Month 2 rewards should use new min (1M) → does not qualify
        (,uint256 l2Total,,,,) = referral.getTotalReferralRewards(alice);
        uint256 month1L2 = (600_000 ether * 100) / 10000; // Old min, qualifies
        uint256 month2L2 = 0; // New min (1M), doesn't qualify
        assertEq(l2Total, month1L2 + month2L2, "L2 should respect per-month min volumes");
    }

    function testMinVolumePreservedForPreviousMonths() public {
        // Verify that changing min volumes doesn't affect already-earned rewards
        vm.warp(vm.getBlockTimestamp() + 31 days);
        _registerCode();

        // Month 1: Earn L2 rewards with initial min volume (500k)
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 600_000 ether); // Above 500k

        vm.warp(vm.getBlockTimestamp() + 31 days);
        (,uint256 l2First,,,,) = referral.getTotalReferralRewards(alice);
        uint256 expectedFirst = (600_000 ether * 100) / 10000;
        assertEq(l2First, expectedFirst, "First month should use initial min");

        // Now drastically increase min volume
        vm.prank(referral.owner());
        referral.setMinVolumeForL2L3(10_000_000 ether, 20_000_000 ether);

        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Month 2: Trade with new high min volumes
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 600_000 ether);

        vm.warp(vm.getBlockTimestamp() + 31 days);
        (,uint256 l2Total,,,,) = referral.getTotalReferralRewards(alice);

        // First month should still be included (600k >= 500k), not affected by new high min
        assertEq(l2Total, expectedFirst, "Old month min volumes should be preserved");
    }

    function testMinVolumesScheduledEvent() public {
        vm.warp(vm.getBlockTimestamp() + 31 days);

        vm.prank(referral.owner());
        vm.expectEmit(true, true, true, true);
        emit DoppiReferral.MinVolumesScheduled(1_000 ether, 2_000 ether, 1_000_000 ether, 2_000_000 ether, _currentMonthId() + 1);
        referral.setMinVolumeForL2L3(1_000_000 ether, 2_000_000 ether);
    }

    function testOverwritePendingMinVolumeUpdate() public {
        // Test that setting min volumes twice in same effective month overwrites the first
        vm.warp(vm.getBlockTimestamp() + 31 days);

        uint24 effectiveMonth = _currentMonthId() + 1;
        assertEq(referral.getMinVolumeCheckpointCount(), 2, "Should start with 2 checkpoints");

        // First min volume change scheduled for next month
        vm.prank(referral.owner());
        referral.setMinVolumeForL2L3(1_000_000 ether, 2_000_000 ether);
        assertEq(referral.getMinVolumeCheckpointCount(), 3, "Should add checkpoint");

        (uint24 month1, uint256 minL2_1, uint256 minL3_1) = referral.getMinVolumeCheckpoint(2);
        assertEq(month1, effectiveMonth, "Month should match");
        assertEq(minL2_1, 1_000_000 ether, "First update");

        // Second min volume change for same month overwrites
        vm.prank(referral.owner());
        referral.setMinVolumeForL2L3(2_000_000 ether, 3_000_000 ether);
        assertEq(referral.getMinVolumeCheckpointCount(), 3, "Should not add another checkpoint");

        (uint24 month2, uint256 minL2_2, uint256 minL3_2) = referral.getMinVolumeCheckpoint(2);
        assertEq(month2, effectiveMonth, "Month should still match");
        assertEq(minL2_2, 2_000_000 ether, "Should be overwritten");
        assertEq(minL3_2, 3_000_000 ether, "Should be overwritten");
    }

    function testGetMinVolForMonth() public {
        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Month 0-1 should use initial min volumes
        (uint256 minL2, uint256 minL3) = referral.getMinVolForMonth(0);
        assertEq(minL2, 500_000 ether, "Month 0 L2 min");
        assertEq(minL3, 1_000_000 ether, "Month 0 L3 min");

        // Schedule new min volumes for month 2
        uint24 currentMonth = _currentMonthId();
        vm.prank(referral.owner());
        referral.setMinVolumeForL2L3(1_000_000 ether, 2_000_000 ether);

        // Month 1 already uses setUp scheduled min volumes (1k/2k)
        (minL2, minL3) = referral.getMinVolForMonth(1);
        assertEq(minL2, 1_000 ether, "Month 1 still baseline scheduled min");
        assertEq(minL3, 2_000 ether, "Month 1 still baseline scheduled min");

        // Month 2+ use new min volumes
        (minL2, minL3) = referral.getMinVolForMonth(currentMonth + 1);
        assertEq(minL2, 1_000_000 ether, "Month 2+ new L2 min");
        assertEq(minL3, 2_000_000 ether, "Month 2+ new L3 min");
    }

    function testGetMinVolumeCheckpoint() public {
        assertEq(referral.getMinVolumeCheckpointCount(), 2, "Initial checkpoints from constructor + setUp");

        (uint24 month0, uint256 minL2_0, uint256 minL3_0) = referral.getMinVolumeCheckpoint(0);
        assertEq(month0, 0, "First checkpoint at month 0");
        assertEq(minL2_0, 500_000 ether, "Initial L2 min");
        assertEq(minL3_0, 1_000_000 ether, "Initial L3 min");

        // Check baseline checkpoint created in setUp (effective month 1)
        (uint24 month1, uint256 minL2_1, uint256 minL3_1) = referral.getMinVolumeCheckpoint(1);
        assertEq(month1, 1, "Second checkpoint is setUp baseline at month 1");
        assertEq(minL2_1, 1_000 ether, "Baseline L2 min");
        assertEq(minL3_1, 2_000 ether, "Baseline L3 min");

        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(referral.owner());
        referral.setMinVolumeForL2L3(1_500_000 ether, 3_000_000 ether);

        (uint24 month2, uint256 minL2_2, uint256 minL3_2) = referral.getMinVolumeCheckpoint(2);
        assertEq(month2, _currentMonthId() + 1, "Third checkpoint at next month");
        assertEq(minL2_2, 1_500_000 ether, "Updated L2 min");
        assertEq(minL3_2, 3_000_000 ether, "Updated L3 min");
    }

    function testMixedMinVolumeConversionMultipleMonths() public {
        // Comprehensive test: multiple min volume changes with varied trading
        vm.warp(vm.getBlockTimestamp() + 31 days);
        _registerCode();

        // Month 1: Trade with initial min volumes (500k L2, 1M L3)
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 600_000 ether); // Above 500k L2 min
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(dave, 2_000_000 ether); // Above 1M L3 min

        // Move to month 2 and schedule new min volumes
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(referral.owner());
        referral.setMinVolumeForL2L3(800_000 ether, 1_500_000 ether);

        // Month 2: Trade with new min volumes
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 900_000 ether); // Above 800k L2 min
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(dave, 1_800_000 ether); // Above 1.5M L3 min

        // Move to month 3: Verify all accumulated rewards with mixed min volumes
        vm.warp(vm.getBlockTimestamp() + 31 days);

        (,uint256 l2Total, uint256 l3Total,,,) = referral.getTotalReferralRewards(alice);

        // L2 (from Charlie's trades):
        //   Month 1: 600k >= 500k, qualifies → 600k * 100 / 10000 = 6000
        //   Month 2: 900k >= 800k, qualifies → 900k * 100 / 10000 = 9000
        // Total: 15000
        uint256 expectedL2 = (600_000 ether * 100 / 10000) +
                             (900_000 ether * 100 / 10000);
        assertEq(l2Total, expectedL2, "L2 mixed min volumes");

        // L3 (from Dave's trades):
        //   Month 1: 2M >= 1M, qualifies → 2M * 50 / 10000 = 10000
        //   Month 2: 1.8M >= 1.5M, qualifies → 1.8M * 50 / 10000 = 9000
        // Total: 19000
        uint256 expectedL3 = (2_000_000 ether * 50 / 10000) +
                             (1_800_000 ether * 50 / 10000);
        assertEq(l3Total, expectedL3, "L3 mixed min volumes");
    }

    function testMinVolumeChangeBlocksRewards() public {
        // Test that increasing min volume blocks rewards for trades that don't meet new threshold
        vm.warp(vm.getBlockTimestamp() + 31 days);
        _registerCode();

        // Initial low min volume
        vm.prank(referral.owner());
        referral.setMinVolumeForL2L3(100_000 ether, 200_000 ether);

        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Month 1: Trade at mid-level
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 500_000 ether);

        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Should qualify with low min
        (,uint256 l2First,,,,) = referral.getTotalReferralRewards(alice);
        uint256 expectedFirst = (500_000 ether * 100) / 10000;
        assertEq(l2First, expectedFirst, "Should qualify with low min");

        // Increase min volume drastically
        vm.prank(referral.owner());
        referral.setMinVolumeForL2L3(3_000_000 ether, 5_000_000 ether);

        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Month 2: Same trade amount (500k) now fails new high min
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(charlie, 500_000 ether);

        vm.warp(vm.getBlockTimestamp() + 31 days);

        // Month 2 should NOT qualify (500k < 3M new min)
        (,uint256 l2Total,,,,) = referral.getTotalReferralRewards(alice);
        assertEq(l2Total, expectedFirst, "Month 2 should not qualify with new high min");
    }

}
