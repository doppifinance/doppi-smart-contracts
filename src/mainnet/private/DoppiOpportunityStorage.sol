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
    }
    
    function setOpportunitySell(
        uint256 strikePrice,
        uint256 amount,
        uint256 swappedAmount,
        uint256 outAmount
    ) external onlyDoppiCore {
        opportunitySell[strikePrice] = OpportunityOrders(amount, swappedAmount, outAmount);
    }
    
    // Amount modifiers
    
    function addOpportunityBuyAmount(uint256 strikePrice, uint256 amount) external onlyDoppiCore {
        opportunityBuy[strikePrice].amount += amount;
    }
    
    function addOpportunitySellAmount(uint256 strikePrice, uint256 amount) external onlyDoppiCore {
        opportunitySell[strikePrice].amount += amount;
    }
    
    function subtractOpportunityBuy(uint256 strikePrice, uint256 subtractSwapped, uint256 subtractOut) external onlyDoppiCore {
        OpportunityOrders storage opp = opportunityBuy[strikePrice];
        opp.swappedAmount -= subtractSwapped;
        opp.outAmount -= subtractOut;
    }
    
    function subtractOpportunitySell(uint256 strikePrice, uint256 subtractSwapped, uint256 subtractOut) external onlyDoppiCore {
        OpportunityOrders storage opp = opportunitySell[strikePrice];
        opp.swappedAmount -= subtractSwapped;
        opp.outAmount -= subtractOut;
    }
}
