// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiOpportunity} from "../src/mainnet/DoppiOpportunity.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";

import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {ImpliedVol} from "../src/mainnet/ImpliedVol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";

contract DoppiOpportunityTest is Test {
    DoppiOpportunity doppiOpportunity;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    BlackScholes blackScholes;
    ImpliedVol impliedVol;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;

    address owner = address(this);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address treasury = address(0x3);

    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;

        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(int256(100_000 ether), 18);

        blackScholes = new BlackScholes();
        impliedVol = new ImpliedVol(blackScholes);
        impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);

        doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(usdt), IERC20(btc), treasury);
        doppiLP.setOracle(address(oracle));

        // Create router and set entry points
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));

        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);

        doppiLP.setDualAsset(address(doppiCore));

        doppiOpportunity = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiCore.setAdmin(address(doppiOpportunity), true);

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
        oracle.setPrice(int256(98_500 ether));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
        doppiOpportunity.performUpkeep(performData);
        DoppiCore.DualAssetPosition memory pos = doppiCore.get_buy(user1, 1);
        assertEq(pos.isTraded, true);
    }

    function test_checkUpkeep_opportunitySell() public {
        depositBTC();
        assertEq(doppiCore.getSellPositionCount(), 1);
        oracle.setPrice(int256(101_600 ether));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertGt(performData.length, 0);
        doppiOpportunity.performUpkeep(performData);
        DoppiCore.DualAssetPosition memory pos = doppiCore.get_sell(user2, 1);
        assertEq(pos.isTraded, true);
    }

    function test_checkUpkeep_opportunityTakeSellProfit() public {
        depositBTC();
        oracle.setPrice(int256(110_500 ether));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        doppiOpportunity.performUpkeep(performData);
        DoppiCore.DualAssetPosition memory pos = doppiCore.get_sell(user2, 1);
        assertEq(pos.isTraded, true);

        // unwind for profit opportunity
        oracle.setPrice(int256(98_500 ether));
        (upkeepNeeded, performData) = doppiOpportunity.checkUpkeep("");
        doppiOpportunity.performUpkeep(performData);
        pos = doppiCore.get_sell(user2, 1); // refresh position
        assertEq(pos.isTraded, false); // unwind successfully
        assertGt(doppiOpportunity.profitAssetB(), 0); // profit recorded on BTC
        assertEq(doppiOpportunity.profitAssetA(), 0);
        // assertEq(doppiOpportunity.profitAssetB(), 119584878172588832);
    }

    function test_checkUpkeep_opportunityTakeBuyProfit() public {
        depositUSDT();
        oracle.setPrice(int256(98_500 ether));
        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        doppiOpportunity.performUpkeep(performData);
        DoppiCore.DualAssetPosition memory pos = doppiCore.get_buy(user1, 1);
        assertEq(pos.isTraded, true);

        // unwind for profit opportunity
        oracle.setPrice(int256(100_500 ether));
        (upkeepNeeded, performData) = doppiOpportunity.checkUpkeep("");
        doppiOpportunity.performUpkeep(performData);
        pos = doppiCore.get_sell(user1, 1); // refresh position
        assertEq(pos.isTraded, false); // unwind successfully
        assertEq(doppiOpportunity.profitAssetB(), 0);
        assertGt(doppiOpportunity.profitAssetA(), 0); // profit recorded on USDT
            // assertEq(doppiOpportunity.profitAssetA(), 913248984771573601000);
    }

    // internal function
    function depositUSDT() internal {
        DoppiCore.DualAssetOffer memory buyOffer = doppiCore.getOffer(true, 1, 0);
        DoppiCore.DepositParams memory params = DoppiCore.DepositParams({
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
        DoppiCore.DualAssetOffer memory offer = doppiCore.getOffer(false, 1, 0);
        DoppiCore.DepositParams memory params = DoppiCore.DepositParams({
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
