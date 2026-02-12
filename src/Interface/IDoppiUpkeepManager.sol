// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDoppiUpkeepManager {
    function getForwarder(uint256 _upkeepId) external view returns (address);
    function getUpkeepIdByBot(address _traderbot) external view returns (uint256);
    function getDefault_Amount() external view returns (uint256); 
    function insertNewBot(address trader, address bot) external;
}
