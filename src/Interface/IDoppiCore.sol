// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "../mainnet/DoppiCoreTypes.sol";

interface IDoppiCore {
    
    function getBuyPositionCount(address _owner) external view returns (uint256);
    function getSellPositionCount(address _owner) external view returns (uint256);
    function bulkDeposit(bool isBuy, DepositParams[] calldata params, DualAssetOffer[] memory _offers) external;
    function get_positions_buy(address _owner) external view returns (DualAssetPosition[] memory);
    function get_positions_sell(address _owner) external view returns (DualAssetPosition[] memory);
    function paused() external view returns (bool);
    function isEmergency() external view returns (bool);
    function emergencyWithdraw() external;
    function getCurrentDeposits(bool isBuy) external view returns (uint256);
    function getInterestLiabilities() external view returns (uint256, uint256);
    function acceptedDeposit(bool isBuy) external view returns (uint256 acceptedAmount);
    function getMinOrder() external view returns (uint256, uint256);
    function getDoppiOffer() external view returns (address);
    function canAcceptDeposit(bool isBuy, uint256 depositAmount) external view returns (bool);
    function getSupportDays() external view returns (uint8[] memory);
}
