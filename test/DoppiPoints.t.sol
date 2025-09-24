// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DoppiPoints} from "../src/mainnet/DoppiPoints.sol";

contract DoppiPointsTest is Test {
    DoppiPoints doppiPoints;
    address trader1 = address(0x1);
    address trader2 = address(0x2);
    address mockDoppiCore = address(0x3);
    address mockDoppiClaim = address(0x4);

    function setUp() public {

        doppiPoints = new DoppiPoints();
        doppiPoints.setDoppiCore(mockDoppiCore);
        doppiPoints.setDoppiClaim(mockDoppiClaim);
    }

    function testRecordTradeIncreasesPointsAndVolume() public {
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 100); // trader1 trades 100 USDT

        (uint256 volume, uint256 points) = doppiPoints.traders(trader1);

        assertEq(volume, 100, "Volume should equal 100");
        assertEq(points, 100, "Points should equal 100");

        vm.stopPrank();
    }

    function testRecordTradeIncreasesPointsAndVolume_BTC() public {
        
        uint256 btcamount = 0.1 ether;
        uint256 rate = 100_000 * 1e8;
        uint256 inUSDT = btcamount * rate / 1e8;
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, btcamount * rate / 1e8);

        (uint256 volume, uint256 points) = doppiPoints.traders(trader1);

        assertEq(volume, inUSDT, "Volume should in USDT");

        vm.stopPrank();
    }

    function testMultipleTradesAccumulateCorrectly() public {
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 50);
        vm.stopPrank();
        vm.warp(block.timestamp + 15 days + 1);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 150);
        vm.stopPrank();
        
        vm.warp(block.timestamp + 15 days + 1);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader2, 150);
        vm.stopPrank();
        
        (uint256 volume, uint256 points) = doppiPoints.traders(trader1);

        assertEq(volume, 200, "Total volume should equal 200");
        assertEq(points, 200, "Total points should equal 200");
    }

    function testDifferentTradersIndependent() public {
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 70);
        vm.stopPrank();
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader2, 30);
        vm.stopPrank();
        
        (uint256 v1, uint256 p1) = doppiPoints.traders(trader1);
        (uint256 v2, uint256 p2) = doppiPoints.traders(trader2);

        assertEq(v1, 70, "Trader1 volume");
        assertEq(p1, 70, "Trader1 points");

        assertEq(v2, 30, "Trader2 volume");
        assertEq(p2, 30, "Trader2 points");
        vm.stopPrank();
    }

    function testGetPointsReturnsCorrectValue() public {
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 123);

        uint256 pts = doppiPoints.getPoints(trader1);
        assertEq(pts, 123, "Points should equal 123");
        vm.stopPrank();
    }

    function testRevertOnZeroVolume() public {
        
        vm.prank(mockDoppiCore);
        vm.expectRevert(bytes("Volume must be > 0"));
        doppiPoints.recordTrade(trader1, 0);
        vm.stopPrank();
    }

    function testEventEmittedOnRecordTrade() public {
        vm.expectEmit(true, true, false, true);
        emit DoppiPoints.TradeRecorded(trader1, 200, 200);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 200);
        vm.stopPrank();
    }

    function testResetPoint() public {
        // Record a trade -> trader1 gets 100 points
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 100);
        vm.stopPrank();
        assertEq(doppiPoints.getPoints(trader1), 100, "Points should be 100");

        // Pretend we are trader1 and claim
        vm.prank(mockDoppiClaim);
        doppiPoints.resetPoint(trader1);
        assertEq(doppiPoints.getPoints(trader1), 0, "Points should be reset after claim");
    }

    function testMonthId() public {
        // --- Bucket 1 ---
        vm.warp(block.timestamp + 31 days); // jump into first bucket
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 50);
        vm.stopPrank();

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 150);
        vm.stopPrank();

        uint256 bucket1 = block.timestamp / 30 days;
        assertEq(bucket1, 1, "Expected bucket1 = 1");
        assertEq(doppiPoints.getMonthlyVolume(trader1, bucket1), 200, "Bucket1 should equal 200");


        // --- Bucket 2 ---
        vm.warp(block.timestamp + 29 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 150);
        vm.stopPrank();

        vm.warp(block.timestamp + 13 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 150);
        vm.stopPrank();

        vm.warp(block.timestamp + 15 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 150);
        vm.stopPrank();

        uint256 bucket2 = block.timestamp / 30 days;
        assertEq(bucket2, 2, "Expected bucket2 = 2");
        assertEq(doppiPoints.getMonthlyVolume(trader1, bucket2), 450, "Bucket2 should equal 450");


        // --- Bucket 3 ---
        vm.warp(block.timestamp + 3 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 150);
        vm.stopPrank();

        uint256 bucket3 = block.timestamp / 30 days;
        assertEq(bucket3, 3, "Expected bucket3 = 3");
        assertEq(doppiPoints.getMonthlyVolume(trader1, bucket3), 150, "Bucket3 should equal 150");
    }

}
