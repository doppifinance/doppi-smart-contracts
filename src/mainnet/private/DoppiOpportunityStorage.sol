// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IDoppiCore} from "../../Interface/IDoppiCore.sol";
import "../DoppiCoreTypes.sol";

/**
 * @title DoppiOpportunityStorage
 * @notice Storage contract for opportunity orders in private DoppiCore instances
 * 
 * This contract stores buy and sell opportunity orders per strike price.
 * It's initialized with a reference to its associated DoppiCore and can only be
 * called by that core.
 */
contract DoppiOpportunityStorage is Initializable {
    IDoppiCore public doppiCore;
    
    // Opportunity storage by strike price
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
    
    modifier onlyDoppiCore() {
        require(msg.sender == address(doppiCore), "OnlyDoppiCore");
        _;
    }
    
    /**
     * @notice Initialize the opportunity storage with a reference to DoppiCore
     * @param _doppiCore Address of the associated DoppiCore contract
     */
    function initialize(address _doppiCore) external initializer {
        require(_doppiCore != address(0), "Invalid core");
        doppiCore = IDoppiCore(_doppiCore);
    }
    
    // Getters
    
    function getBuyOpportunity(uint256 strikePrice) external view returns (OpportunityOrders memory) {
        return opportunityBuy[strikePrice];
    }
    
    function getSellOpportunity(uint256 strikePrice) external view returns (OpportunityOrders memory) {
        return opportunitySell[strikePrice];
    }
    
    function getOpportunityOrders(bool isBuy, uint256 strikePrice) external view returns (OpportunityOrders memory) {
        return isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
    }
    
    // Setters (only callable by DoppiCore)
    
    function setOpportunityBuy(
        uint256 strikePrice,
        uint256 amount,
        uint256 swappedAmount,
        uint256 outAmount
    ) external onlyDoppiCore {
        opportunityBuy[strikePrice] = OpportunityOrders(amount, swappedAmount, outAmount);
        _syncStrikeState(strikePrice, true);
    }
    
    function setOpportunitySell(
        uint256 strikePrice,
        uint256 amount,
        uint256 swappedAmount,
        uint256 outAmount
    ) external onlyDoppiCore {
        opportunitySell[strikePrice] = OpportunityOrders(amount, swappedAmount, outAmount);
        _syncStrikeState(strikePrice, false);
    }
    
    // Amount modifiers
    
    function addOpportunityBuyAmount(uint256 strikePrice, uint256 amount) external onlyDoppiCore {
        opportunityBuy[strikePrice].amount += amount;
        _syncStrikeState(strikePrice, true);
    }
    
    function addOpportunitySellAmount(uint256 strikePrice, uint256 amount) external onlyDoppiCore {
        opportunitySell[strikePrice].amount += amount;
        _syncStrikeState(strikePrice, false);
    }
    
    function subtractOpportunityBuy(uint256 strikePrice, uint256 subtractSwapped, uint256 subtractOut) external onlyDoppiCore {
        OpportunityOrders storage opp = opportunityBuy[strikePrice];
        opp.swappedAmount -= subtractSwapped;
        opp.outAmount -= subtractOut;
        _syncStrikeState(strikePrice, true);
    }
    
    function subtractOpportunitySell(uint256 strikePrice, uint256 subtractSwapped, uint256 subtractOut) external onlyDoppiCore {
        OpportunityOrders storage opp = opportunitySell[strikePrice];
        opp.swappedAmount -= subtractSwapped;
        opp.outAmount -= subtractOut;
        _syncStrikeState(strikePrice, false);
    }

    function reduceOpportunityOrder(bool isBuy, uint256 strikePrice, uint256 amount) external onlyDoppiCore {
        OpportunityOrders storage opp = isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
        if (opp.amount <= amount) {
            opp.amount = 0;
        } else {
            opp.amount -= amount;
        }
        _syncStrikeState(strikePrice, isBuy);
    }

    function syncStrikeState(uint256 strikePrice, bool isBuy) external onlyDoppiCore {
        _syncStrikeState(strikePrice, isBuy);
    }

    function getLowerUpperBound() external view returns (uint256 lower, uint256 upper) {
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
        returns (uint256 prev, uint256 next, bool active)
    {
        StrikeNode memory node = isBuy ? buyStrikeNodes[strikePrice] : sellStrikeNodes[strikePrice];
        return (node.prev, node.next, node.active);
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
