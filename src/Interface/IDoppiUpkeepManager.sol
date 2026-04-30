// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "../mainnet/DoppiUpkeepManagerTypes.sol";

interface IDoppiUpkeepManager {
    function getForwarder(uint256 _upkeepId) external view returns (address);
    function getUpkeepIdByBot(address _traderbot) external view returns (uint256);
    function getDefault_Amount() external view returns (uint256); 
    function insertNewBot(address trader, address bot) external;
    function shouldTopUpkeep(uint256 upkeepId) external view returns (TopUpInfo memory topUpInfo, bool needTopUp);
    function performTopUpkeep(uint256 upkeepId) external;
    function shouldInsertNew(address traderBot) external view returns (bool needInsert);
}
