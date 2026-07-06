// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Canonical module list for private bot automation jobs.
enum PrivateAutomationModule {
    Trader,
    Core,
    Opportunity,
    Liquidity
}

/// @notice Registration payload used by factory -> automation hub.
struct RegisterPrivateBotParams {
    address trader;
    address bot;
    address core;
    address opportunity;
    address liquidity;
    address router;
    uint32 botId;
}

/// @notice Returned job ids for each private module.
struct PrivateBotJobIds {
    uint256 traderJobId;
    uint256 coreJobId;
    uint256 opportunityJobId;
    uint256 liquidityJobId;
}

/// @notice Per-job execution controls used by the hub scheduler.
struct PrivateJobConfig {
    bool active;
    uint32 minInterval;
    uint32 maxStaleness;
    uint32 gasLimitHint;
    uint16 maxConsecutiveFails;
}

/// @notice View shape for external indexing and operator tooling.
struct PrivateJobView {
    uint256 jobId;
    PrivateAutomationModule module;
    address bot;
    address target;
    bool active;
    uint32 minInterval;
    uint32 maxStaleness;
    uint32 gasLimitHint;
    uint32 failCount;
    uint64 lastRunAt;
    uint64 nextEligibleAt;
}

/// @notice Per-bot billing state: credit balance, trader EOA, lifetime fees, low-credit flag.
struct BotBillingState {
    address trader;           // registered EOA that can withdraw credit
    uint256 creditBalance;    // remaining pre-paid balance in fundToken
    uint256 totalGasFeePaid;  // lifetime fees charged
    bool    lowCreditPaused;  // true when hub paused jobs due to low credit
    bool usePoint; // use point to pay for gas fee, if false, use fundToken to pay for gas fee
}
