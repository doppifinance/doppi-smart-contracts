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
    function setOpportunityBuy(uint256 strikePrice, uint256 amount, uint256 swappedAmount, uint256 outAmount) external;
    function setOpportunitySell(uint256 strikePrice, uint256 amount, uint256 swappedAmount, uint256 outAmount) external;
    function addOpportunityBuyAmount(uint256 strikePrice, uint256 amount) external;
    function addOpportunitySellAmount(uint256 strikePrice, uint256 amount) external;
    function subtractOpportunityBuy(uint256 strikePrice, uint256 subtractSwapped, uint256 subtractOut) external;
    function subtractOpportunitySell(uint256 strikePrice, uint256 subtractSwapped, uint256 subtractOut) external;
}

