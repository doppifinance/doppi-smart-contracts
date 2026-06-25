// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDoppiOffer} from "../../Interface/IDoppiOffer.sol";
import {IDoppiLiquidity} from "../../Interface/IDoppiLiquidity.sol";
import "../DoppiCore.sol";

/// @notice Private core implementation using external opportunity storage only.
contract DoppiCorePrivate is DoppiCore {
    constructor(address _assetA, address _assetB, IDoppiLiquidity _doppiLP, IDoppiOffer _doppiOffer, address _doppiPoints)
        DoppiCore(_assetA, _assetB, _doppiLP, _doppiOffer, _doppiPoints)
    {}

    function _getOpportunityOrdersInternal(bool isBuy, uint256 strikePrice)
        internal
        view
        override
        returns (OpportunityOrders memory)
    {
        if (address(doppiOpportunity) == address(0)) revert NotExist();
        return _opportunityGetOrdersLowLevel(isBuy, strikePrice);
    }

    function _setOpportunityOrders(
        uint256 strikePrice,
        uint256 amount,
        uint256 swappedAmount,
        uint256 outAmount,
        bool isBuy
    ) internal override {
        if (address(doppiOpportunity) == address(0)) revert NotExist();
        _opportunitySetOrdersLowLevel(strikePrice, amount, swappedAmount, outAmount, isBuy);
    }

    function _addOpportunityAmount(uint256 strikePrice, uint256 amount, bool isBuy) internal override {
        if (address(doppiOpportunity) == address(0)) revert NotExist();
        _opportunityAddAmountLowLevel(strikePrice, amount, isBuy);
    }

    function _subtractOpportunityTrade(
        uint256 strikePrice,
        uint256 subtractSwapped,
        uint256 subtractOut,
        bool isBuy
    ) internal override {
        if (address(doppiOpportunity) == address(0)) revert NotExist();
        _opportunitySubtractTradeLowLevel(strikePrice, subtractSwapped, subtractOut, isBuy);
    }
}
