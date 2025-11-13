// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "../mainnet/DoppiCoreTypes.sol";

interface IDoppiCore {
    
    function getBuyPositionCount(address _owner) external view returns (uint256);
    function getSellPositionCount(address _owner) external view returns (uint256);
    function bulkHedge(uint256 _amountInHedgeAsset, uint256 _price, bool isBuy) external returns (uint256 swappedHedgeAmount, uint256 hedgePrice);
    function bulkDeposit(bool isBuy, DepositParams[] calldata params, DualAssetOffer[] memory _offers, bool _hedge) external;
    function get_positions_buy(address _owner) external view returns (DualAssetPosition[] memory);
    function get_positions_sell(address _owner) external view returns (DualAssetPosition[] memory);
    function paused() external view returns (bool);
    function isEmergency() external view returns (bool);
    function emergencyWithdraw() external;
    function getCurrentDeposits(bool isBuy) external view returns (uint256);
}
