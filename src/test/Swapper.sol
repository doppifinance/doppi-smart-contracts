// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Interface/ISwapper.sol";
import "../Interface/ISwapRouter.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import "./MockToken.sol";
import "./MockOracle.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Simple Swapper Contract that also mocks Uniswap V3 Router, Pool, and QuoterV2 functionality
contract Swapper is ISwapper, ISwapRouter, IQuoterV2 {
    using SafeERC20 for MockToken;
    using SafeCast for int256;
    using Math for uint256;

    MockToken public USDT;
    MockToken public BTC;
    MockOracle public oracle;

    constructor(MockToken _usdt, MockToken _btc) {
        USDT = _usdt;
        BTC = _btc;
    }

    function swap(uint256 _amountIn, uint256 _price, bool _isBuy) external returns (uint256) {
        if (_isBuy) {
            USDT.safeTransferFrom(msg.sender, address(this), _amountIn);
            uint256 amountOut = _amountIn / _price;
            BTC.mint(msg.sender, amountOut);
            USDT.burn(address(this), _amountIn);
            return amountOut;
        } else {
            BTC.safeTransferFrom(msg.sender, address(this), _amountIn);
            uint256 amountOut = _amountIn * _price;
            USDT.mint(msg.sender, amountOut);
            BTC.burn(address(this), _amountIn);
            return amountOut;
        }
    }

    function swapWithFee(uint256 _amountIn, uint256 _price, bool _isBuy, uint32 _fee) external returns (uint256) {
        if (_isBuy) {
            USDT.safeTransferFrom(msg.sender, address(this), _amountIn);
            uint256 amountOut = _amountIn / _price;
            amountOut -= amountOut.mulDiv(_fee, 1000000);

            BTC.mint(msg.sender, amountOut);
            USDT.burn(address(this), _amountIn);
            return amountOut;
        } else {
            BTC.safeTransferFrom(msg.sender, address(this), _amountIn);
            uint256 amountOut = _amountIn * _price;
            amountOut -= amountOut.mulDiv(_fee, 1000000);

            USDT.mint(msg.sender, amountOut);
            BTC.burn(address(this), _amountIn);
            return amountOut;
        }
    }

    function setOracle(MockOracle _oracle) public {
        oracle = _oracle;
    }

    function getPrice() public view returns (uint256 rate) {
        uint256 chainlinkDecimals = 10 ** oracle.decimals();
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint256 updatedAt*/ /*uint80 answeredInRound*/
            ,
            ,
        ) = oracle.latestRoundData();
        rate = price.toUint256() / chainlinkDecimals;

        return rate;
    }

    // Mock Uniswap V3 Router Functions
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        // Simple mock implementation
        MockToken tokenIn = MockToken(params.tokenIn);
        MockToken tokenOut = MockToken(params.tokenOut);

        // Transfer tokens from caller
        tokenIn.safeTransferFrom(msg.sender, address(this), params.amountIn);

        // Simple conversion based on oracle price if available, otherwise 1:1
        if (address(oracle) != address(0)) {
            (, int256 price,,,) = oracle.latestRoundData();
            uint256 priceUint = price.toUint256();

            if (params.tokenIn == address(USDT) && params.tokenOut == address(BTC)) {
                // USDT to BTC: divide by price
                amountOut = params.amountIn.mulDiv(10 ** oracle.decimals(), priceUint);
            } else if (params.tokenIn == address(BTC) && params.tokenOut == address(USDT)) {
                // BTC to USDT: multiply by price
                amountOut = params.amountIn.mulDiv(priceUint, 10 ** oracle.decimals());
            } else {
                // Fallback 1:1
                amountOut = params.amountIn;
            }
        } else {
            // No oracle, 1:1 conversion
            amountOut = params.amountIn;
        }

        // Apply minimum amount check
        require(amountOut >= params.amountOutMinimum, "Insufficient output amount");

        // Mint output tokens to recipient
        tokenOut.mint(params.recipient, amountOut);

        // Burn input tokens
        tokenIn.burn(address(this), params.amountIn);

        return amountOut;
    }

    function exactInput(ExactInputParams calldata) external payable override returns (uint256) {
        revert("Not implemented");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable override returns (uint256) {
        revert("Not implemented");
    }

    function exactOutput(ExactOutputParams calldata) external payable override returns (uint256) {
        revert("Not implemented");
    }

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external pure {
        // Empty implementation for interface compliance
    }

    // Mock Uniswap V3 Pool Functions
    function observe(uint32[] calldata secondsAgo)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory)
    {
        // Simple mock implementation that returns consistent tick data
        tickCumulatives = new int56[](secondsAgo.length);
        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgo.length);

        // Use oracle price to calculate tick if available
        if (address(oracle) != address(0)) {
            (, int256 price,,,) = oracle.latestRoundData();
            // Simple but valid tick calculation - keep it in reasonable range
            // Valid tick range is approximately -887272 to 887272
            int56 currentTick = int56(price / 1e8); // This should give us reasonable values
            // Clamp tick to valid range
            if (currentTick > 800000) currentTick = 800000;
            if (currentTick < -800000) currentTick = -800000;

            for (uint256 i = 0; i < secondsAgo.length; i++) {
                // Simple cumulative calculation - ensure result stays in valid range
                int56 timeFactor = int56(int256(secondsAgo.length > i ? secondsAgo.length - i : 1));
                tickCumulatives[i] = currentTick * timeFactor;
                secondsPerLiquidityCumulativeX128s[i] = 0; // Not used in tests
            }
        } else {
            // Fallback values when no oracle - use safe values
            for (uint256 i = 0; i < secondsAgo.length; i++) {
                tickCumulatives[i] = int56(1000 * int256(i + 1)); // Simple progressive values
                secondsPerLiquidityCumulativeX128s[i] = 0;
            }
        }

        return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
    }

    function token0() external view returns (address) {
        return address(USDT);
    }

    function token1() external view returns (address) {
        return address(BTC);
    }

    function fee() external pure returns (uint24) {
        return 500; // 0.05%
    }

    // IQuoterV2 implementation
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        view
        override
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        // Simple mock implementation using same logic as exactInputSingle
        if (address(oracle) != address(0)) {
            (, int256 price,,,) = oracle.latestRoundData();
            uint256 priceUint = price.toUint256();

            if (params.tokenIn == address(USDT) && params.tokenOut == address(BTC)) {
                // USDT to BTC: divide by price
                amountOut = params.amountIn.mulDiv(10 ** oracle.decimals(), priceUint);
            } else if (params.tokenIn == address(BTC) && params.tokenOut == address(USDT)) {
                // BTC to USDT: multiply by price
                amountOut = params.amountIn.mulDiv(priceUint, 10 ** oracle.decimals());
            } else {
                // Fallback 1:1
                amountOut = params.amountIn;
            }
        } else {
            // No oracle, 1:1 conversion
            amountOut = params.amountIn;
        }

        // Mock values for other return parameters
        sqrtPriceX96After = 79228162514264337593543950336; // sqrt(1) in Q96 format
        initializedTicksCrossed = 0;
        gasEstimate = 150000; // Typical gas estimate for a swap
    }

    function quoteExactInput(bytes memory, uint256)
        external
        pure
        override
        returns (uint256, uint160[] memory, uint32[] memory, uint256)
    {
        revert("Not implemented");
    }

    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory)
        external
        pure
        override
        returns (uint256, uint160, uint32, uint256)
    {
        revert("Not implemented");
    }

    function quoteExactOutput(bytes memory, uint256)
        external
        pure
        override
        returns (uint256, uint160[] memory, uint32[] memory, uint256)
    {
        revert("Not implemented");
    }
}
