// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct DoppiUpkeepInfo {
    uint256 upkeepId;
    address targetContract;
    bool isRegistered;
    address trader;
}

struct DoppiUpkeepPayment {
    address trader;
    uint256 lastBlockCharged;
    uint96 lastPaidAmount;
}

struct CheckUpKeepStorage {

    uint256 upkeepId;
    uint256 tobepaid;
    bool topUp;
    uint256 fee;
    uint96 amountSpent;
    uint256 feeInfundToken;
}

struct TopUpInfo {
    uint256 fee;
    uint96 amountSpent;
    uint256 feeInfundToken;
    uint256 topUpAmountInfundToken;
    uint256 totalInfundToken;
}