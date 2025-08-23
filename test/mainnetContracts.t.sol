// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiTrader} from "../src/mainnet/DoppiTrader.sol";
import {DoppiOpportunity} from "../src/mainnet/DoppiOpportunity.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {ImpliedVol} from "../src/mainnet/ImpliedVol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";

contract MainnetContractsTest is Test {
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    DoppiCore doppiCore;
    DoppiTrader doppiTrader;
    DoppiOpportunity bot;
    BlackScholes blackScholes;
    ImpliedVol impliedVol;

    function setUp() public {
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;

        // Deploy mock tokens and oracle
        uint24[] memory weights = new uint24[](5);
        weights[0] = 500;
        weights[1] = 1000;
        weights[2] = 1500;
        weights[3] = 2500;
        weights[4] = 4500;

        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(100_000 ether, 18);
        blackScholes = new BlackScholes();
        impliedVol = new ImpliedVol(blackScholes);
        impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);

        // Deploy doppiLP with mock oracle
        doppiLP =
            new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(usdt), IERC20(btc), address(2));
        doppiLP.setOracle(address(oracle));

        // Deploy doppiCore
        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);
        doppiLP.setDualAsset(address(doppiCore));

        // Create router and set entry points
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));

        // Deploy Trader with router
        doppiTrader = new DoppiTrader(
            address(2),
            IERC20(address(usdt)),
            IERC20(address(btc)),
            doppiLP,
            doppiRouter,
            doppiCore,
            weights
        );

        // Deploy OpportunityBot
        bot = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiCore.setAdmin(address(bot), true);

        // Mint tokens to doppiTrader
        usdt.mint(address(doppiTrader), 100_000 ether);
        btc.mint(address(doppiTrader), 1 ether);
        usdt.mint(address(doppiLP), 1_000_000 ether);
        btc.mint(address(doppiLP), 10 ether);
    }

    // function testPlaceBuysAndSells() public {
    //     // Trader places buy positions
    //     bool buysPlaced = doppiTrader.place_buys();
    //     assertTrue(buysPlaced, "Buys should be placed");

    //     // Trader places sell positions
    //     bool sellsPlaced = doppiTrader.place_sells();
    //     assertTrue(sellsPlaced, "Sells should be placed");

    //     // Fast forward time by 2 days
    //     vm.warp(block.timestamp + 2 days);

    //     // Settle buy positions
    //     uint256[] memory buys = doppiCore.getReadyBuyPositions();
    //     if (buys.length > 0) doppiCore.settle_buys(buys);

    //     // Settle sell positions
    //     uint256[] memory sells = doppiCore.getReadySellPositions();
    //     if (sells.length > 0) doppiCore.settle_sells(sells);
    // }

    // function testSettleWithDifferentPrices() public {
    //     // Place buys and sells
    //     doppiTrader.place_buys();
    //     doppiTrader.place_sells();

    //     // Fast forward time
    //     vm.warp(block.timestamp + 2 days);

    //     // Test with price below strike (simulate price drop)
    //     oracle.setPrice(95_000 ether);
    //     // Settle buy positions
    //     uint256[] memory buys = doppiCore.getReadyBuyPositions();
    //     if (buys.length > 0) doppiCore.settle_buys(buys);

    //     // Settle sell positions
    //     uint256[] memory sells = doppiCore.getReadySellPositions();
    //     if (sells.length > 0) doppiCore.settle_sells(sells);

    //     // Place again
    //     doppiTrader.place_buys();
    //     doppiTrader.place_sells();

    //     vm.warp(block.timestamp + 2 days);

    //     // Test with price above strike (simulate price rise)
    //     oracle.setPrice(105_000 ether);

    //     // Settle buy positions
    //     buys = doppiCore.getReadyBuyPositions();
    //     if (buys.length > 0) doppiCore.settle_buys(buys);

    //     // Settle sell positions
    //     sells = doppiCore.getReadySellPositions();
    //     if (sells.length > 0) doppiCore.settle_sells(sells);
    // }

    // function testOpportunity() public {
    //     // Place buys and sells
    //     oracle.setPrice(100_000 ether);
    //     doppiTrader.place_buys();
    //     doppiTrader.place_sells();
    //     bool upkeepNeeded;
    //     bytes memory data;

    //     oracle.setPrice(95_000 ether);

    //     (upkeepNeeded, data) = bot.checkUpkeep(bytes(""));
    //     while (upkeepNeeded) {
    //         bot.performUpkeep(data);
    //         (upkeepNeeded, data) = bot.checkUpkeep(bytes(""));
    //     }

    //     oracle.setPrice(105_000 ether);

    //     (upkeepNeeded, data) = bot.checkUpkeep(bytes(""));
    //     while (upkeepNeeded) {
    //         bot.performUpkeep(data);
    //         (upkeepNeeded, data) = bot.checkUpkeep(bytes(""));
    //     }

    //     oracle.setPrice(95_000 ether);

    //     (upkeepNeeded, data) = bot.checkUpkeep(bytes(""));
    //     while (upkeepNeeded) {
    //         bot.performUpkeep(data);
    //         (upkeepNeeded, data) = bot.checkUpkeep(bytes(""));
    //     }

    //     console.log(bot.profitAssetB(), bot.profitAssetA());
    // }
}
