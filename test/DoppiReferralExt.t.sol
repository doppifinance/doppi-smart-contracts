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

contract DoppiReferralExtTest is Test {
    DoppiReferral referral;
    DoppiPoints doppiPoints;
    MockDoppiPoints mockdoppiPoints;

    address doppiCore = address(0x3);
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
    address referrer = address(0x99);
    address user1 = address(0x98);
    address doppiClaim = address(0x2);


    // Test constants
    uint256 constant maxL1 = 100;
    uint256 constant maxL2 = 10;
    uint256 constant maxL3 = 2;
    uint16 constant L1_BPS = 150;  // 1.5%
    uint16 constant L2_BPS = 100;  // 1.0%
    uint16 constant L3_BPS = 50;   // 0.5%
    uint256 constant MIN_VOLUME_L2 = 500_000 ether;
    uint256 constant MIN_VOLUME_L3 = 1_000_000 ether;


    function setUp() public {
        
        doppiPoints = new DoppiPoints();
        doppiPoints.setDoppiCore(doppiCore, true);
        // mockdoppiPoints = new MockDoppiPoints();
        referral = new DoppiReferral(
            address(doppiPoints),
            L1_BPS, // 1.5%
            L2_BPS, // 1.0%
            L3_BPS   // 0.5%
        );
        
        referral.setDoppiClaim(doppiClaim);
        doppiPoints.setDoppiReferral(address(referral));
        // fast-forward to known start timestamp
        vm.warp(1735689600 + 60 days);
    }

    function test_ResetClaims_SimpleCase() public {
        
        // Setup referral codes
        bytes32 code = _registerCode(referrer);
        
        // Create relationship: user1 -> referrer
        _registerReferrer(user1, code);
        
        // Record some volume for user1 in month 0
        uint256 volume1 = 600_000 ether; // Qualifies for L2
        _recordVolume(user1, volume1);
        
        // Fast forward to month 2
        vm.warp(vm.getBlockTimestamp() + 60 days);
        
        // Call resetClaims
        vm.prank(doppiClaim);
        referral.resetClaims(referrer);
        
        // Check results
        DoppiReferral.ReferralInfo memory info = referral.getReferralInfo(referrer);
        
        // Expected rewards:
        // L1: 600,000 * 1.5% = 9,000
        // L2: 0 * 1.0% = 0 (qualifies since >= 500k)
        // L3: 0 (volume < 1M)
        uint256 expectedL1 = (volume1 * L1_BPS) / 10000;
        assertEq(info.claimedLevel1, expectedL1, "L1 rewards incorrect");
        assertEq(info.claimedLevel2, 0, "L2 rewards incorrect");
        assertEq(info.claimedLevel3, 0, "L3 rewards should be 0");
        assertEq(info.claimedMonthId, 3, "Should claim up to month 3");
    }

    function test_ResetClaims_MaxLimits_50L1_15L2_8L3() public {
        
        vm.startPrank(referral.owner());
        referral.setMinVolumeForL2(70_000_000 ether, 1_000_000 ether);
        vm.stopPrank();

        // Register referrer
        bytes32 code = _registerCode(referrer);
        // Create maximum referral tree (50 L1, 15 L2 per L1, 8 L3 per L2)
        address[maxL1] memory l1Referees;
        address[maxL2][maxL1] memory l2Referees;
        address[maxL3][maxL2][maxL1] memory l3Referees;
        
        // Create 50 L1 referees
        for (uint256 i = 0; i < maxL1; i++) {
            address l1 = address(uint160(0x110 + i));
            // console.log(i, l1, "address l1");
            _registerReferrer(l1, code);
            l1Referees[i] = l1;
            bytes32 l1code = _registerCode(l1);
            
            // Create 15 L2 referees for this L1
            for (uint256 j = 0; j < maxL2; j++) {
                address l2 = address(uint160(0x1100 + i * 100 + j));
                // console.log(j, l2, "address l2");
                _registerReferrer(l2, l1code);
                l2Referees[i][j] = l2;
                bytes32 l2code = _registerCode(l2);
                
                // Create 8 L3 referees for this L2
                for (uint256 k = 0; k < maxL3; k++) {
                    address l3 = address(uint160(0x11000 + i * 1100 + j * 101 + k));
                    // console.log(k, l3, "address l3");
                    _registerReferrer(l3, l2code);
                    l3Referees[i][j][k] = l3;
                    bytes32 l2code = _registerCode(l3);
                }
            }
        }
        
        // Record volume for all traders in month 0
        // L1 traders: 600k each (qualifies for L2)
        for (uint256 i = 0; i < maxL1; i++) {
            _recordVolume(l1Referees[i], 600_000 ether);
        }
        
        // L2 traders: 300k each (doesn't qualify for L2)
        for (uint256 i = 0; i < maxL1; i++) {
            for (uint256 j = 0; j < maxL2; j++) {
                _recordVolume(l2Referees[i][j], 1 ether);
            }
        }
        
        // L3 traders: 1.2M each (qualifies for L3)
        for (uint256 i = 0; i < maxL1; i++) {
            for (uint256 j = 0; j < maxL2; j++) {
                for (uint256 k = 0; k < maxL3; k++) {
                    _recordVolume(l3Referees[i][j][k], 1_200_000 ether);
                }
            }
        }

        (uint256 totalL1, uint256 totalL2, uint256 totalL3,
                uint256 currentL1, uint256 currentL2, uint256 currentL3)  = referral.getTotalReferralRewards(referrer);

        // console.log("Total L1 Rewards:", totalL1);
        // console.log("Total L2 Rewards:", totalL2);
        // console.log("Total L3 Rewards:", totalL3);
        // console.log("Current L1 Rewards:", currentL1);
        // console.log("Current L2 Rewards:", currentL2);
        // console.log("Current L3 Rewards:", currentL3);

        // Fast fcrward to month 2
        vm.warp(vm.getBlockTimestamp() + 60 days);
        
        // Call resetClaims - this should handle the max limits without out-of-gas
        vm.prank(doppiClaim);
        uint256 gasBefore = gasleft();
        referral.resetClaims(referrer);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for max limits calculation:", gasUsed);
        
        // Verify gas is reasonable (well under block limit)
        assertLt(gasUsed, 500_000, "Gas usage too high");
        
        // Calculate expected rewards
        uint256 expectedL1 = 0;
        uint256 expectedL2 = 0;
        uint256 expectedL3 = 0;
        
        // L1 rewards from direct referees (50 × 600k)
        expectedL1 = maxL1 * 600_000 ether * uint256(L1_BPS) / 10000;
        // L2 rewards from L2 referees that qualify (none, since 300k < 500k)
        expectedL2 += 0;
        // L3 rewards from L3 referees that qualify (50×15×8 × 1.2M)
        uint256 l3Count = maxL1 * maxL2 * maxL3; // max set in the contract
        expectedL3 = l3Count * 1_200_000 ether * L3_BPS / 10000;

        DoppiReferral.ReferralInfo memory info = referral.getReferralInfo(referrer);

        assertEq(info.claimedLevel1, expectedL1, "L1 rewards incorrect");
        assertEq(info.claimedLevel2, expectedL2, "L2 rewards incorrect");
        assertEq(info.claimedLevel3, expectedL3, "L3 rewards incorrect");
    }
    
    function test_ResetClaims_MultipleMonths() public {
        
        // Setup referral codes
        bytes32 code = _registerCode(referrer);        
        _registerReferrer(user1, code);
        
        // Record volume in month 0, 1, and 2
        uint256 volume = 600_000 ether;
        _recordVolume(user1, volume);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _recordVolume(user1, volume);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _recordVolume(user1, volume);
        
        // Fast forward to month 4
        vm.warp(vm.getBlockTimestamp() + 30 days);
        
        // Call resetClaims - should claim months 2, 3, 4 (not current month 5)
        vm.prank(doppiClaim);
        referral.resetClaims(referrer);
        
        DoppiReferral.ReferralInfo memory info = referral.getReferralInfo(referrer);
        
        uint256 rewardPerMonth = (volume * L1_BPS / 10000); // + (volume * L2_BPS / 10000);
        uint256 expectedTotal = rewardPerMonth * 3; // 3 months
        
        assertEq(info.claimedLevel1 + info.claimedLevel2, expectedTotal, "Total rewards incorrect");
        assertEq(info.claimedMonthId, 4, "Should claim up to month 4");
    }
    
    function test_ResetClaims_NoNewMonth_ShouldDoNothing() public {
        
        // Setup referral codes
        bytes32 code = _registerCode(referrer);        
        _registerReferrer(user1, code);

        // Record volume in month 0
        _recordVolume(user1, 600_000 ether);
        
        // Fast forward to month 15 days, still in the same monthId
        vm.warp(vm.getBlockTimestamp() + 15 days);
        
        // Call resetClaims - should NOT claim since currentMonthId = claimedMonthId + 1
        vm.prank(doppiClaim);
        vm.expectRevert("still in current month");
        referral.resetClaims(referrer);
        
        DoppiReferral.ReferralInfo memory info = referral.getReferralInfo(referrer);
        
        // Should still be at initial state
        assertEq(_currentMonthId(), info.claimedMonthId + 1, "currentMonthId = claimedMonthId + 1");
        assertEq(info.claimedLevel1, 0, "Should not claim when no new month");
        assertEq(info.claimedMonthId, 1, "claimedMonthId should not change");
    }

    function test_ResetClaims_ByMonthId() public {
        
        // Setup referral codes
        bytes32 code = _registerCode(referrer);        
        _registerReferrer(user1, code);
        
        DoppiReferral.ReferralInfo memory infostart = referral.getReferralInfo(referrer);
        console.log(infostart.claimedMonthId, "infostart.claimedMonthId");
        
        // Record volume in month 0, 1, and 2
        uint256 volume = 600_000 ether;
        _recordVolume(user1, volume);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _recordVolume(user1, volume);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _recordVolume(user1, volume);
        
        // Fast forward to month 4
        vm.warp(vm.getBlockTimestamp() + 30 days);
        
        (uint24 start, uint24 current) = referral.getUnclaimedMonthId(referrer);
        console.log(start, current);

        // Call resetClaims - should claim months 0, 1, 2 (not current month 3)
        vm.prank(doppiClaim);
        referral.resetClaimsByMonthId(referrer, start);
        
        DoppiReferral.ReferralInfo memory info = referral.getReferralInfo(referrer);
        // console.log(info.claimedMonthId, "info.claimedMonthId");
        // console.log(info.claimedLevel1, "info.claimedLevel1");
        // console.log(info.claimedLevel2, "info.claimedLevel2");
        // console.log(info.claimedLevel3, "info.claimedLevel3");
        
        uint256 rewardPerMonth = (volume * L1_BPS / 10000); // + (volume * L2_BPS / 10000);
        
        assertEq(info.claimedLevel1 + info.claimedLevel2, rewardPerMonth, "rewards per month id incorrect");
        assertEq(info.claimedMonthId, 2, "Should claim up to month 4");

        vm.prank(doppiClaim);
        vm.expectRevert("should claimed earlier month");
        referral.resetClaimsByMonthId(referrer, start + 2);
        
        vm.prank(doppiClaim);
        referral.resetClaimsByMonthId(referrer, start + 1);
        vm.prank(doppiClaim);
        referral.resetClaimsByMonthId(referrer, start + 2);

        info = referral.getReferralInfo(referrer);

        vm.prank(doppiClaim);
        vm.expectRevert("still in current month");
        referral.resetClaimsByMonthId(referrer, start + 3);

        vm.prank(doppiClaim);
        vm.expectRevert("not registered");
        referral.resetClaims(user1);
    }
    
    
    
    // internal
    function _getReferee(address trader, address referror, uint256 l1, uint256 l2, uint256 l3) internal {
        
        (address upline,
            address[] memory level1Referees, 
            address[] memory level2Referees, 
            address[] memory level3Referees) = referral.getReferees(trader);

        assertEq(upline, referror);
        assertEq(level1Referees.length, l1);
        assertEq(level2Referees.length, l2);
        assertEq(level3Referees.length, l3);
    }

    function _registerCode(address user) internal returns (bytes32 code) {
        vm.prank(user);
        code = _generateCode(user);
        referral.registerReferralCode(code);
    }

    function _registerReferrer(address referee, bytes32 code) internal {
        // bytes32 code = _generateCode(referrerAddr);
        vm.prank(referee);
        referral.registerReferrer(code);
        vm.stopPrank();
    }

    function _recordVolume(address trader, uint256 volume) internal {
        vm.prank(doppiCore);
        doppiPoints.recordTrade(trader, volume); 
        vm.stopPrank();
    }

    function _generateCode(address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, "referral"));
    }

    // function _registerCode() internal {

    //     // Step 1: Alice registers her code
    //     vm.prank(alice);
    //     referral.registerReferralCode(keccak256("ALICE"));

    //     // Step 2: Bob registers with Alice's code
    //     vm.startPrank(bob);
    //     referral.registerReferralCode(keccak256("BOB"));
    //     referral.registerReferrer(keccak256("ALICE"));
    //     vm.stopPrank();

    //     // Step 3: Charlie registers with Bob's code
    //     vm.startPrank(charlie);
    //     referral.registerReferralCode(keccak256("CHARLIE"));
    //     referral.registerReferrer(keccak256("BOB"));
    //     vm.stopPrank();

    //     // Step 4: Dave registers with Charlie's code
    //     vm.startPrank(dave);
    //     referral.registerReferralCode(keccak256("DAVE"));
    //     referral.registerReferrer(keccak256("CHARLIE"));
    //     vm.stopPrank();
    // } 

    function _currentMonthId() internal view returns (uint24) {
        // 30-day rolling months
        uint256 startTimestamp = 1735689600; // Jan 1, 2025
        return uint24((block.timestamp - startTimestamp) / 30 days);
    }

}
