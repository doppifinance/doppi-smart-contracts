// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../mainnet/DoppiCoreTypes.sol";

/**
 * @notice Interface for external opportunity storage (used by private cores)
 * Separate from the existing DoppiOpportunity bot contract.
 */
interface IDoppiOpportunity {
    function initialize(address _doppiCore) external;
    function getBuyOpportunity(uint256 strikePrice) external view returns (OpportunityOrders memory);
    function getSellOpportunity(uint256 strikePrice) external view returns (OpportunityOrders memory);
    function getOpportunityOrders(bool isBuy, uint256 strikePrice) external view returns (OpportunityOrders memory);
    function getActiveStrikeSnapshot(bool isBuy) external view returns (uint256 activeCount, uint256 head, uint256 tail);
    function getStrikeNode(bool isBuy, uint256 strikePrice) external view returns (uint256 prev, uint256 next, bool active);
    function getLowerUpperBound() external view returns (uint256 lower, uint256 upper);
    function syncStrikeState(uint256 strikePrice, bool isBuy) external;
    function reduceOpportunityOrder(bool isBuy, uint256 strikePrice, uint256 amount) external;
    function setOpportunityBuy(uint256 strikePrice, uint256 amount, uint256 swappedAmount, uint256 outAmount) external;
    function setOpportunitySell(uint256 strikePrice, uint256 amount, uint256 swappedAmount, uint256 outAmount) external;
    function addOpportunityBuyAmount(uint256 strikePrice, uint256 amount) external;
    function addOpportunitySellAmount(uint256 strikePrice, uint256 amount) external;
    function subtractOpportunityBuy(uint256 strikePrice, uint256 subtractSwapped, uint256 subtractOut) external;
    function subtractOpportunitySell(uint256 strikePrice, uint256 subtractSwapped, uint256 subtractOut) external;
}

