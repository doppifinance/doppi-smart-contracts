// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IDoppiLiquidity} from "./IDoppiLiquidity.sol";
import {IERC7575} from "./IERC7575.sol";

interface IDoppiLiquidityRouter {
    function doppiLP() external view returns (IDoppiLiquidity);
    function entryPointA() external view returns (IERC7575);
    function entryPointB() external view returns (IERC7575);
    function assetA() external view returns (address);
    function assetB() external view returns (address);

    function deposit(address _asset, uint256 _amount) external returns (uint256 shares);
    function redeem(uint256 _shares) external returns (uint256 assetsA, uint256 assetsB);
    function paused() external view returns (bool);
    function emergencyWithdraw() external;
    function isEmergency() external returns (bool);
}
