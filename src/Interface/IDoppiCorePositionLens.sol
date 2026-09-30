// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../mainnet/DoppiCoreTypes.sol";

interface IDoppiCorePositionLens {
    function getPositionsBuy(address owner) external view returns (DualAssetPosition[] memory);
    function getPositionsSell(address owner) external view returns (DualAssetPosition[] memory);
}