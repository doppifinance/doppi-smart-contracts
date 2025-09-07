// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;

// import "forge-std/Test.sol";
// import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
// import {DoppiTrader} from "../src/mainnet/DoppiTrader.sol";
// import {DoppiOpportunity} from "../src/mainnet/DoppiOpportunity.sol";
// import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
// import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
// import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
// import {ImpliedVol} from "../src/mainnet/ImpliedVol.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {MockToken} from "../src/test/MockToken.sol";
// import {MockOracle} from "../src/test/MockOracle.sol";
// import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// contract MainnetForkTest is Test {
//     using Math for uint256;

//     IERC20 usdt = IERC20(0x55d398326f99059fF775485246999027B3197955);
//     IERC20 btc = IERC20(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
//     DoppiLiquidity doppiLP;
//     DoppiLiquidityRouter doppiRouter;
//     DoppiCore doppiCore;
//     DoppiTrader doppiTrader;
//     DoppiOpportunity bot;
//     BlackScholes blackScholes;
//     ImpliedVol impliedVol;

//     address user = address(0x1234);

//     function setUp() public {
//         int256 a_buy = 0.0000000807142857142833 * 1e27;
//         int256 b_buy = -0.019095857142856592 * 1e27;
//         int256 c_buy = 1159.8454285713972 * 1e27;

//         int256 a_sell = 0.000000102857142857143 * 1e27;
//         int256 b_sell = -0.02447200000000008 * 1e27;
//         int256 c_sell = 1485.8762857142906 * 1e27;

//         string memory BSC_RPC_URL = vm.envString("BSC_NODE");
//         uint256 mainnetFork = vm.createFork(BSC_RPC_URL);
//         vm.selectFork(mainnetFork);
//         uint24[] memory weights = new uint24[](5);
//         weights[0] = 500;
//         weights[1] = 1000;
//         weights[2] = 1500;
//         weights[3] = 2500;
//         weights[4] = 4500;

//         blackScholes = new BlackScholes();
//         impliedVol = new ImpliedVol(blackScholes);
//         impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);

//         // Deploy doppiLP with mock oracle
//         doppiLP =
//             new DoppiLiquidity("Dual Asset Liquidity Pool", "DALP", IERC20(usdt), IERC20(btc), address(2));

//         // Deploy doppiCore
//         doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);
//         doppiLP.setDoppiCore(address(doppiCore));

//         // Create router and set entry points
//         doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
//         doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
//         doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
//         doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
//         doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));

//         // Deploy Trader with router
//         doppiTrader = new DoppiTrader(
//             address(2),
//             IERC20(address(usdt)),
//             IERC20(address(btc)),
//             doppiLP,
//             doppiRouter,
//             doppiCore,
//             weights
//         );

//         // Deploy OpportunityBot
//         bot = new DoppiOpportunity(address(doppiCore), address(doppiLP));

//         // Set balance for USDT and BTC tokens
//         vm.prank(address(usdt));
//         IERC20(usdt).transfer(address(doppiTrader), 100_000 ether);
//         vm.prank(address(btc));
//         IERC20(btc).transfer(address(doppiTrader), 1 ether);
//         vm.prank(address(usdt));
//         IERC20(usdt).transfer(address(doppiCore), 100_000 ether);
//         vm.prank(address(btc));
//         IERC20(btc).transfer(address(doppiCore), 1 ether);
//     }

//     // function testPlaceBuysAndSells() public {
//     //     // Trader places buy positions
//     //     bool buysPlaced = doppiTrader.place_buys();
//     //     assertTrue(buysPlaced, "Buys should be placed");

//     //     // Trader places sell positions
//     //     bool sellsPlaced = doppiTrader.place_sells();
//     //     assertTrue(sellsPlaced, "Sells should be placed");

//     //     // Fast forward time by 2 days
//     //     vm.warp(block.timestamp + 2 days);

//     //     // Settle buy positions
//     //     uint256[] memory buys = doppiCore.getReadyBuyPositions();
//     //     if (buys.length > 0) doppiCore.settle_buys(buys);

//     //     // Settle sell positions
//     //     uint256[] memory sells = doppiCore.getReadySellPositions();
//     //     if (sells.length > 0) doppiCore.settle_sells(sells);
//     // }

//     function testdualAssetLiquidity() public {
//         vm.prank(address(usdt));
//         usdt.transfer(user, 100_000 ether);
//         vm.prank(address(btc));
//         btc.transfer(user, 1 ether);

//         uint256 usdtAmt = 100_000 ether;
//         vm.startPrank(user);
//         usdt.approve(address(doppiLP), usdtAmt);
//         doppiLP.swap(100_000 ether, doppiLP.getPrice(), true);
//         vm.stopPrank();
//         uint256 minAmount =
//             (usdtAmt / doppiLP.getPrice()).mulDiv(10000 - doppiLP.slippage(), 10000);
//         assert(btc.balanceOf(user) >= 1 ether + minAmount);
//         console.log(btc.balanceOf(user));
//     }
// }
