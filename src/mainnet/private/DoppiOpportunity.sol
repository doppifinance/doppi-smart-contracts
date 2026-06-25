// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../DoppiCoreTypes.sol";

/**
 * @title DoppiOpportunity
 * @notice Storage contract for opportunity orders (buy/sell)
 * Can be deployed as proxy instances (one per private DoppiCore)
 */
contract DoppiOpportunity {
    
    /// @notice Opportunity orders indexed by strike price
    /// True for buy opportunities, false for sell opportunities
    mapping(uint256 => OpportunityOrders) public opportunityBuy;
    mapping(uint256 => OpportunityOrders) public opportunitySell;
    
    /// @notice Only doppiCore of this opportunity instance can modify state
    address public doppiCore;
    
    /// @notice Initialize opportunity storage (called via proxy)
    function initialize(address _doppiCore) external {
        require(doppiCore == address(0), "Already initialized");
        doppiCore = _doppiCore;
    }
    
    // Modifiers
    modifier onlyDoppiCore() {
        require(msg.sender == doppiCore, "Only DoppiCore");
        _;
    }
    
    // Write functions
    
    /// @notice Update buy opportunity at strike price
    function setOpportunityBuy(
        uint256 strikePrice,
        uint256 amount,
        uint256 swappedAmount,
        uint256 outAmount
    ) external onlyDoppiCore {
        opportunityBuy[strikePrice] = OpportunityOrders({
            amount: amount,
            swappedAmount: swappedAmount,
            outAmount: outAmount
        });
    }
    
    /// @notice Update sell opportunity at strike price
    function setOpportunitySell(
        uint256 strikePrice,
        uint256 amount,
        uint256 swappedAmount,
        uint256 outAmount
    ) external onlyDoppiCore {
        opportunitySell[strikePrice] = OpportunityOrders({
            amount: amount,
            swappedAmount: swappedAmount,
            outAmount: outAmount
        });
    }
    
    /// @notice Add to buy opportunity amount
    function addOpportunityBuyAmount(uint256 strikePrice, uint256 amount) external onlyDoppiCore {
        opportunityBuy[strikePrice].amount += amount;
    }
    
    /// @notice Add to sell opportunity amount
    function addOpportunitySellAmount(uint256 strikePrice, uint256 amount) external onlyDoppiCore {
        opportunitySell[strikePrice].amount += amount;
    }
    
    /// @notice Subtract from buy opportunity (with underflow protection)
    function subtractOpportunityBuy(
        uint256 strikePrice,
        uint256 subtractSwapped,
        uint256 subtractOut
    ) external onlyDoppiCore {
        opportunityBuy[strikePrice].swappedAmount = opportunityBuy[strikePrice].swappedAmount > subtractSwapped
            ? opportunityBuy[strikePrice].swappedAmount - subtractSwapped
            : 0;
        opportunityBuy[strikePrice].outAmount = opportunityBuy[strikePrice].outAmount > subtractOut
            ? opportunityBuy[strikePrice].outAmount - subtractOut
            : 0;
    }
    
    /// @notice Subtract from sell opportunity (with underflow protection)
    function subtractOpportunitySell(
        uint256 strikePrice,
        uint256 subtractSwapped,
        uint256 subtractOut
    ) external onlyDoppiCore {
        opportunitySell[strikePrice].swappedAmount = opportunitySell[strikePrice].swappedAmount > subtractSwapped
            ? opportunitySell[strikePrice].swappedAmount - subtractSwapped
            : 0;
        opportunitySell[strikePrice].outAmount = opportunitySell[strikePrice].outAmount > subtractOut
            ? opportunitySell[strikePrice].outAmount - subtractOut
            : 0;
    }
    
    // Read functions
    
    /// @notice Get opportunity by direction and strike price
    function getOpportunityOrders(bool isBuy, uint256 strikePrice) 
        external 
        view 
        returns (OpportunityOrders memory) 
    {
        return isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
    }
    
    /// @notice Get buy opportunity at strike price
    function getBuyOpportunity(uint256 strikePrice) 
        external 
        view 
        returns (OpportunityOrders memory) 
    {
        return opportunityBuy[strikePrice];
    }
    
    /// @notice Get sell opportunity at strike price
    function getSellOpportunity(uint256 strikePrice) 
        external 
        view 
        returns (OpportunityOrders memory) 
    {
        return opportunitySell[strikePrice];
    }
}
