// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "../../src/mainnet/DoppiLiquidityTypes.sol";

library TestParamLib {
    
    function get_configLP() external pure returns (ConfigParam memory configLP) {

		address CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
		address PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
		address PCSWAP_V3Pool = address(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);

		configLP = ConfigParam({
			chainLinkFeed : CHAINLINK_BTC_USD,
			router : PCSWAP_V3_ROUTER,
			poolFee: 500,  
			slippage: 100,
			liquidityFee: 1000,
			priceDecimals: 8,
			decimals: 10 ** 8,
			v3Pool: PCSWAP_V3Pool,
			twapDuration: 3600,
			maxDepositPercentage: 20000,
			maxDelay: 2 minutes,
			maxSwap: 100000 ether,
			priceGap: 500,
			unwindGapMultiplier: 1
		});
		
        return configLP;
    }

	function get_configLP_localhost() external pure returns (ConfigParam memory configLP) {

		address CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
		address PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
		address PCSWAP_V3Pool = address(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);

		configLP = ConfigParam({
			chainLinkFeed : CHAINLINK_BTC_USD,
			router : PCSWAP_V3_ROUTER,
			poolFee: 500,  
			slippage: 50,
			liquidityFee: 1000,
			priceDecimals: 8,
			decimals: 10 ** 8,
			v3Pool: PCSWAP_V3Pool,
			twapDuration: 3600,
			maxDepositPercentage: 10000,
			maxDelay: 2 minutes,
			maxSwap: 20000 ether,
			priceGap: 500,
			unwindGapMultiplier: 2
		});
		
        return configLP;
    }


	function get_configLP_ETH() external pure returns (ConfigParam memory configLP) {

		address CHAINLINK_ETH_USD = address(0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e);
		address PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
		address PCSWAP_V3Pool = address(0xBe141893E4c6AD9272e8C04BAB7E6a10604501a5);

		configLP = ConfigParam({
			chainLinkFeed : CHAINLINK_ETH_USD,
			router : PCSWAP_V3_ROUTER,
			poolFee: 500,  // fee for PCSWAP_V3Pool 0.05%
			slippage: 50, // 1.00% swap slippage
			liquidityFee: 0, // 0.15% to the LP pool for internal swap
			priceDecimals: 8,
			decimals: 10 ** 8,
			v3Pool: PCSWAP_V3Pool,
			twapDuration: 3600,
			maxDepositPercentage: 10000, // 2x
			maxDelay: 1 minutes,
			maxSwap: 10000 ether, // maxswap per once for unwinding 
			priceGap: 25,
			unwindGapMultiplier: 2
		});
		
        return configLP;
    }

	function get_configLPMainnet() external pure returns (ConfigParam memory configLP) {

		address CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
		address PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
		address PCSWAP_V3Pool = address(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);

		configLP = ConfigParam({
			chainLinkFeed : CHAINLINK_BTC_USD,
			router : PCSWAP_V3_ROUTER,
			poolFee: 500,  // fee for PCSWAP_V3Pool 0.05%
			slippage: 50, // 0.50% swap slippage
			liquidityFee: 500, // 0.05% to the LP pool for internal swap
			priceDecimals: 8,
			decimals: 10 ** 8,
			v3Pool: PCSWAP_V3Pool,
			twapDuration: 3600,
			maxDepositPercentage: 10000, // 1x
			maxDelay: 1 minutes,
			maxSwap: 25000 ether, // maxswap per once for unwinding 
			priceGap: 500,
			unwindGapMultiplier: 2
		});
		
        return configLP;
    }

	function get_configLPMainnet_ETH() external pure returns (ConfigParam memory configLP) {

		address CHAINLINK_ETH_USD = address(0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e);
		address PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
		address PCSWAP_V3Pool = address(0xBe141893E4c6AD9272e8C04BAB7E6a10604501a5);

		configLP = ConfigParam({
			chainLinkFeed : CHAINLINK_ETH_USD,
			router : PCSWAP_V3_ROUTER,
			poolFee: 500,  // fee for PCSWAP_V3Pool 0.05%
			slippage: 100, // 1.00% swap slippage
			liquidityFee: 500, // 0.10% to the LP pool for internal swap
			priceDecimals: 8,
			decimals: 10 ** 8,
			v3Pool: PCSWAP_V3Pool,
			twapDuration: 3600,
			maxDepositPercentage: 15000, // 2x
			maxDelay: 1 minutes,
			maxSwap: 20000 ether, // maxswap per once for unwinding 
			priceGap: 25,
			unwindGapMultiplier: 2
		});
		
        return configLP;
    }

}
