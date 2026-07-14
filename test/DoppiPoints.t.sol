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
    uint256 startTimestamp = 1735689600;
    function setUp() public {

        doppiPoints = new DoppiPoints();
        doppiPoints.setDoppiCore(mockDoppiCore, true);
        doppiPoints.setDoppiClaim(mockDoppiClaim);
        vm.warp(startTimestamp);

    }

    function testRecordTradeIncreasesPointsAndVolume() public {
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 100); // trader1 trades 100 USDT

        uint24 currentMonthId = doppiPoints.getCurrentMonthId();
        uint256 volume = doppiPoints.getMonthlyVolume(trader1, currentMonthId);
        
        assertEq(volume, 100, "Volume should equal 100");
        assertEq(doppiPoints.totalTradeVolumeUSDT(), 100, "Raw USDT trade volume should equal 100");
        
        vm.stopPrank();
    }

    function testRecordTradeIncreasesPointsAndVolume_BTC() public {
        
        uint256 btcamount = 0.1 ether;
        uint256 rate = 100_000 * 1e8;
        uint256 inUSDT = btcamount * rate / 1e8;
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, btcamount * rate / 1e8);

        uint24 currentMonthId = doppiPoints.getCurrentMonthId();
        uint256 volume = doppiPoints.getMonthlyVolume(trader1, currentMonthId);

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
        
        uint24 currentMonthId = doppiPoints.getCurrentMonthId();
        uint256 volume = doppiPoints.getMonthlyVolume(trader1, currentMonthId);

        assertEq(volume, 200, "Total volume should equal 200");

    }

    function testDifferentTradersIndependent() public {
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 70);
        vm.stopPrank();
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader2, 30);
        vm.stopPrank();
        
        uint24 currentMonthId = doppiPoints.getCurrentMonthId();
        
        uint256 v1 = doppiPoints.getMonthlyVolume(trader1, currentMonthId);
        uint256 v2 = doppiPoints.getMonthlyVolume(trader2, currentMonthId);

        assertEq(v1, 70, "Trader1 volume");
        assertEq(v2, 30, "Trader2 volume");
        vm.stopPrank();
    }

    function testGetPointsReturnsCorrectValue() public {
        
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 123);

        (,, uint256 currentMonthPoint) = doppiPoints.getAllPointData(trader1);
        
        assertEq(currentMonthPoint, 123, "Points should equal 123");
        vm.stopPrank();
    }

    function testRevertOnZeroVolume() public {
        
        vm.prank(mockDoppiCore);
        vm.expectRevert(bytes("volume must be > 0"));
        doppiPoints.recordTrade(trader1, 0);
        vm.stopPrank();
    }

    function testEventEmittedOnRecordTrade() public {
        vm.expectEmit(true, true, false, true);
        emit DoppiPoints.TradeRecorded(trader1, 200);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 200);
        vm.stopPrank();
    }

    function testResetPoint() public {
        // Record a trade -> trader1 gets 100 points
        
        vm.warp(vm.getBlockTimestamp() + 31 days);
        
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 100);
        vm.stopPrank();
        (,, uint256 currentpoints) = doppiPoints.getAllPointData(trader1);
        assertEq(currentpoints, 100, "Points should be 100");

        // Pretend we are trader1 and claim
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(mockDoppiClaim);
        doppiPoints.resetPoint(trader1);
        (,, currentpoints) = doppiPoints.getAllPointData(trader1);
        assertEq(currentpoints, 0, "Points should be reset after claim");
    }

    function testMonthId() public {
        // --- Bucket 1 ---
        vm.warp(vm.getBlockTimestamp() + 31 days); // jump into first bucket
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 50);
        vm.stopPrank();

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 150);
        vm.stopPrank();

        uint256 current = vm.getBlockTimestamp(); //block.timestamp;
        uint256 bucket1 = (vm.getBlockTimestamp() - startTimestamp) / 30 days;
        assertEq(bucket1, 1, "Expected bucket1 = 1");
        assertEq(doppiPoints.getMonthlyVolume(trader1, uint24(bucket1)), 200, "Bucket1 should equal 200");


        // --- Bucket 2 ---
        vm.warp(vm.getBlockTimestamp() + 29 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 150);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 13 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 150);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 15 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 150);
        vm.stopPrank();

        current = vm.getBlockTimestamp(); // 7603201;
        uint256 bucket2 = (vm.getBlockTimestamp() - startTimestamp) / 30 days;
        // console.log(bucket2, block.timestamp, "block.timestamp");
        assertEq(bucket2, 2, "Expected bucket2 = 2");
        assertEq(doppiPoints.getMonthlyVolume(trader1, uint24(bucket2)), 450, "Bucket2 should equal 450");


        // --- Bucket 3 ---
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 150);
        vm.stopPrank();

        current = vm.getBlockTimestamp(); //7862401;
        uint256 bucket3 = (vm.getBlockTimestamp() - startTimestamp) / 30 days;
        console.log(bucket3, vm.getBlockTimestamp(), "block.timestamp");
        assertEq(bucket3, 3, "Expected bucket3 = 3");
        assertEq(doppiPoints.getMonthlyVolume(trader1, uint24(bucket3)), 150, "Bucket3 should equal 150");

        uint24[] memory monthsId = doppiPoints.getMonthIds();
        for(uint256 i=0; i < monthsId.length; i++){
            assertEq(monthsId[i], i+1);
        }
    }

    // ---------------------------------------------------------------------------
    // Multi-factory (per-core) tests
    // ---------------------------------------------------------------------------

    // Minimal mock factory so we can control isTraderBot() without deploying real contracts
    MockTraderFactory mockFactory;
    MockTraderBot    mockBot;

    function _deployMultiFactoryFixture() internal {
        mockFactory = new MockTraderFactory();
        mockBot     = new MockTraderBot(trader1);
        doppiPoints.setCoreTraderFactory(mockDoppiCore, address(mockFactory));
    }

    function testSetCoreTraderFactory_StoredCorrectly() public {
        MockTraderFactory factory = new MockTraderFactory();
        vm.expectEmit(true, true, false, false);
        emit DoppiPoints.CoreTraderFactorySet(mockDoppiCore, address(factory));
        doppiPoints.setCoreTraderFactory(mockDoppiCore, address(factory));

        assertEq(
            address(doppiPoints.coreToTraderFactory(mockDoppiCore)),
            address(factory),
            "Factory should be stored for the given core"
        );
    }

    function testSetCoreTraderFactory_RevertsOnZeroCore() public {
        MockTraderFactory factory = new MockTraderFactory();
        vm.expectRevert(bytes("Zero address"));
        doppiPoints.setCoreTraderFactory(address(0), address(factory));
    }

    function testSetCoreTraderFactory_RevertsOnZeroFactory() public {
        vm.expectRevert(bytes("Zero address"));
        doppiPoints.setCoreTraderFactory(mockDoppiCore, address(0));
    }

    function testSetCoreTraderFactory_OnlyOwner() public {
        MockTraderFactory factory = new MockTraderFactory();
        vm.prank(trader1);
        vm.expectRevert();
        doppiPoints.setCoreTraderFactory(mockDoppiCore, address(factory));
    }

    function testBotVolumeAttributedToRealTrader() public {
        _deployMultiFactoryFixture();

        // Register the bot as known in the mock factory
        mockFactory.registerBot(address(mockBot));

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(address(mockBot), 500);

        uint24 monthId = doppiPoints.getCurrentMonthId();

        // Volume must be under the real trader (trader1), not the bot address
        assertEq(doppiPoints.getMonthlyVolume(trader1, monthId),        500, "Real trader should have volume");
        assertEq(doppiPoints.getMonthlyVolume(address(mockBot), monthId), 0,  "Bot address should have no volume");
    }

    function testUnknownBotFallsBackToItsOwnAddress() public {
        _deployMultiFactoryFixture();
        // mockBot is NOT registered in the factory → isTraderBot returns false

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(address(mockBot), 300);

        uint24 monthId = doppiPoints.getCurrentMonthId();

        assertEq(doppiPoints.getMonthlyVolume(address(mockBot), monthId), 300, "Unregistered bot falls back to its own address");
        assertEq(doppiPoints.getMonthlyVolume(trader1, monthId),           0,  "Real trader should be untouched");
    }

    function testEOATraderUnaffectedByFactory() public {
        _deployMultiFactoryFixture();

        // trader1 is just a plain EOA, not a bot
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader1, 200);

        uint24 monthId = doppiPoints.getCurrentMonthId();
        assertEq(doppiPoints.getMonthlyVolume(trader1, monthId), 200, "EOA volume should be recorded directly");
    }

    function testTwoCoresEachResolveTheirOwnBots() public {
        address mockDoppiCore2 = address(0x5);
        doppiPoints.setDoppiCore(mockDoppiCore2, true);

        MockTraderFactory factoryA = new MockTraderFactory();
        MockTraderFactory factoryB = new MockTraderFactory();

        MockTraderBot botA = new MockTraderBot(trader1); // belongs to core A
        MockTraderBot botB = new MockTraderBot(trader2); // belongs to core B

        factoryA.registerBot(address(botA));
        factoryB.registerBot(address(botB));

        doppiPoints.setCoreTraderFactory(mockDoppiCore,  address(factoryA));
        doppiPoints.setCoreTraderFactory(mockDoppiCore2, address(factoryB));

        // core A records a trade via botA
        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(address(botA), 1000);

        // core B records a trade via botB
        vm.prank(mockDoppiCore2);
        doppiPoints.recordTrade(address(botB), 2000);

        uint24 monthId = doppiPoints.getCurrentMonthId();

        assertEq(doppiPoints.getMonthlyVolume(trader1, monthId), 1000, "trader1 should have 1000 from botA via coreA");
        assertEq(doppiPoints.getMonthlyVolume(trader2, monthId), 2000, "trader2 should have 2000 from botB via coreB");
        assertEq(doppiPoints.getMonthlyVolume(address(botA), monthId), 0, "botA address should have zero volume");
        assertEq(doppiPoints.getMonthlyVolume(address(botB), monthId), 0, "botB address should have zero volume");
    }

    function testCoreWithNoFactoryDoesNotResolveBot() public {
        // mockDoppiCore has no factory configured (no setCoreTraderFactory call)
        MockTraderBot orphanBot = new MockTraderBot(trader1);

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(address(orphanBot), 400);

        uint24 monthId = doppiPoints.getCurrentMonthId();

        // No factory → bot address is used as-is
        assertEq(doppiPoints.getMonthlyVolume(address(orphanBot), monthId), 400, "Orphan bot should accumulate under its own address");
        assertEq(doppiPoints.getMonthlyVolume(trader1, monthId),             0,  "Real trader untouched when no factory configured");
    }

    function testBotVolumeAccumulatesAcrossMultipleTrades() public {
        _deployMultiFactoryFixture();
        mockFactory.registerBot(address(mockBot));

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(address(mockBot), 100);

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(address(mockBot), 250);

        uint24 monthId = doppiPoints.getCurrentMonthId();
        assertEq(doppiPoints.getMonthlyVolume(trader1, monthId), 350, "Accumulated volume should be 350 under real trader");
    }

    function testBotVolumeMultiplier_DefaultOneToOne() public {
        _deployMultiFactoryFixture();
        mockFactory.registerBot(address(mockBot));

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(address(mockBot), 500);

        uint24 monthId = doppiPoints.getCurrentMonthId();
        assertEq(doppiPoints.getMonthlyVolume(trader1, monthId), 500, "Default 1:1 multiplier should keep volume unchanged");
    }

    function testBotVolumeMultiplier_AppliesOnlyToBot() public {
        _deployMultiFactoryFixture();
        mockFactory.registerBot(address(mockBot));
        doppiPoints.setBotVolumeMultiplier(2, 1);

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(address(mockBot), 500);

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(trader2, 200);

        uint24 monthId = doppiPoints.getCurrentMonthId();
        assertEq(doppiPoints.getMonthlyVolume(trader1, monthId), 1000, "Bot volume should be multiplied");
        assertEq(doppiPoints.getMonthlyVolume(trader2, monthId), 200, "EOA volume should stay unchanged");
        assertEq(doppiPoints.totalVolume(), 1200, "Total points volume should include multiplier");
        assertEq(doppiPoints.totalTradeVolumeUSDT(), 700, "Total trade volume should keep raw USDT sum");
    }

    function testTotalTradeVolumeUSDT_IgnoresBotMultiplier() public {
        _deployMultiFactoryFixture();
        mockFactory.registerBot(address(mockBot));
        doppiPoints.setBotVolumeMultiplier(2, 1);

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(address(mockBot), 500);

        assertEq(doppiPoints.totalVolume(), 1000, "Points volume should be multiplied");
        assertEq(doppiPoints.totalTradeVolumeUSDT(), 500, "Raw trade volume should not be multiplied");
    }

    function testSetBotVolumeMultiplier_RevertsOnZeroDenominator() public {
        vm.expectRevert(bytes("Zero denominator"));
        doppiPoints.setBotVolumeMultiplier(1, 0);
    }

    function testSetBotVolumeMultiplier_OnlyOwner() public {
        vm.prank(trader1);
        vm.expectRevert();
        doppiPoints.setBotVolumeMultiplier(3, 2);
    }

    function testBotVolumeMultiplier_AppliesToReferralVolume() public {
        _deployMultiFactoryFixture();
        mockFactory.registerBot(address(mockBot));

        MockReferral referral = new MockReferral();
        referral.setUplineChain(trader1, address(0xAA), address(0xBB), address(0xCC));
        doppiPoints.setDoppiReferral(address(referral));
        doppiPoints.setBotVolumeMultiplier(3, 2); // 1.5x

        vm.prank(mockDoppiCore);
        doppiPoints.recordTrade(address(mockBot), 200);

        uint24 monthId = doppiPoints.getCurrentMonthId();
        (uint256 l1, uint256 l2, uint256 l3) = doppiPoints.getReferralVolumeByMonth(address(0xAA), monthId);
        assertEq(l1, 300, "L1 for first referrer should include multiplied volume");
        assertEq(l2, 0, "No level2 volume should be recorded for L1 address");
        assertEq(l3, 0, "No level3 volume should be recorded for L1 address");

        (l1, l2, l3) = doppiPoints.getReferralVolumeByMonth(address(0xBB), monthId);
        assertEq(l1, 0, "No level1 volume should be recorded for L2 address");
        assertEq(l2, 300, "L2 for second referrer should include multiplied volume");
        assertEq(l3, 0, "No level3 volume should be recorded for L2 address");

        (l1, l2, l3) = doppiPoints.getReferralVolumeByMonth(address(0xCC), monthId);
        assertEq(l1, 0, "No level1 volume should be recorded for L3 address");
        assertEq(l2, 0, "No level2 volume should be recorded for L3 address");
        assertEq(l3, 300, "L3 for third referrer should include multiplied volume");
    }

    function testCoreTraderFactoryCanBeUpdated() public {
        MockTraderFactory factoryOld = new MockTraderFactory();
        MockTraderFactory factoryNew = new MockTraderFactory();

        doppiPoints.setCoreTraderFactory(mockDoppiCore, address(factoryOld));
        assertEq(address(doppiPoints.coreToTraderFactory(mockDoppiCore)), address(factoryOld));

        doppiPoints.setCoreTraderFactory(mockDoppiCore, address(factoryNew));
        assertEq(address(doppiPoints.coreToTraderFactory(mockDoppiCore)), address(factoryNew), "Factory should be updated to new one");
    }

}

// ---------------------------------------------------------------------------
// Minimal mocks
// ---------------------------------------------------------------------------

contract MockTraderFactory {
    mapping(address => bool) private _bots;

    function registerBot(address bot) external {
        _bots[bot] = true;
    }

    function isTraderBot(address bot) external view returns (bool) {
        return _bots[bot];
    }
}

contract MockTraderBot {
    address public validTrader;

    constructor(address _validTrader) {
        validTrader = _validTrader;
    }
}

contract MockReferral {
    struct Chain {
        address l1;
        address l2;
        address l3;
    }

    mapping(address => Chain) private _chains;

    function setUplineChain(address trader, address l1, address l2, address l3) external {
        _chains[trader] = Chain({l1: l1, l2: l2, l3: l3});
    }

    function getUplineChain(address trader) external view returns (address l1, address l2, address l3) {
        Chain memory c = _chains[trader];
        l1 = c.l1;
        l2 = c.l2;
        l3 = c.l3;
    }
}
