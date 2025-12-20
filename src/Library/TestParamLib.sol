// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "../../src/mainnet/DoppiLiquidityTypes.sol";

library TestParamLib {
    
    function get_configLP() external pure returns (ConfigParam memory configLP) {

		address CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
		address PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
		address PCSWAP_V3_QUOTER = address(0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997);
		address PCSWAP_V3Pool = address(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);

		configLP = ConfigParam({
			chainLinkFeed : CHAINLINK_BTC_USD,
			router : PCSWAP_V3_ROUTER,
			quoter: PCSWAP_V3_QUOTER,
			poolFee: 500,  
			slippage: 100,
			liquidityFee: 1000,
			swapMargin: 5000,
			priceDecimals: 8,
			decimals: 10 ** 8,
			v3Pool: PCSWAP_V3Pool,
			twapDuration: 3600,
			maxDepositPercentage: 20000,
			maxDelay: 2 minutes,
			maxSwap: 500000 ether
		});
		
        return configLP;
    }

}
