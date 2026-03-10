// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";

struct ConfigParam {
    address chainLinkFeed; 
    address router; 
    address quoter; 
    uint24 poolFee;  // fee for v3 swap
    uint24 slippage; // use for swap slippage
    uint24 liquidityFee; // for doppiLP 1000 = 0.10%
    uint8 priceDecimals;
    uint256 decimals;
    address v3Pool; 
    uint32 twapDuration;
    uint24 maxDepositPercentage;
    uint32 maxDelay;
    uint256 maxSwap;
    uint256 priceGap;
    uint8 unwindGapMultiplier;
}

struct Config {
    AggregatorV3Interface chainLinkFeed; 
    address router; 
    address quoter; 
    uint24 poolFee;  // fee for v3 swap
    uint24 slippage; // use for swap slippage
    uint24 liquidityFee; // for doppiLP 1000 = 0.10%
    uint8 priceDecimals;
    uint256 decimals;
    address v3Pool; 
    uint32 twapDuration;
    uint24 maxDepositPercentage;
    uint32 maxDelay;
    uint256 maxSwap;
    uint256 priceGap;
    uint8 unwindGapMultiplier;
}