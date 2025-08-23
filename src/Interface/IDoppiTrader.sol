// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDoppiLiquidity} from "./IDoppiLiquidity.sol";

interface IDoppiTrader {
    struct Trade {
        uint256 amount;
        uint256 originalAmount;
        uint256 originalStrikePrice;
    }

    function pauseTrades(bool pause) external;
    function createUnwindPosition(uint256 _amount, uint256 _strikePrice, bool _isBuyUndo) external;
    function get_buy_undos() external view returns (Trade[] memory);
    function get_sell_undos() external view returns (Trade[] memory);
    function get_buy_unrealized_PNL() external view returns (int256);
    function get_sell_unrealized_PNL() external view returns (int256);
}
