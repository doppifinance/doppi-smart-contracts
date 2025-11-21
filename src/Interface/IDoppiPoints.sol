// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IDoppiPoints {
    
    function recordTrade(address trader, uint256 volumeInUSDT) external;
    function resetPoint(address trader) external;
    function paused() external view returns (bool);
}
