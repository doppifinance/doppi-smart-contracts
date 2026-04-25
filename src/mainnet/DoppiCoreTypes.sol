// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// tradeState: 0 = not traded, 1 = partial, 2 = fully traded
struct SettlementPlan {
    uint64  posId;
    bool    isBuy;
    bool    striked;
    uint8   tradeState;    // 0 = none, 1 = partial, 2 = full
    uint256 tradedPortion; // amount of p.amount covered by the opp swap (pre-allocated in plan phase)
    uint256 myAmountOut;   // proportional outAmount allocated to this position (pre-allocated in plan phase)
}

struct StrikeNode {
        uint256 prev;
        uint256 next;
        bool active;
    }


//  Common Structs and Enums for DualAssetCore Modules
struct DualAssetOffer {
    uint256 price;
    uint256 strikePrice;
    uint32 apr;
    uint256 delta;
    uint32 expiry;
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

/// @notice Lightweight params used only by DoppiTrader.bulkDeposit.
/// strikePrice / apr / expiry are intentionally absent — DoppiCore derives
/// them from a fresh DoppiOffer call at execution time.
struct BulkDepositParam {
    uint256 amount;
    uint8 strikeZone;
    uint8 numDays;
}

struct DepositParams {
    uint256 amount;
    uint8 strikeZone;
    uint256 strikePrice;
    uint8 numDays;
    uint32 apr;
    uint32 expiry; 
}
