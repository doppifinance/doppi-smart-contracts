// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShares} from "../Interface/IShares.sol";

interface IDoppiLiquidity is IShares {
    function assetA() external view returns (IERC20);
    function assetB() external view returns (IERC20);
    function doppiCore() external view returns (address);
    function amountToBuy(uint256 price) external view returns (uint256);
    function amountToSell(uint256 price) external view returns (uint256);
    function swap(uint256 _amountIn, uint256 _price, bool _isBuy) external returns (uint256 amountOut) ;
    function settle(uint256 _amountIn, uint256 _payout, uint256 _price, bool _isBuy) external returns (uint256);
    function getPrice() external view returns (uint256);
    function getPriceDecimals() external view returns (uint8);
    function assetRatio() external view returns (uint256 ratioA, uint256 ratioB);
    function totalAssetsInAssetA() external view returns (uint256);
    function totalAssetsInAssetB() external view returns (uint256);
    function getMaxDepositAmount(bool isBuy) external view returns (uint256);
    function interestGet(
        address _interestToken,
        uint256 interest,
        uint256 price,
        bool isBuy
    ) external;
}
