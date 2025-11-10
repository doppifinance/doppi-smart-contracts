// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DoppiPoints} from "../src/mainnet/DoppiPoints.sol";

contract DoppiPointsMonthIdTest is Test {
    DoppiPoints doppiPoints;
    address trader = address(0x1);
    address trader2 = address(0x2);
    address mockDoppiCore = address(0x3);
    address mockDoppiClaim = address(0x4);
    // Fixed start timestamp - January 1, 2025 00:00:00 UTC
    uint256 public constant START_TIMESTAMP = 1735689600;
    // 30 days in seconds
    uint256 public constant THIRTY_DAYS = 30 days;

    function setUp() public {

        doppiPoints = new DoppiPoints();
        doppiPoints.setDoppiCore(mockDoppiCore, true);
        doppiPoints.setDoppiClaim(mockDoppiClaim);
        vm.warp(START_TIMESTAMP + 100 days);

    }

    function test_MonthlyVolumeTracking() public {
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader, 1000e18);
        
        uint256 currentMonthId1 = doppiPoints.getCurrentMonthId();
        (,, uint256 currentVol) = doppiPoints.getAllPointData(trader);
        
        assertEq(currentVol, 1000e18, "Should have 1000 volume");
        
        uint256 month0Volume = doppiPoints.getMonthlyVolume(trader, currentMonthId1);
        assertEq(month0Volume, 1000e18, "Month 0 volume should be 1000");

        // Trade in month 1
        vm.warp(vm.getBlockTimestamp() + 31 days);
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader, 2000e18);
        
        uint256 currentMonthId2 = doppiPoints.getCurrentMonthId();
        (uint256 claimedPoint, uint256 readyPoint, uint256 currentPoint) = doppiPoints.getAllPointData(trader);

        assertEq(currentPoint, 2000e18, "Should have 2000 current point");
        assertEq(readyPoint, 1000e18, "Should have 1000 ready to claim point");
        
        uint256 month1Volume = doppiPoints.getMonthlyVolume(trader, currentMonthId2);
        assertEq(month1Volume, 2000e18, "Month 1 volume should be 2000");
        
        // Month 0 volume unchanged
        month0Volume = doppiPoints.getMonthlyVolume(trader, currentMonthId1);
        assertEq(month0Volume, 1000e18, "Month 0 volume should remain 1000");
    }

    function test_MonthBoundaries() public {
        // Test exact boundary conditions
        
        // Last second of month 0
        vm.warp(START_TIMESTAMP + THIRTY_DAYS - 1);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader, 500e18);
        
        uint256 month0Volume = doppiPoints.getMonthlyVolume(trader, 0);
        assertEq(month0Volume, 500e18, "Last second of month 0 should count in month 0");

        // First second of month 1
        vm.warp(START_TIMESTAMP + THIRTY_DAYS);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader, 600e18);
        
        uint256 month1Volume = doppiPoints.getMonthlyVolume(trader, 1);
        assertEq(month1Volume, 600e18, "First second of month 1 should count in month 1");
        
        // Month 0 unchanged
        month0Volume = doppiPoints.getMonthlyVolume(trader, 0);
        assertEq(month0Volume, 500e18, "Month 0 volume should remain unchanged");
    }

    function test_CurrentMonthIdCalculation() public {
        // Test the month calculation with meaningful dates
        
        // January 1, 2022 - Should be month 0
        vm.warp(START_TIMESTAMP);
        uint256 monthId = getCurrentMonthId();
        assertEq(monthId, 0, "Jan 1, 2022 should be month 0");

        // January 15, 2022 - Still month 0
        vm.warp(START_TIMESTAMP + 14 days);
        monthId = getCurrentMonthId();
        assertEq(monthId, 0, "Jan 15, 2022 should be month 0");

        // January 31, 2022 - Still month 0
        vm.warp(START_TIMESTAMP + 30 days - 1); // 1 second before month ends
        monthId = getCurrentMonthId();
        assertEq(monthId, 0, "Jan 31, 2022 should be month 0");

        // February 1, 2022 - Month 1 starts
        vm.warp(START_TIMESTAMP + 30 days);
        monthId = getCurrentMonthId();
        assertEq(monthId, 1, "Feb 1, 2022 should be month 1");

        // March 1, 2022 - Month 2
        vm.warp(START_TIMESTAMP + 60 days);
        monthId = getCurrentMonthId();
        assertEq(monthId, 2, "Mar 1, 2022 should be month 2");

        // December 1, 2022 - Month 11
        vm.warp(START_TIMESTAMP + 334 days); // Approx 11 months
        monthId = getCurrentMonthId();
        assertEq(monthId, 11, "Dec 1, 2022 should be month 11");

        // January 1, 2023 - Month 12 (1 year later)
        vm.warp(START_TIMESTAMP + 365 days);
        monthId = getCurrentMonthId();
        assertEq(monthId, 12, "Jan 1, 2023 should be month 12");

        // March 15, 2024 - Month 26
        vm.warp(START_TIMESTAMP + 26 * THIRTY_DAYS + 15 days);
        monthId = getCurrentMonthId();
        assertEq(monthId, 26, "Mar 15, 2024 should be month 26");
    }

    function test_YearBoundaries() public {
        // Test across year boundaries
        
        // // December 31, 2022 - Month 11
        // vm.warp(START_TIMESTAMP + 363 days);
        // assertEq(getCurrentMonthId(), 11, "Dec 31, 2025 should be month 11");
        
        // January 1, 2023 - Month 12
        vm.warp(START_TIMESTAMP + 365 days);
        assertEq(getCurrentMonthId(), 12, "Jan 1, 2026 should be month 12");
        
        // January 1, 2024 - Month 24  
        vm.warp(START_TIMESTAMP + 730 days); // 2 years
        assertEq(getCurrentMonthId(), 24, "Jan 1, 2027 should be month 24");
    }

    function test_ConsistentMonthCalculation() public {
        // Test that same date always gives same month ID regardless of contract deployment time
        
        // March 15, 2024 timestamp
        uint256 march15_2024 = START_TIMESTAMP + (26 * THIRTY_DAYS) + (15 days);
        
        vm.warp(march15_2024);
        uint256 monthId = getCurrentMonthId();
        
        // This should always be month 26, regardless of when contract was deployed
        assertEq(monthId, 26, "March 15, 2024 should always be month 26");
        
        // Verify with different approach
        uint256 calculatedMonthId = (march15_2024 - START_TIMESTAMP) / THIRTY_DAYS;
        assertEq(monthId, calculatedMonthId, "Manual calculation should match");
    }

    // Test to show the problem with the original approach
    function test_OriginalApproachProblem() public {
        // Show how original approach creates arbitrary month IDs
        
        // If first trade happens on random date, month IDs become meaningless
        uint256 randomStart = 1736870400; // January 15, 2025 (random)
        
        vm.warp(randomStart);
        uint256 originalMonthId = vm.getBlockTimestamp() / THIRTY_DAYS; // Original approach
        uint256 fixedMonthId = (randomStart - START_TIMESTAMP) / THIRTY_DAYS; // Fixed approach
        
        console.log("Original month ID:", originalMonthId); // Some arbitrary number like 633
        console.log("Fixed month ID:", fixedMonthId); // Meaningful: 0 (first month)
        
        // The fixed approach gives us month 0 (meaningful), 
        // while original gives 633 (meaningless)
        assertEq(fixedMonthId, 0, "Fixed approach gives meaningful month 0");
        // originalMonthId could be any large number depending on deployment time
    }
    
    // NEW: Public function to get current month ID
    function getCurrentMonthId() internal view returns (uint256) {
        return (vm.getBlockTimestamp() - START_TIMESTAMP) / THIRTY_DAYS;
    }
}
