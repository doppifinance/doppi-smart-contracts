// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISwapper {
    function swap(uint256 _amountIn, uint256 _price, bool _isBuy) external returns (uint256);
    function getPrice() external view returns (uint256 rate);
}
