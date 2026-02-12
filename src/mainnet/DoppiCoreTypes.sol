// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//  Common Structs and Enums for DualAssetCore Modules
struct DualAssetOffer {
    uint256 price;
    uint256 strikePrice;
    uint32 apr;
    uint256 delta;
    uint32 expiry;
}

struct PendingSettlement {
    uint256[] indexes;
    uint256 settlementPrice;
}

struct OpportunityOrders {
    uint256 amount;
    uint256 swappedAmount;
    uint256 outAmount;
}

/// @notice User position data
struct DualAssetPosition {
    uint256 amount;
    uint256 price;
    uint256 strikePrice;
    uint32 expiryTimestamp; 
    uint32 apr;
    address owner;
    uint256 interest;
    uint256 payout;
}

struct SettleAccumulate {
    uint64 positionId;
    uint256 totalInterestA;
    uint256 totalInterestB;
    uint256 totalA;
    uint256 totalB;
}

struct DepositParams {
    uint256 amount;
    uint8 strikeZone;
    uint256 strikePrice;
    uint8 numDays;
    uint32 apr;
    uint32 expiry; 
}

struct SettlementResult {
    address profitToken;
    address payoutToken;
    address interestToken;
    bool isProfit;
    uint256 profitLoss;
}
