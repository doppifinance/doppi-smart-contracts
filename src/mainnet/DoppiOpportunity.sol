// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./DoppiCore.sol";
import "../Interface/AutomationCompatibleInterface.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiOpportunity} from "../Interface/IDoppiOpportunity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import "./DoppiCoreTypes.sol";
// import "forge-std/console.sol";

contract DoppiOpportunity is Ownable, Pausable, AutomationCompatibleInterface {
    error ZeroForwarder();
    error InvalidForwarder();

    DoppiCore public immutable doppiCore;
    IDoppiLiquidity public immutable doppiLP;
    address public s_forwarderAddress;
    
    constructor(address _doppiCore, address _doppiLP) Ownable(msg.sender) {
        doppiCore = DoppiCore(_doppiCore);
        doppiLP = IDoppiLiquidity(_doppiLP);
    }

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        if (forwarderAddress == address(0)) revert ZeroForwarder();
        s_forwarderAddress = forwarderAddress;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        
        if(paused()) return (false, bytes(""));

        uint256 price = doppiLP.getPrice();
        (uint256[] memory targetPrices, uint256[] memory targetPricesUnwind, ,) = _checkOpportunity(price, true);
        (uint256[] memory targetPricesSell, uint256[] memory targetPricesSellUnwind, ,) = _checkOpportunity(price, false);

        upkeepNeeded = (targetPrices.length > 0 || targetPricesUnwind.length > 0 || targetPricesSell.length > 0 || targetPricesSellUnwind.length > 0);
        
        if (upkeepNeeded) {
            return (true, bytes(""));
        } 
        return (upkeepNeeded, bytes(""));
    }

    function performUpkeep(bytes calldata) external override onlyForwarder {
        
        if(paused()) return;
        uint256 price = doppiLP.getPrice();
        (   
            uint256[] memory targetPrices, 
            uint256[] memory targetPricesUnwind, 
            uint256 totalAmountBuy,
            uint256 totalAmountBuyUnwind
        ) = _checkOpportunity(price, true);
        
        (   
            uint256[] memory targetPricesSell, 
            uint256[] memory targetPricesSellUnwind, 
            uint256 totalAmountSell,
            uint256 totalAmountSellUnwind
        ) = _checkOpportunity(price, false);

        if(targetPrices.length > 0 || targetPricesUnwind.length > 0){
            _performOpportunity(targetPrices, targetPricesUnwind, totalAmountBuy, totalAmountBuyUnwind, true, price);
        }
        if(targetPricesSell.length > 0 || targetPricesSellUnwind.length > 0){
            _performOpportunity(targetPricesSell, targetPricesSellUnwind, totalAmountSell, totalAmountSellUnwind, false, price);
        }
    }

    function performOpportunity(
        uint256[] memory targetPrices,
        uint256[] memory targetPricesUnwind,
        uint256 totalAmount,
        uint256 totalAmountUnwind,
        bool isBuy
    ) external onlyForwarder {
        _performOpportunity(targetPrices, targetPricesUnwind, totalAmount, totalAmountUnwind, isBuy, doppiLP.getPrice());
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }

    modifier onlyForwarder() {
        if (msg.sender != s_forwarderAddress) revert InvalidForwarder();
        _;
    }

    function _checkOpportunity(uint256 price, bool isBuy)
        internal
        view
        returns (
            uint256[] memory targetPrices,
            uint256[] memory targetPricesUnwind,
            uint256 totalAmount,
            uint256 totalAmountUnwind
        )
    {
        uint256 oneDayMove = doppiCore.doppiOffer().getOneDayBuffer(price, isBuy);
        if (oneDayMove == 0) {
            return (new uint256[](0), new uint256[](0), 0, 0);
        }

        (targetPrices, totalAmount) = _checkOppoOrUnwind(isBuy, price, oneDayMove, false);
        (targetPricesUnwind, totalAmountUnwind) = _checkOppoOrUnwind(isBuy, price, oneDayMove, true);
    }

    function _checkOppoOrUnwind(
        bool isBuy,
        uint256 price,
        uint256 oneDayMove,
        bool unwind
    ) internal view returns (uint256[] memory targetPrices, uint256 totalAmount) {
        IDoppiOpportunity opportunityStore = doppiCore.doppiOpportunity();
        (uint256 activeCount, uint256 head, uint256 tail) = opportunityStore.getActiveStrikeSnapshot(isBuy);
        if (activeCount == 0) {
            return (new uint256[](0), 0);
        }

        uint256[] memory tempTargetPrice = new uint256[](activeCount);
        uint256 count;

        uint256 buffer = price * oneDayMove / 10000;
        uint256 triggerPrice = isBuy ? price + buffer : price - buffer;
        uint256 triggerUnwindPrice = isBuy ? price - buffer : price + buffer;
        uint256 maxSwapInLocal = (isBuy == unwind) ? doppiCore.maxSwap() * doppiCore.priceDecimal() / price : doppiCore.maxSwap();
        bool ascending = isBuy != unwind;
        uint256 strikePrice = ascending ? tail : head;

        while (strikePrice != 0) {
            (uint256 prevStrike, uint256 nextStrike,) = opportunityStore.getStrikeNode(isBuy, strikePrice);
            uint256 cursor = ascending ? prevStrike : nextStrike;

            OpportunityOrders memory order = opportunityStore.getOpportunityOrders(isBuy, strikePrice);
            bool isTriggered;
            uint256 comparedAmount;

            if (unwind) {
                comparedAmount = order.outAmount;
                uint256 unwindSwappedAmount = order.swappedAmount;
                if (comparedAmount > 0 && unwindSwappedAmount > 0) {
                    uint256 costPrice = isBuy
                        ? unwindSwappedAmount * doppiCore.priceDecimal() / comparedAmount
                        : comparedAmount * doppiCore.priceDecimal() / unwindSwappedAmount;
                    isTriggered = isBuy ? costPrice < triggerUnwindPrice : costPrice > triggerUnwindPrice;
                }
            } else {
                comparedAmount = order.amount > order.swappedAmount ? order.amount - order.swappedAmount : 0;
                isTriggered = isBuy
                    ? (comparedAmount > 0 && strikePrice > triggerPrice)
                    : (comparedAmount > 0 && strikePrice < triggerPrice);
            }

            if (isTriggered && comparedAmount > 0) {
                uint256 totalAmountPost = totalAmount + comparedAmount;
                uint256 toTradeAmount = totalAmountPost > maxSwapInLocal
                    ? comparedAmount - (totalAmountPost - maxSwapInLocal)
                    : comparedAmount;

                if (toTradeAmount > 0 && (totalAmount + toTradeAmount) <= maxSwapInLocal) {
                    totalAmount += toTradeAmount;
                    tempTargetPrice[count] = strikePrice;
                    unchecked { ++count; }
                }
            }

            strikePrice = cursor;
        }

        targetPrices = _createResultArrays(tempTargetPrice, count);
    }

    function _createResultArrays(
        uint256[] memory tempPrices,
        uint256 count
    ) private pure returns (uint256[] memory prices) {
        uint256 resultSize = count < tempPrices.length ? count : tempPrices.length;
        prices = new uint256[](resultSize);

        for (uint256 i = 0; i < resultSize;) {
            prices[i] = tempPrices[resultSize - 1 - i];
            unchecked { ++i; }
        }
    }

    function _performOpportunity(
        uint256[] memory targetPrices,
        uint256[] memory targetPricesUnwind,
        uint256 totalAmount,
        uint256 totalAmountUnwind,
        bool isBuy,
        uint256 price
    ) internal {
        if (targetPrices.length > 0) {
            uint256 amountOut = doppiCore.opportunitySwap(totalAmount, price, isBuy);
            uint256 reduced = totalAmount;
            uint256 reducedout = amountOut;
            for (uint256 j = targetPrices.length; j > 0; ) {
                uint256 strikePrice = targetPrices[j - 1];
                (reduced, reducedout) = doppiCore.executeOpportunityStep(
                    totalAmount,
                    amountOut,
                    price,
                    reduced,
                    reducedout,
                    isBuy,
                    strikePrice
                );
                unchecked { --j; }
            }
        }

        if (targetPricesUnwind.length > 0) {
            uint256 amountOutUnwind = doppiCore.opportunitySwap(totalAmountUnwind, price, !isBuy);
            uint256 reduced = totalAmountUnwind;
            uint256 reducedout = amountOutUnwind;
            for (uint256 j = 0; j < targetPricesUnwind.length; ) {
                uint256 strikePrice = targetPricesUnwind[j];
                (reduced, reducedout) = doppiCore.executeUnwindStep(
                    totalAmountUnwind,
                    amountOutUnwind,
                    price,
                    reduced,
                    reducedout,
                    isBuy,
                    strikePrice
                );
                unchecked { ++j; }
            }
        }
    }
}