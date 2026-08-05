// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DALiquidityLib} from "../../src/Library/DALiquidityLib.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {DoppiLiquidity} from "../../src/mainnet/DoppiLiquidity.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "../../src/Interface/AggregatorV3Interface.sol";
import {TestParamLib} from "../../src/Library/TestParamLib.sol";
import "../../src/mainnet/DoppiLiquidityTypes.sol";

contract LivePriceTest is Test {
    IERC20 usdt;
    IERC20 btc;
    DoppiLiquidity doppiLP;
    ConfigParam configLP;
    
    // Mainnet addresses for forking
    address constant CAKE = address(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
    address constant BTCB = address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    address constant CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
    address constant PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    address constant PCSWAP_V3Pool = address(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);
    address constant PCSWAP_V3_QUOTER = address(0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997);
    
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    
    function setUp() public {
        
        // Fork Mainnet at a specific block
        uint256 mainnetFork = vm.createFork("mainnet", 60905002); // Do not change the block number for the unit test
        vm.selectFork(mainnetFork);
        
        // Start prank as owner
        vm.startPrank(owner);
        
        usdt = IERC20(USDT);
        btc = IERC20(BTCB);
        
        doppiLP = _setupLP(address(usdt), address(btc));
        
        vm.stopPrank();
    }

    function testPriceFeed() public view {
        uint256 price = doppiLP.getPrice();
        console.log("BTC Price from Chainlink:", price);
        assertGt(price, 0);
    }

    function test_getPriceFallbackTwap() public view {

        uint32 twapDuration = 3600;
        uint256 pricePCS = DALiquidityLib.getTWAPPrice(PCSWAP_V3Pool, twapDuration);
        // console.log(pricePCS, "price from twapPrice");
        uint256 priceFromLP = DALiquidityLib.getPriceWithFallback(AggregatorV3Interface(CHAINLINK_BTC_USD), PCSWAP_V3Pool, 3600, 0);
        // console.log(pricePCS, priceFromLP);
        assertEq(pricePCS, priceFromLP);
        uint256 lowerBound = priceFromLP * 9950 / 10000; // -0.50%
        uint256 upperBound = priceFromLP * 10050 / 10000; // +0.50%
        assertGe(pricePCS, lowerBound, "Price below -0.50% tolerance");
        assertLe(pricePCS, upperBound, "Price above +0.50% tolerance");
    }

     function test_getOtherTokens() public {

        uint32 twapDuration = 3600;
        address cakeusdt = address(0x7f51c8AaA6B0599aBd16674e2b17FEc7a9f674A1);
        address chainlinkcakeusdt = address(0xB6064eD41d4f67e353768aA239cA86f4F73665a1);

        vm.startPrank(owner);
        DoppiLiquidity doppiLPCakeUSDT =
            new DoppiLiquidity("Doppi CAKE-USDT LP", "CAKE-USDT", address(usdt), address(CAKE));
        configLP = TestParamLib.get_configLP();
        configLP.chainLinkFeed = chainlinkcakeusdt;
        configLP.v3Pool = cakeusdt;
        doppiLPCakeUSDT.setConfig(configLP);

        vm.stopPrank();


        uint256 pricePCS = DALiquidityLib.getTWAPPrice(cakeusdt, twapDuration);
        // console.log(pricePCS, "pricePCS");

        uint256 priceFromLP = doppiLPCakeUSDT.getPrice();
        // console.log("CAKE Price from priceFromLP (chainlink):", priceFromLP);

        // Calculate allowed range
        uint256 lowerBound = priceFromLP * 9950 / 10000; // -0.50%
        uint256 upperBound = priceFromLP * 10050 / 10000; // +0.50%
        assertGe(pricePCS, lowerBound, "Price below -0.50% tolerance");
        assertLe(pricePCS, upperBound, "Price above +0.50% tolerance");

    }

    

    function _setupLP(address _assetA, address _assetB) internal returns (DoppiLiquidity _doppiLP) {
        _doppiLP =
            new DoppiLiquidity("Doppi BTC-USDT LP", "BTCB-USDT", address(IERC20(_assetA)), address(IERC20(_assetB)));
        configLP = TestParamLib.get_configLP();
        _doppiLP.setConfig(configLP);
    }
}
