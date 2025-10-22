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

/// @notice User position data
struct DualAssetPosition {
    uint256 amount;
    uint256 price;
    uint256 strikePrice;
    uint32 expiryTimestamp; // Changed to uint32 to save storage
    uint32 apr;
    address owner;
    uint256 swappedAmount;
    bool isTraded;
    uint256 interest;
    uint256 hedgeAmountInHedgeToken;
    uint256 swappedHedgeAmount;
    uint256 hedgePrice;
}

struct KeyPosition {
    address owner;
    uint32 positionId; // Changed to uint32
}

struct DepositParams {
    uint256 amount;
    uint8 strikeZone;
    uint256 strikePrice;
    uint32 numDays;
    uint32 apr;
    uint32 expiry; // Changed to uint32
}

struct HedgeBulkTrade {
    uint256 hedgeAmountInHedgeToken;
    uint256 swappedHedgeAmount;
    uint256 hedgePrice;
    bool isNetBuy;
}

struct Trade {
    uint256 payoutAmount;
    uint256 origAmount;
    uint256 origStrikePrice;
}

struct OrderConfig {
    uint8 strikeZone;
    uint24 weight;
}

struct UndoStat {
    uint256 undo_assetB;
    uint256 undo_assetA;
}

