// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @notice IAutomationRegistryConsumer defines the LTS user-facing interface that we intend to maintain for
 * across upgrades. As long as users use functions from within this interface, their upkeeps will retain
 * backwards compatability across migrations.
 * @dev Functions can be added to this interface, but not removed.
 */
interface IAutomationRegistryConsumer {

  struct UpkeepInfo {
    address target;
    uint32 executeGas;
    bytes checkData;
    uint96 balance;
    address admin;
    uint64 maxValidBlocknumber;
    uint32 lastPerformBlockNumber;
    uint96 amountSpent;
    bool paused;
    bytes offchainConfig;
    address forwarder;
  }

  struct RegistrationParams {
        string name;
        bytes encryptedEmail;
        address upkeepContract;
        uint32 gasLimit;
        address adminAddress;
        uint8 triggerType;
        bytes checkData;
        bytes triggerConfig;
        bytes offchainConfig;
        uint96 amount;
    }

  function getBalance(uint256 id) external view returns (uint96 balance);

  function getMinBalance(uint256 id) external view returns (uint96 minBalance);

  function cancelUpkeep(uint256 id) external;

  function pauseUpkeep(uint256 id) external;

  function unpauseUpkeep(uint256 id) external;

  function addFunds(uint256 id, uint96 amount) external;

  function withdrawFunds(uint256 id, address to) external;

  function setUpkeepGasLimit(uint256 id, uint32 gasLimit) external;
  
  function registerUpkeep(
        RegistrationParams calldata requestParams
    ) external returns (uint256);

   function getUpkeep(uint256 id) external view returns (UpkeepInfo memory upkeepInfo);
   function getForwarder(uint256 upkeepID) external view returns (address);
  
}