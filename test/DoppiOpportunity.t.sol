// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiOpportunity} from "../src/mainnet/DoppiOpportunity.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {DoppiConfig} from "../src/mainnet/DoppiConfig.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {ImpliedVol} from "../src/mainnet/ImpliedVol.sol";
import {IImpliedVol} from "../src/Interface/IImpliedVol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {Swapper} from "../src/test/Swapper.sol";
import "../src/mainnet/DoppiCoreTypes.sol";

contract DoppiOpportunityTest is Test {
    DoppiOpportunity doppiOpportunity;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    DoppiConfig doppiConfig;
    BlackScholes blackScholes;
    ImpliedVol impliedVol;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    Swapper swapper;

    address owner = address(this);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address treasury = address(0x3);
    address mockForwarder = address(0x5);

    event OppPerformed(bool isBuy, address indexed trader, uint256 price, uint256 amount, uint256 amountOut);
    event OppUnwindPerformed(bool isBuy, address indexed trader, uint256 price, uint256 swappedAmount, uint256 amountOut, uint256 profit, address profitToken);
    
    function setUp() public {
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
        impliedVol = new ImpliedVol(blackScholes, address(oracle), 500);
        impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);

        // deploy doppiConfig
        doppiConfig = new DoppiConfig();

        // Deploy Swapper that will act as both router and pool
        swapper = new Swapper(MockToken(usdt), MockToken(btc));
        swapper.setOracle(MockOracle(oracle));    
        doppiConfig.setRouter(address(swapper));
        doppiConfig.setQuoter(address(swapper));
        doppiConfig.setTreasury(treasury);
        doppiConfig.setOracle(address(oracle));
        doppiConfig.setImpliedVol(address(impliedVol)); 

        doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(usdt), IERC20(btc));
        doppiLP.setDoppiConfig(doppiConfig);
        doppiLP.approveRouter();

        // Create router and set entry points
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));

        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);

        doppiLP.setDoppiCore(address(doppiCore));

        doppiOpportunity = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiCore.setAdmin(address(doppiOpportunity), true);
        doppiOpportunity.setForwarderAddress(mockForwarder);
        doppiOpportunity.setDoppiConfig(doppiConfig);

        // Mint tokens to a liquidity provider and properly deposit into LP
        address liquidityProvider = address(0x999);
        usdt.mint(liquidityProvider, 1_000_000 ether);
        btc.mint(liquidityProvider, 10 ether);

        usdt.mint(address(doppiLP), 1_000_000 ether);
        btc.mint(address(doppiLP), 10 ether);
        usdt.mint(user1, 200_000 ether);
        btc.mint(user1, 2 ether);
        usdt.mint(user2, 200_000 ether);
        btc.mint(user2, 2 ether);
    }

    function test_constructor() public view {
        assertEq(doppiOpportunity.owner(), owner);
        assertEq(address(doppiOpportunity.doppiLP()), address(doppiLP));
        assertEq(address(doppiOpportunity.doppiCore()), address(doppiCore));
    }

    function test_checkUpkeep_opportunityBuy() public {
        depositUSDT();
        assertEq(doppiCore.getBuyPositionCount(), 1);
        oracle.setPrice(int256(98_500  * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
        DualAssetPosition memory pos = doppiCore.get_buy(user1, 1);
        assertEq(pos.isTraded, true);
    }

    function test_checkUpkeep_opportunitySell() public {
        depositBTC();
        assertEq(doppiCore.getSellPositionCount(), 1);
        oracle.setPrice(int256(101_600 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
        DualAssetPosition memory pos = doppiCore.get_sell(user2, 1);
        assertEq(pos.isTraded, true);
    }

    function test_checkUpkeep_opportunityTakeSellProfit() public {
        depositBTC();
        oracle.setPrice(int256(110_500  * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
        DualAssetPosition memory pos = doppiCore.get_sell(user2, 1);
        assertEq(pos.isTraded, true);

        // unwind for profit opportunity
        oracle.setPrice(int256(98_500 * 1e8));
        (upkeepNeeded, performData) = doppiOpportunity.checkUpkeep("");
        
        vm.expectEmit(true, true, true, true);
        emit OppUnwindPerformed(
            false,
            user2,
            98_500 * 1e8,
            110389500000000000000000,
            1119584878172588832,
            119584878172588832, // profit
            address(btc) // profit in asset A
        );

        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
        pos = doppiCore.get_sell(user2, 1); // refresh position
        assertEq(pos.isTraded, false); // unwind successfully
    }

    function test_checkUpkeep_opportunityTakeBuyProfit() public {
        depositUSDT();
        oracle.setPrice(int256(98_500 * 1e8));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
        DualAssetPosition memory pos = doppiCore.get_buy(user1, 1);
        assertEq(pos.isTraded, true);

        // unwind for profit opportunity
        oracle.setPrice(int256(100_500 * 1e8));
        (upkeepNeeded, performData) = doppiOpportunity.checkUpkeep("");
        
        vm.expectEmit(true, true, true, true);
        emit OppUnwindPerformed(
            true,
            user1,
            100_500 * 1e8,
            507106598984771573,
            50913248984771573601000,
            913248984771573601000, // profit
            address(usdt) // profit in asset A
        );

        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
        pos = doppiCore.get_sell(user1, 1); // refresh position
        assertEq(pos.isTraded, false); // unwind successfully
    }

     // Event emit test
    function test_OpportunityOppPerformed_EmitsEvent() public {
        
        depositUSDT();
        oracle.setPrice(int256(98_500 * 1e8));
        (, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        vm.expectEmit(true, true, true, true);
        emit OppPerformed(
            true,
            user1,
            98_500 * 1e8,
            50_000 ether,
            507106598984771573
        );    
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
    }

    function test_OpportunityOppUnwindPerformed_EmitsEvent() public {
        
        depositUSDT();
        oracle.setPrice(int256(98_500 * 1e8));
        (, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);

        oracle.setPrice(int256(100_500 * 1e8));
        (, performData) = doppiOpportunity.checkUpkeep("");

        vm.expectEmit(true, true, true, true);
        emit OppUnwindPerformed(
            true,
            user1,
            100_500 * 1e8,
            507106598984771573,
            50913248984771573601000,
            913248984771573601000,
            address(usdt)
        );    

        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
    }

    function test_checkUpkeep_opportunityBuy_withPagination() public {
        
        depositUSDT();
        depositUSDT();
        depositUSDT();
        
        assertEq(doppiCore.getBuyPositionCount(), 3);
        oracle.setPrice(int256(98_500  * 1e8));
        doppiOpportunity.setUpkeeps_per_check(2);

        // first checkUpkeep
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        (, uint256[] memory buyIndexes, ) =
            abi.decode(performData, (uint256, uint256[], uint256[]));
        assertEq(buyIndexes.length, 2);

        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
        vm.stopPrank();

        DualAssetPosition memory pos2 = doppiCore.get_buy(user1, 1);
        DualAssetPosition memory pos3 = doppiCore.get_buy(user1, 2);
        assertTrue(pos2.isTraded);
        assertTrue(pos3.isTraded);
        
        // second checkUpkeep
        (upkeepNeeded, performData) = doppiOpportunity.checkUpkeep("");
        assertTrue(upkeepNeeded);
        (, buyIndexes, ) = abi.decode(performData, (uint256, uint256[], uint256[]));
        assertEq(buyIndexes.length, 1);

        vm.prank(mockForwarder);
        doppiOpportunity.performUpkeep(performData);
        vm.stopPrank();
        
        DualAssetPosition memory pos1 = doppiCore.get_buy(user1, 3);
        assertTrue(pos1.isTraded);
        
        // third checkUpkeep no more opportunity
        (upkeepNeeded, ) = doppiOpportunity.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    // internal function
    function depositUSDT() internal {
        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 0);
        DepositParams memory params = DepositParams({
            amount: 50_000 ether,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            validityTime: buyOffer.validUntilTimestamp
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
            validityTime: offer.validUntilTimestamp
        });

        vm.startPrank(user2);
        btc.approve(address(doppiCore), params.amount);
        doppiCore.deposit_sell(params);
        vm.stopPrank();
    }

    
}
