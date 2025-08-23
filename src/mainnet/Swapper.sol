// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Interface/ISwapper.sol";
import "../Interface/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Simple Swapper Contract
contract Swapper is ISwapper {
    using SafeCast for int256;
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 public USDT;
    IERC20 public BTC;
    address public router = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    uint24 public poolFee = 500;
    uint24 public slippage = 100;
    AggregatorV3Interface public constant chainLinkFeed =
        AggregatorV3Interface(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);

    constructor(IERC20 _usdt, IERC20 _btc) {
        USDT = _usdt;
        BTC = _btc;
    }

    function swap(uint256 _amountIn, uint256 _price, bool _isBuy) external returns (uint256) {
        if (_isBuy) {
            USDT.safeTransferFrom(msg.sender, address(this), _amountIn);
            return _swapV3(_amountIn, address(USDT), address(BTC), msg.sender, _amountIn / _price);
        } else {
            BTC.safeTransferFrom(msg.sender, address(this), _amountIn);
            return _swapV3(_amountIn, address(BTC), address(USDT), msg.sender, _amountIn * _price);
        }
    }

    function _swapV3(uint256 _amount, address _fromToken, address _toToken, address _recipient, uint256 amountOutQuote)
        internal
        returns (uint256)
    {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _fromToken,
            tokenOut: _toToken,
            fee: poolFee,
            recipient: _recipient,
            amountIn: _amount,
            amountOutMinimum: amountOutQuote.mulDiv(10000 - slippage, 10000),
            sqrtPriceLimitX96: 0
        });
        TransferHelper.safeApprove(_fromToken, router, _amount);
        return ISwapRouter(router).exactInputSingle(params);
    }

    function getPrice() public view returns (uint256 rate) {
        uint256 chainlinkDecimals = 10 ** chainLinkFeed.decimals();
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint256 updatedAt*/ /*uint80 answeredInRound*/
            ,
            ,
        ) = chainLinkFeed.latestRoundData();
        rate = price.toUint256() / chainlinkDecimals;

        return rate;
    }
}
