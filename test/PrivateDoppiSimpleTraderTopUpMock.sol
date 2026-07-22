// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPrivateAutomationHub} from "../src/Interface/IPrivateAutomationHub.sol";
import {
    RegisterPrivateBotParams,
    PrivateBotJobIds,
    PrivateAutomationModule,
    PrivateJobConfig,
    PrivateJobView,
    BotBillingState
} from "../src/mainnet/private/PrivateAutomationHubTypes.sol";

contract MockPrivateAutomationHubForSimple is IPrivateAutomationHub {
    uint256 public sharedRegisterCount;
    IERC20 public topUpToken;
    uint256 public topUpAmount;
    uint256 public creditThreshold;
    uint256 public creditBalance;
    bool public pausedForLowCredit;
    mapping(address => uint256) public depositedByBot;

    function setBillingConfig(IERC20 _topUpToken, uint256 _topUpAmount, bool _pausedForLowCredit) external {
        topUpToken = _topUpToken;
        topUpAmount = _topUpAmount;
        creditThreshold = _topUpAmount;
        creditBalance = _pausedForLowCredit ? 0 : _topUpAmount + 1;
        pausedForLowCredit = _pausedForLowCredit;
    }

    function setCreditThreshold(uint256 _creditThreshold) external {
        creditThreshold = _creditThreshold;
    }

    function setCreditBalance(uint256 _creditBalance) external {
        creditBalance = _creditBalance;
    }

    function registerPrivateBotJobs(RegisterPrivateBotParams calldata)
        external
        pure
        returns (PrivateBotJobIds memory jobIds)
    {
        return jobIds;
    }

    function registerSharedBotJob(address, address, uint32) external returns (uint256 jobId) {
        sharedRegisterCount += 1;
        return sharedRegisterCount;
    }

    function disablePrivateBotJobs(address) external pure {}

    function getJobId(address, PrivateAutomationModule) external pure returns (uint256 jobId) {
        return 0;
    }

    function getJobIdsByBot(address) external pure returns (PrivateBotJobIds memory jobIds) {
        return jobIds;
    }

    function getJob(uint256) external pure returns (PrivateJobView memory job) {
        return job;
    }

    function setJobConfig(uint256, PrivateJobConfig calldata) external pure {}

    function setJobActive(uint256, bool) external pure {}

    function checkUpkeep(bytes calldata) external pure returns (bool upkeepNeeded, bytes memory performData) {
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata) external pure {}

    function getBotBilling(address) external view returns (BotBillingState memory) {
        return BotBillingState({
            trader: address(0),
            creditBalance: creditBalance,
            totalGasFeePaid: 0,
            lowCreditPaused: pausedForLowCredit,
            usePoint: false
        });
    }

    function deposit(address bot, uint256 amount) external {
        require(topUpToken.transferFrom(msg.sender, address(this), amount), "top up transfer failed");
        depositedByBot[bot] += amount;
    }

    function defaultTopUp() external view returns (uint256) {
        return topUpAmount;
    }

    function fundToken() external view returns (IERC20) {
        return topUpToken;
    }

    function minCreditThreshold() external view returns (uint256){
        return creditThreshold;
    }
}