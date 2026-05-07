// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiOpportunity} from "../src/mainnet/DoppiOpportunity.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {DoppiOffer} from "../src/mainnet/DoppiOffer.sol";
import {IDoppiOffer} from "../src/Interface/IDoppiOffer.sol";
import {DoppiPoints} from "../src/mainnet/DoppiPoints.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {Swapper} from "../src/test/Swapper.sol";
import "../src/mainnet/DoppiCoreTypes.sol";
import {TestParamLib} from "../src/Library/TestParamLib.sol";
import "../src/mainnet/DoppiLiquidityTypes.sol";

contract DoppiCorePartialFillTest is Test {
    DoppiOpportunity doppiOpportunity;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiPoints doppiPoints;
    DoppiLiquidityRouter doppiRouter;
    BlackScholes blackScholes;
    DoppiOffer impliedVol;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    Swapper swapper;
    ConfigParam configLP;

    address owner = address(this);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address treasury = address(0x3);
    address mockForwarder = address(0x5);
    address trader = address(0x6);
    address liquidityProvider = makeAddr("liquidityProvider");
    address pos1Owner         = makeAddr("pos1Owner");
    address pos2Owner         = makeAddr("pos2Owner");
    address pos3Owner         = makeAddr("pos3Owner");

    uint256 constant POSITION_SIZE = 10_000 ether;  // USDT per position
    uint256 constant TOTAL_DEPOSITS = 3 * POSITION_SIZE; // 30 000 USDT
    // maxSwap is set to POSITION_SIZE * 2.5 so that exactly 2.5/3 of the bucket
    // is executed: Pos1 fully traded, Pos2 fully traded, Pos3 partially traded.
    uint256 constant MAX_SWAP = 25_000 ether; // 25 000 USDT


    event OppPerformed(bool isBuy, uint256 price, uint256 amount, uint256 amountOut);
    event OppUnwindPerformed(bool isBuy, uint256 price, uint256 swappedAmount, uint256 amountOut, uint256 profit, address profitToken);
    
    function setUp() public {
        
        vm.warp(1735689600); 
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;

        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(int256(100_000 * 1e8), 8);

        blackScholes = new BlackScholes();
        impliedVol = new DoppiOffer(blackScholes, address(oracle), 500);
        impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);

        // Deploy Swapper that will act as both router and pool
        swapper = new Swapper(MockToken(usdt), MockToken(btc));
        swapper.setOracle(MockOracle(oracle));    
        doppiPoints = _deployDoppiPoints();
        doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(usdt), IERC20(btc));
        
        configLP = TestParamLib.get_configLP();
        configLP.chainLinkFeed = address(oracle);
        configLP.router = address(swapper);
        doppiLP.setConfig(configLP);
        doppiLP.approveRouter();
        // Create router and set entry points
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        
        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol, address(doppiPoints));
        doppiPoints.setDoppiCore(address(doppiCore), true);
        
        doppiLP.setDoppiCore(address(doppiCore));

        doppiOpportunity = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiCore.setOpportunityBot(address(doppiOpportunity), true);
        doppiCore.setTreasury(treasury, 1000);
        doppiOpportunity.setForwarderAddress(mockForwarder);
        doppiCore.setForwarderAddress(mockForwarder);

        uint256 lpUSDT = 5_000_000 ether;
        uint256 lpBTC  = 50 ether;
        usdt.mint(liquidityProvider, lpUSDT);
        btc.mint(address(liquidityProvider), lpBTC);
        
        vm.startPrank(liquidityProvider);
        usdt.approve(address(doppiRouter), lpUSDT);
        btc.approve(address(doppiRouter),  lpBTC);
        doppiRouter.deposit(address(usdt), lpUSDT);
        doppiRouter.deposit(address(btc),  lpBTC);
        vm.stopPrank();
        
    }

    function test_PartialFill_DesiredBehavior_OppBucketClearedAfterSettlement() public {


        (uint256 strikePrice, uint256 settlementPrice) = _setupPartialFillScenario();

        OpportunityOrders memory oppAfter = doppiCore.getOpportunityOrders(true, strikePrice);
        console.log("swappedAmount after settlement:", oppAfter.swappedAmount);
        console.log("outAmount after settlement:", oppAfter.outAmount);
        console.log("amount after settlement:", oppAfter.amount);

        settlementPrice = 80_000 * 1e8;
        oracle.setPrice(int256(settlementPrice));
        
        // settle all 3 positions ??????????????????????????????????????????
        _doppiCoreCheckUpkeep_performUpkeep();
        
        oppAfter = doppiCore.getOpportunityOrders(true, strikePrice);
        console.log("swappedAmount after settlement:", oppAfter.swappedAmount);
        console.log("outAmount after settlement:", oppAfter.outAmount);
        console.log("amount after settlement:", oppAfter.amount);

        // ?? DESIRED: bucket fully consumed after all 3 positions are settled ??
        OpportunityOrders memory opp = doppiCore.getOpportunityOrders(true, strikePrice);


        assertEq(usdt.balanceOf(address(doppiCore)), 0, "USDT balance of doppiCore should be zero");
        assertEq(btc.balanceOf(address(doppiCore)), 0, "BTC balance of doppiCore should be zero");
        
        assertEq(
            opp.swappedAmount,
            0,
            "FAIL (F-01): orphaned swappedAmount after full settlement -- Pos3 partial portion not consumed"
        );
        assertEq(
            opp.outAmount,
            0,
            "FAIL (F-01): orphaned outAmount after full settlement -- Pos3 partial BTC not distributed"
        );

        // payout sanity: every position owner received BTC ????????????????
        uint256 expectedPayout = (POSITION_SIZE * 1e8) / strikePrice; // p.payout set at deposit
        assertApproxEqRel(btc.balanceOf(pos1Owner), expectedPayout, 0.05e18, "Pos1 BTC payout incorrect");
        assertApproxEqRel(btc.balanceOf(pos2Owner), expectedPayout, 0.05e18, "Pos2 BTC payout incorrect");
        assertApproxEqRel(btc.balanceOf(pos3Owner), expectedPayout, 0.05e18, "Pos3 BTC payout incorrect");

    }

    function _setupPartialFillScenario()
        internal
        returns (uint256 strikePrice, uint256 settlementPrice)
    {
        
        DualAssetOffer memory offer = impliedVol.getOffer(true, 1, 1);
        strikePrice = offer.strikePrice; // = 99 500 * 1e8
        
        // Cap maxSwap so only 25 000 / 30 000 USDT executes
        vm.startPrank(doppiCore.owner());
        doppiCore.setMaxSwap(25000 ether);
        vm.stopPrank();

        // Three position owners deposit 
        address[3] memory owners = [pos1Owner, pos2Owner, pos3Owner];
        for (uint256 i = 0; i < owners.length; i++) {
            usdt.mint(owners[i], POSITION_SIZE);
            vm.startPrank(owners[i]);
            usdt.approve(address(doppiCore), POSITION_SIZE);
            doppiCore.deposit_buy(DepositParams({
                amount:      POSITION_SIZE,
                strikeZone:  1,
                strikePrice: offer.strikePrice,
                numDays:     1,
                apr:         offer.apr,
                expiry:      offer.expiry
            }));
            vm.stopPrank();
        }

        // Confirm the bucket has the expected total amount
        OpportunityOrders memory oppInit = doppiCore.getOpportunityOrders(true, strikePrice);
        assertEq(oppInit.amount, TOTAL_DEPOSITS, "Bucket amount mismatch after deposits");
        assertEq(oppInit.swappedAmount, 0,        "No swap should have happened yet");

        // Drop price to trigger opportunity (buy strike > triggerPrice) ??
        // triggerPrice = newPrice + oneDayBuffer(newPrice)
        // At 80 000, 1-day buffer ? a few percent ? triggerPrice ? 82 000-84 000
        // strikePrice ? 99 500 >> 84 000, so opportunity is triggered.
        uint256 settlementPrice = 80_000 * 1e8;
        oracle.setPrice(int256(settlementPrice));
        
        // Run opportunity upkeep -- partial fill (25 000 / 30 000) ???????
        _doppiOpportunityCheckUpkeep_performUpkeep();

        // Assert partial fill was recorded
        OpportunityOrders memory oppPartial = doppiCore.getOpportunityOrders(true, strikePrice);
        assertEq(
            oppPartial.swappedAmount,
            MAX_SWAP,
            "Partial fill: swappedAmount must equal MAX_SWAP after opportunity"
        );
        assertGt(oppPartial.outAmount, 0, "Partial fill: outAmount must be > 0 after opportunity");

        // Advance time past expiry and keep price ITM
        vm.warp(block.timestamp + 1 days + 1);
    }

    function _doppiCoreCheckUpkeep_performUpkeep() internal {

        uint256 gasBefore = gasleft();
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        uint256 gasUsed = gasBefore - gasleft();
        console.log(upkeepNeeded, gasUsed, "gasUsed in doppiCore.checkUpkeep");
        assertLt(gasUsed, 500_000, "Gas usage too high");

        if(upkeepNeeded){
            vm.prank(mockForwarder);
            gasBefore = gasleft();
            doppiCore.performUpkeep(performData);
            gasUsed = gasBefore - gasleft();
            console.log(gasUsed, "gasUsed in doppiCore.performUpkeep");
            assertLt(gasUsed, 2_000_000, "Gas usage too high");
            vm.stopPrank();
        }else{
            console.log("No upkeep needed at this time");
        }
    }

    function depositUSDT() internal {
        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 1);
        DepositParams memory params = DepositParams({
            amount: 50_000 ether,
            strikeZone: 1,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            expiry: buyOffer.expiry
        });

        vm.startPrank(user1);
        usdt.approve(address(doppiCore), params.amount);
        doppiCore.deposit_buy(params);
        vm.stopPrank();
    }

    function depositBTC() internal {
        DualAssetOffer memory offer = impliedVol.getOffer(false, 1, 0);
        DepositParams memory params = DepositParams({
            amount: 1 ether,
            strikeZone: 0,
            strikePrice: offer.strikePrice,
            numDays: 1,
            apr: offer.apr,
            expiry: offer.expiry
        });

        vm.startPrank(user2);
        btc.approve(address(doppiCore), params.amount);
        doppiCore.deposit_sell(params);
        vm.stopPrank();
    }

    function _doppiOpportunityCheckUpkeep_performUpkeep() internal {
        
        uint256 gasBefore = gasleft();
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        uint256 gasUsed = gasBefore - gasleft();
        console.log(upkeepNeeded, gasUsed, "gasUsed in doppiOpportunity.checkUpkeep");
        assertLt(gasUsed, 500_000, "Gas usage too high");

        if(upkeepNeeded){
            vm.prank(mockForwarder);
            gasBefore = gasleft();
            doppiOpportunity.performUpkeep(performData);
            gasUsed = gasBefore - gasleft();
            console.log(gasUsed, "gasUsed in doppiOpportunity.performUpkeep");
            assertLt(gasUsed, 2_000_000, "Gas usage too high");
            vm.stopPrank();
        }
        
    }

    function _deployDoppiPoints() internal returns (DoppiPoints) {
        console.log("Deploying DoppiPoints...");
        DoppiPoints _doppiPoints = new DoppiPoints();
        console.log("DoppiPoints deployed at:", address(_doppiPoints));
        return _doppiPoints;
    }

    function _displayBound(uint256 lowerBound, uint256 upperBound) internal view {
        
        for (uint256 price = upperBound; price >= lowerBound; ) {
            // console.log(price, "price");
            bool isBuy = true;
            (uint256 amount, uint256 swappedAmount, uint256 outAmount) = doppiCore.opportunityBuy(price);
            
            if(amount == 0){
                isBuy = false;
                (amount, swappedAmount, outAmount) = doppiCore.opportunitySell(price);
            }
            console.log(isBuy, price, swappedAmount, outAmount);
            price -= (500 * 1e8); 
        }

    }

    
}
