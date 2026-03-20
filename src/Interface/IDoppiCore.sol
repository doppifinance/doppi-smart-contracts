// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "../mainnet/DoppiCoreTypes.sol";
import {IDoppiOffer} from "../Interface/IDoppiOffer.sol";

interface IDoppiCore {
    
    function getBuyPositionCount(address _owner) external view returns (uint256);
    function getSellPositionCount(address _owner) external view returns (uint256);
    function bulkDeposit(bool isBuy, DepositParams[] calldata params, DualAssetOffer[] memory _offers, uint256 total) external;
    function get_positions_buy(address _owner) external view returns (DualAssetPosition[] memory);
    function get_positions_sell(address _owner) external view returns (DualAssetPosition[] memory);
    function paused() external view returns (bool);
    function emergencyMode() external view returns (bool);
    function emergencyWithdraw() external;
    function getCurrentDeposits(bool isBuy) external view returns (uint256);
    function getInterestLiabilities() external view returns (uint256, uint256);
    function acceptedDeposit(bool isBuy) external view returns (uint256 acceptedAmount);
    function minOrderA() external view returns (uint256);
    function minOrderB() external view returns (uint256);
    function doppiOffer() external view returns (IDoppiOffer);
    function canAcceptDeposit(bool isBuy, uint256 depositAmount) external view returns (bool);
    function supportDays() external view returns (uint8[] memory); 
}
