// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    IUniswapV3Pool
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../Library/TickMath.sol";
import "forge-std/console.sol";

library DALiquidityLib {
    using SafeCast for int256;

    error OUTOFBOUNDS();

    function getPriceWithFallback(
        AggregatorV3Interface chainLinkFeed,
        address _v3Pool,
        uint32 twapDuration,
        uint32 maxDelay
    ) public view returns (uint256 rate) {
        rate = getPrice(chainLinkFeed, maxDelay);
        // console.log(rate, maxDelay);
        if (rate == 0) {
            rate = getTWAPPrice(_v3Pool, twapDuration);
        }
        // console.log(rate, "twap");
    }

    function getPrice(
        AggregatorV3Interface chainLinkFeed,
        uint32 maxDelay
    ) public view returns (uint256 rate) {
        (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = chainLinkFeed.latestRoundData();
        // Comprehensive Chainlink validation
        if (price <= 0) return 0;
        if (updatedAt == 0) return 0;
        if (updatedAt < block.timestamp - maxDelay) return 0;
        if (answeredInRound < roundId) return 0;
        
        return uint256(price);
    }

    function getTWAPPrice(
        address _v3Pool,
        uint32 twapDuration
    ) public view returns (uint256 rate) {
        IUniswapV3Pool v3Pool = IUniswapV3Pool(_v3Pool);
        (uint256 twapPrice, uint8 priceDecimals) = getPancakePrice(
            v3Pool,
            twapDuration
        );
        if (twapPrice == 0) revert("no twap price");

        if (priceDecimals > 8) {
            twapPrice /= 10 ** (priceDecimals - 8);
        } else {
            twapPrice *= 10 ** (8 - priceDecimals);
        }
        return twapPrice;
    }

    function getPriceDecimals(
        AggregatorV3Interface chainLinkFeed
    ) public view returns (uint8 decimals) {
        return chainLinkFeed.decimals();
    }

    function getPancakePrice(
        IUniswapV3Pool pancakeV3Pool,
        uint32 twapDuration
    ) public view returns (uint256 rate, uint8 priceDecimal) {
        address usdt = address(0x55d398326f99059fF775485246999027B3197955);
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = twapDuration;
        secondsAgo[1] = 0;
        (int56[] memory tickCumulatives, ) = pancakeV3Pool.observe(secondsAgo);
        uint256 first = pancakeV3Pool.token0() == usdt ? 0 : 1;
        uint256 second = first == 1 ? 0 : 1;
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(
            int24(
                (tickCumulatives[first] - tickCumulatives[second]) /
                    int32(twapDuration)
            )
        );

        if (pancakeV3Pool.token0() == usdt) {
            priceDecimal = ERC20(pancakeV3Pool.token0()).decimals();
        } else {
            priceDecimal = ERC20(pancakeV3Pool.token1()).decimals();
        }
        rate = sqrtPriceX96ToUint(sqrtPriceX96, priceDecimal);
    }

    function sqrtPriceX96ToUint(
        uint160 sqrtPriceX96,
        uint8 decimalsToken0
    ) internal pure returns (uint256) {
        uint256 numerator1 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 numerator2 = 10 ** decimalsToken0;
        return Math.mulDiv(numerator1, numerator2, 1 << 192);
    }

    function sortedInsert(
        uint256[] storage a,
        uint256 index,
        uint256 value
    ) public {
        if (index > a.length) revert OUTOFBOUNDS();
        a.push();
        // Only shift if not inserting at the end
        if (index < a.length - 1) {
            for (uint256 i = a.length - 1; i > index; ) {
                a[i] = a[i - 1];
                unchecked {
                    i--;
                }
            }
        }
        a[index] = value;
    }

    function sortedRemove(uint256[] storage a, uint256 index) public {
        if (index >= a.length) revert OUTOFBOUNDS();
        for (uint256 i = index; i < a.length - 1; ) {
            a[i] = a[i + 1];
            unchecked {
                i++;
            }
        }
        a.pop();
    }

    function find(
        uint256[] memory a,
        uint256 value
    ) public pure returns (bool, uint256) {
        uint256 left = 0;
        uint256 right = a.length;
        while (left < right) {
            uint256 mid = (left & right) + ((left ^ right) >> 1);
            uint256 midVal = a[mid];
            if (midVal == value) {
                return (true, mid);
            }
            if (midVal < value) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return (false, 0);
    }

    function sumArray(uint24[] calldata arr) public pure returns (uint24) {
        uint24 i;
        uint24 sum = 0;

        for (i = 0; i < arr.length; i++) sum = sum + arr[i];
        return sum;
    }

    function netoutBuySell(
        uint256 _totalSellB,
        uint256 _totalSellOut,
        uint256 _totalBuyA,
        uint256 _totalBuyAOut
    ) public pure returns (bool isNetBuy, uint256 netSellOrBuy) {
        if (_totalSellB > _totalBuyAOut) {
            isNetBuy = false;
            netSellOrBuy = _totalSellB - _totalBuyAOut;
        } else {
            isNetBuy = true;
            netSellOrBuy = _totalBuyA - _totalSellOut;
        }
    }
}
