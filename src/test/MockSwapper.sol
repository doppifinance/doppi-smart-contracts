// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Interface/ISwapper.sol";
import "../Interface/ISwapRouter.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import "./MockToken.sol";
import "./MockOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "forge-std/console.sol";

// Simple Swapper Contract that also mocks Uniswap V3 Router, Pool, and QuoterV2 functionality
contract MockSwapper is ISwapper, ISwapRouter, IQuoterV2 {
    using SafeERC20 for ERC20;
    using SafeCast for int256;
    using Math for uint256;

    uint256 private constant BPS = 10000;

    ERC20 public USDT;
    ERC20 public BTC;
    MockOracle public oracle;
    uint256 public exactInputOutputBps = BPS;
    uint256 public exactOutputInputBps = BPS;

    constructor(address _usdt, address _btc) {
        USDT = ERC20(_usdt);
        BTC = ERC20(_btc);
    }

    function setExactInputOutputBps(uint256 _exactInputOutputBps) external {
        require(_exactInputOutputBps > 0, "invalid output bps");
        exactInputOutputBps = _exactInputOutputBps;
    }

    function setExactOutputInputBps(uint256 _exactOutputInputBps) external {
        require(_exactOutputInputBps > 0, "invalid input bps");
        exactOutputInputBps = _exactOutputInputBps;
    }

    function setOracle(MockOracle _oracle) external {
        oracle = _oracle;
    }

    function getPrice() external view returns (uint256 rate) {
        require(address(oracle) != address(0), "oracle not set");
        uint256 chainlinkDecimals = 10 ** oracle.decimals();
        (, int256 price,,,) = oracle.latestRoundData();
        return price.toUint256() / chainlinkDecimals;
    }

    function swap(uint256 _amountIn, uint256 _price, bool _isBuy) external returns (uint256) {
        if (_isBuy) {
            USDT.safeTransferFrom(msg.sender, address(this), _amountIn);
            uint256 amountOut = _amountIn / _price;
            ERC20(address(BTC)).transfer(msg.sender, amountOut);
            return amountOut;
        } else {
            BTC.safeTransferFrom(msg.sender, address(this), _amountIn);
            uint256 amountOut = _amountIn * _price;
            ERC20(address(USDT)).transfer(msg.sender, amountOut);
            return amountOut;
        }
    }

    function swapWithFee(uint256 _amountIn, uint256 _price, bool _isBuy, uint32 _fee) external returns (uint256) {
        if (_isBuy) {
            USDT.safeTransferFrom(msg.sender, address(this), _amountIn);
            uint256 amountOut = _amountIn / _price;
            amountOut -= amountOut.mulDiv(_fee, 1000000);

            ERC20(address(BTC)).transfer(msg.sender, amountOut);
            return amountOut;
        } else {
            BTC.safeTransferFrom(msg.sender, address(this), _amountIn);
            uint256 amountOut = _amountIn * _price;
            amountOut -= amountOut.mulDiv(_fee, 1000000);

            ERC20(address(USDT)).transfer(msg.sender, amountOut);
            return amountOut;
        }
    }

    // Mock Uniswap V3 Router Functions
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        // Simple mock implementation
        ERC20 tokenIn = ERC20(params.tokenIn);
        ERC20 tokenOut = ERC20(params.tokenOut);

        // Transfer tokens from caller
        tokenIn.safeTransferFrom(msg.sender, address(this), params.amountIn);

        amountOut = params.amountOutMinimum.mulDiv(exactInputOutputBps, BPS);
        require(amountOut >= params.amountOutMinimum, "insufficient output amount");
        tokenOut.safeTransfer(params.recipient, amountOut);

        return amountOut;
    }

    function exactInput(ExactInputParams calldata) external payable override returns (uint256) {
        revert("Not implemented");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable override returns (uint256 amountIn) {
        // revert("Not implemented");
        // console.log("exactOutputSingle");
        ERC20 tokenIn = ERC20(params.tokenIn);
        ERC20 tokenOut = ERC20(params.tokenOut);

        // Transfer tokens from caller
        amountIn = params.amountInMaximum.mulDiv(exactOutputInputBps, BPS);
        require(amountIn <= params.amountInMaximum, "excessive input amount");
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenOut.safeTransfer(params.recipient, params.amountOut);
        return amountIn;
    }

    function exactOutput(ExactOutputParams calldata) external payable override returns (uint256) {
        revert("Not implemented");
    }

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external pure override {
        revert("Not implemented");
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        view
        override
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        amountOut = params.amountIn.mulDiv(exactInputOutputBps, BPS);
        sqrtPriceX96After = 79228162514264337593543950336;
        initializedTicksCrossed = 0;
        gasEstimate = 150000;
    }

    function quoteExactInput(bytes memory, uint256)
        external
        pure
        override
        returns (uint256, uint160[] memory, uint32[] memory, uint256)
    {
        revert("Not implemented");
    }

    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        view
        override
        returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        amountIn = params.amount.mulDiv(exactOutputInputBps, BPS);
        sqrtPriceX96After = 79228162514264337593543950336;
        initializedTicksCrossed = 0;
        gasEstimate = 150000;
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
