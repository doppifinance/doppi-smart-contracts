// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IDoppiPoints {
    
    function recordTrade(address trader, uint256 volumeInUSDT) external;
    function resetPoint(address trader) external;
    function setBotVolumeMultiplier(uint256 numerator, uint256 denominator) external;
    function setCoreRegistrar(address registrar, bool allowed) external;
    function registerCore(address core, address factory) external;
    function paused() external view returns (bool);
}
