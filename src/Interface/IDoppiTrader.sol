// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDoppiLiquidity} from "./IDoppiLiquidity.sol";

interface IDoppiTrader {
    
    function validTrader() external view returns (address);
    function pauseTrades(bool pause) external;
    function createUnwindPosition(uint256 _amount, uint256 _strikePrice, bool _isBuyUndo) external;
    function get_unrealized_PNL() external view returns (int256);
    function setForwarderAddress(address forwarderAddress) external;
}
