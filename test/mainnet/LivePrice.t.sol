// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DALiquidityLib} from "../../src/Library/DALiquidityLib.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {DoppiLiquidity} from "../../src/mainnet/DoppiLiquidity.sol";
import {DoppiConfig} from "../../src/mainnet/DoppiConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LivePriceTest is Test {
    IERC20 usdt;
    IERC20 btc;
    DoppiLiquidity doppiLP;
    DoppiConfig doppiConfig;
    
    
    // Mainnet addresses for forking
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
        
        doppiConfig = new DoppiConfig();
        doppiConfig.setRouter(PCSWAP_V3_ROUTER);
        doppiConfig.setQuoter(PCSWAP_V3_QUOTER);
        doppiConfig.setPancakeV3Pool(PCSWAP_V3Pool); 
        doppiConfig.setOracle(CHAINLINK_BTC_USD);
        doppiConfig.setSlippage(500);

        doppiLP = _setupLP(address(usdt), address(btc));
        
        vm.stopPrank();
    }

    function testPriceFeed() public view {
        uint256 price = doppiLP.getPrice();
        console.log("BTC Price from Chainlink:", price);
        assertGt(price, 0);
    }

    function test_getPancakePrice() public view {

        uint32 twapDuration = 3600;
        IUniswapV3Pool pancakeV3Pool = IUniswapV3Pool(PCSWAP_V3Pool);
        uint256 price = DALiquidityLib.getPancakePrice(pancakeV3Pool, twapDuration);
        price = 1e26 / price;
        console.log(price, "price");
    }

    function _setupLP(address _assetA, address _assetB) internal returns (DoppiLiquidity _doppiLP) {
        _doppiLP =
            new DoppiLiquidity("Doppi BTC-USDT LP", "BTCB-USDT", IERC20(_assetA), IERC20(_assetB));
        _doppiLP.setDoppiConfig(doppiConfig); 
        // _doppiLP.approveRouter();
    }
}
