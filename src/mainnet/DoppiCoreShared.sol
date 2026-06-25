// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDoppiOffer} from "../Interface/IDoppiOffer.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import "./DoppiCore.sol";

/// @notice Shared core implementation with local opportunity storage only.
contract DoppiCoreShared is DoppiCore {
    constructor(address _assetA, address _assetB, IDoppiLiquidity _doppiLP, IDoppiOffer _doppiOffer, address _doppiPoints)
        DoppiCore(_assetA, _assetB, _doppiLP, _doppiOffer, _doppiPoints)
    {}

    function _getOpportunityOrdersInternal(bool isBuy, uint256 strikePrice)
        internal
        view
        override
        returns (OpportunityOrders memory)
    {
        return isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
    }

    function _setOpportunityOrders(
        uint256 strikePrice,
        uint256 amount,
        uint256 swappedAmount,
        uint256 outAmount,
        bool isBuy
    ) internal override {
        OpportunityOrders storage opp = isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
        opp.amount = amount;
        opp.swappedAmount = swappedAmount;
        opp.outAmount = outAmount;
    }

    function _addOpportunityAmount(uint256 strikePrice, uint256 amount, bool isBuy) internal override {
        OpportunityOrders storage opp = isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
        opp.amount += amount;
    }

    function _subtractOpportunityTrade(
        uint256 strikePrice,
        uint256 subtractSwapped,
        uint256 subtractOut,
        bool isBuy
    ) internal override {
        OpportunityOrders storage opp = isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
        opp.swappedAmount = opp.swappedAmount > subtractSwapped ? opp.swappedAmount - subtractSwapped : 0;
        opp.outAmount = opp.outAmount > subtractOut ? opp.outAmount - subtractOut : 0;
    }
}
