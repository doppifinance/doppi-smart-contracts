// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShares} from "../Interface/IShares.sol";

interface IDoppiLiquidity is IShares {
    function assetA() external view returns (IERC20);
    function assetB() external view returns (IERC20);
    function doppiCore() external view returns (address);
    function treasury() external view returns (address);
    function router() external view returns (address);
    function pancakeV3Pool() external view returns (address);
    function twapDuration() external view returns (uint32);
    function poolFee() external view returns (uint24);
    function slippage() external view returns (uint24);
    function liquidityFee() external view returns (uint24);
    function swapMargin() external view returns (uint32);

    function amountToBuy(uint256 price) external view returns (uint256);
    function amountToSell(uint256 price) external view returns (uint256);
    function toBuyPrices(uint256 index) external view returns (uint256);
    function toSellPrices(uint256 index) external view returns (uint256);
    function hedgeSwap(uint256 _amountIn, uint256 _price, bool _isBuy) external returns (uint256);

    function swap(uint256 _amountIn, uint256 _price, bool _isBuy) external returns (uint256 amountOut) ;
    function settle(uint256 _amountIn, uint256 _price, bool _isBuy) external returns (uint256 amountOut);
    
    function transfer(IERC20 token, uint256 amount, address recipient) external;

    function unwindSwapOrder(uint256 _index, bool _isBuy) external;

    function getPrice() external view returns (uint256);
    function getPriceDecimals() external view returns (uint8);
    function getBalanceAssetA() external view returns (uint256);
    function getBalanceAssetB() external view returns (uint256);

    function totalAssetsInAssetA() external view returns (uint256);
    function totalAssetsInAssetB() external view returns (uint256);
}
