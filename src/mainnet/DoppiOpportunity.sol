// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./DoppiCore.sol";
import "../Interface/AutomationCompatibleInterface.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiOpportunity} from "../Interface/IDoppiOpportunity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OpportunityOrders, StrikeNode} from "./DoppiCoreTypes.sol";
// import "forge-std/console.sol";

contract DoppiOpportunity is Ownable, Pausable, AutomationCompatibleInterface, Initializable, IDoppiOpportunity {
    error ZeroForwarder();
    error InvalidForwarder();
    error InvalidBps();
    error InvalidCore();
    error OnlyDoppiCore();

    uint16 private constant BPS = 10000;

    DoppiCore public doppiCore;
    IDoppiLiquidity public doppiLP;
    address public s_forwarderAddress;
    uint16 public opportunityBufferCutBps = 2000; // 20% cut from one-day buffer
    uint16 public opportunityMinBufferBps = 100; // 1% floor

    // Opportunity storage by strike price (for private combined mode)
    mapping(uint256 => OpportunityOrders) public opportunityBuy;
    mapping(uint256 => OpportunityOrders) public opportunitySell;
    mapping(uint256 => StrikeNode) internal buyStrikeNodes;
    mapping(uint256 => StrikeNode) internal sellStrikeNodes;
    uint256 internal buyHead;
    uint256 internal buyTail;
    uint256 internal sellHead;
    uint256 internal sellTail;
    uint256 internal activeBuyStrikeCount;
    uint256 internal activeSellStrikeCount;
    
    constructor(address _doppiCore, address _doppiLP) Ownable(msg.sender) {
        _disableInitializers();
        doppiCore = DoppiCore(_doppiCore);
        doppiLP = IDoppiLiquidity(_doppiLP);
    }

    function initialize(address _doppiCore) external override initializer {
        if (_doppiCore == address(0)) revert InvalidCore();
        doppiCore = DoppiCore(_doppiCore);
        doppiLP = doppiCore.doppiLP();
        opportunityBufferCutBps = 2000;
        opportunityMinBufferBps = 100;
        _transferOwnership(msg.sender);
    }

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        if (forwarderAddress == address(0)) revert ZeroForwarder();
        s_forwarderAddress = forwarderAddress;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        
        if(paused()) return (false, bytes(""));

        uint256 price = doppiLP.getPrice();
        if(price == 0) return (false, bytes(""));

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
        if(price == 0) return;
        
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

    function setOpportunityBufferParams(uint16 _bufferCutBps, uint16 _minBufferBps) external onlyOwner {
        if (_bufferCutBps > BPS || _minBufferBps > BPS) revert InvalidBps();
        opportunityBufferCutBps = _bufferCutBps;
        opportunityMinBufferBps = _minBufferBps;
    }

    modifier onlyForwarder() {
        if (msg.sender != s_forwarderAddress) revert InvalidForwarder();
        _;
    }

    modifier onlyDoppiCore() {
        if (msg.sender != address(doppiCore)) revert OnlyDoppiCore();
        _;
    }

    // Storage getters/setters (IDoppiOpportunity)

    function getBuyOpportunity(uint256 strikePrice) external view override returns (OpportunityOrders memory) {
        return opportunityBuy[strikePrice];
    }

    function getSellOpportunity(uint256 strikePrice) external view override returns (OpportunityOrders memory) {
        return opportunitySell[strikePrice];
    }

    function getOpportunityOrders(bool isBuy, uint256 strikePrice) external view override returns (OpportunityOrders memory) {
        return isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
    }

    function setOpportunityBuy(
        uint256 strikePrice,
        uint256 amount,
        uint256 swappedAmount,
        uint256 outAmount
    ) external override onlyDoppiCore {
        opportunityBuy[strikePrice] = OpportunityOrders(amount, swappedAmount, outAmount);
        _syncStrikeState(strikePrice, true);
    }

    function setOpportunitySell(
        uint256 strikePrice,
        uint256 amount,
        uint256 swappedAmount,
        uint256 outAmount
    ) external override onlyDoppiCore {
        opportunitySell[strikePrice] = OpportunityOrders(amount, swappedAmount, outAmount);
        _syncStrikeState(strikePrice, false);
    }

    function addOpportunityBuyAmount(uint256 strikePrice, uint256 amount) external override onlyDoppiCore {
        opportunityBuy[strikePrice].amount += amount;
        _syncStrikeState(strikePrice, true);
    }

    function addOpportunitySellAmount(uint256 strikePrice, uint256 amount) external override onlyDoppiCore {
        opportunitySell[strikePrice].amount += amount;
        _syncStrikeState(strikePrice, false);
    }

    function subtractOpportunityBuy(uint256 strikePrice, uint256 subtractSwapped, uint256 subtractOut) external override onlyDoppiCore {
        OpportunityOrders storage opp = opportunityBuy[strikePrice];
        opp.swappedAmount -= subtractSwapped;
        opp.outAmount -= subtractOut;
        _syncStrikeState(strikePrice, true);
    }

    function subtractOpportunitySell(uint256 strikePrice, uint256 subtractSwapped, uint256 subtractOut) external override onlyDoppiCore {
        OpportunityOrders storage opp = opportunitySell[strikePrice];
        opp.swappedAmount -= subtractSwapped;
        opp.outAmount -= subtractOut;
        _syncStrikeState(strikePrice, false);
    }

    function reduceOpportunityOrder(bool isBuy, uint256 strikePrice, uint256 amount) external override onlyDoppiCore {
        OpportunityOrders storage opp = isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
        if (opp.amount <= amount) {
            opp.amount = 0;
        } else {
            opp.amount -= amount;
        }
        _syncStrikeState(strikePrice, isBuy);
    }

    function syncStrikeState(uint256 strikePrice, bool isBuy) external override onlyDoppiCore {
        _syncStrikeState(strikePrice, isBuy);
    }

    function getLowerUpperBound() external view override returns (uint256 lower, uint256 upper) {
        lower = buyHead == 0
            ? sellHead
            : sellHead == 0
                ? buyHead
                : (buyHead < sellHead ? buyHead : sellHead);

        upper = buyTail > sellTail ? buyTail : sellTail;
    }

    function getActiveStrikeSnapshot(bool isBuy)
        external
        view
        override
        returns (uint256 activeCount, uint256 head, uint256 tail)
    {
        if (isBuy) {
            return (activeBuyStrikeCount, buyHead, buyTail);
        }
        return (activeSellStrikeCount, sellHead, sellTail);
    }

    function getStrikeNode(bool isBuy, uint256 strikePrice)
        external
        view
        override
        returns (uint256 prev, uint256 next, bool active)
    {
        StrikeNode memory node = isBuy ? buyStrikeNodes[strikePrice] : sellStrikeNodes[strikePrice];
        return (node.prev, node.next, node.active);
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

        uint256 reducedMove = oneDayMove * (BPS - opportunityBufferCutBps) / BPS;
        uint256 effectiveBufferBps = reducedMove > opportunityMinBufferBps
            ? reducedMove
            : opportunityMinBufferBps;

        (targetPrices, totalAmount) = _checkOppoOrUnwind(isBuy, price, effectiveBufferBps, false);
        (targetPricesUnwind, totalAmountUnwind) = _checkOppoOrUnwind(isBuy, price, effectiveBufferBps, true);
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

    function _syncStrikeState(uint256 strikePrice, bool isBuy) internal {
        OpportunityOrders memory opp = isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
        bool shouldBeActive = opp.amount > 0 || opp.swappedAmount > 0 || opp.outAmount > 0;

        if (isBuy) {
            if (shouldBeActive) {
                _activateStrikeNode(buyStrikeNodes, strikePrice, true);
            } else {
                _deactivateStrikeNode(buyStrikeNodes, strikePrice, true);
            }
        } else {
            if (shouldBeActive) {
                _activateStrikeNode(sellStrikeNodes, strikePrice, false);
            } else {
                _deactivateStrikeNode(sellStrikeNodes, strikePrice, false);
            }
        }
    }

    function _activateStrikeNode(
        mapping(uint256 => StrikeNode) storage strikeNodes,
        uint256 strikePrice,
        bool isBuySide
    ) internal {
        StrikeNode storage node = strikeNodes[strikePrice];
        if (node.active) return;

        node.active = true;
        if (isBuySide) {
            unchecked { ++activeBuyStrikeCount; }
        } else {
            unchecked { ++activeSellStrikeCount; }
        }

        uint256 head = isBuySide ? buyHead : sellHead;
        uint256 tail = isBuySide ? buyTail : sellTail;

        if (head == 0) {
            if (isBuySide) {
                buyHead = strikePrice;
                buyTail = strikePrice;
            } else {
                sellHead = strikePrice;
                sellTail = strikePrice;
            }
            return;
        }

        if (strikePrice <= head) {
            node.next = head;
            strikeNodes[head].prev = strikePrice;
            if (isBuySide) buyHead = strikePrice;
            else sellHead = strikePrice;
            return;
        }

        if (strikePrice >= tail) {
            node.prev = tail;
            strikeNodes[tail].next = strikePrice;
            if (isBuySide) buyTail = strikePrice;
            else sellTail = strikePrice;
            return;
        }

        uint256 current = head;
        while (current != 0 && current < strikePrice) {
            current = strikeNodes[current].next;
        }

        uint256 prevNode = strikeNodes[current].prev;
        node.prev = prevNode;
        node.next = current;
        strikeNodes[prevNode].next = strikePrice;
        strikeNodes[current].prev = strikePrice;
    }

    function _deactivateStrikeNode(
        mapping(uint256 => StrikeNode) storage strikeNodes,
        uint256 strikePrice,
        bool isBuySide
    ) internal {
        StrikeNode storage node = strikeNodes[strikePrice];
        if (!node.active) return;

        uint256 prevNode = node.prev;
        uint256 nextNode = node.next;

        if (prevNode != 0) {
            strikeNodes[prevNode].next = nextNode;
        } else if (isBuySide) {
            buyHead = nextNode;
        } else {
            sellHead = nextNode;
        }

        if (nextNode != 0) {
            strikeNodes[nextNode].prev = prevNode;
        } else if (isBuySide) {
            buyTail = prevNode;
        } else {
            sellTail = prevNode;
        }

        delete strikeNodes[strikePrice];
        if (isBuySide) {
            if (activeBuyStrikeCount > 0) {
                unchecked { --activeBuyStrikeCount; }
            }
        } else {
            if (activeSellStrikeCount > 0) {
                unchecked { --activeSellStrikeCount; }
            }
        }
    }
}