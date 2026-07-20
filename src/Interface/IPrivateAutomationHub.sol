// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AutomationCompatibleInterface} from "./AutomationCompatibleInterface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    RegisterPrivateBotParams,
    PrivateBotJobIds,
    PrivateAutomationModule,
    PrivateJobConfig,
    PrivateJobView,
    BotBillingState
} from "../mainnet/private/PrivateAutomationHubTypes.sol";

/// @notice Shared scheduler/orchestrator for private bot upkeep jobs.
interface IPrivateAutomationHub is AutomationCompatibleInterface {
    /// @notice Registers all module jobs for one private bot in one call.
    function registerPrivateBotJobs(RegisterPrivateBotParams calldata params)
        external
        returns (PrivateBotJobIds memory jobIds);

    /// @notice Registers a shared bot job (trader only, no core/opportunity/liquidity).
    ///         Used when shared bots migrate to PrivateAutomationHub for billing.
    function registerSharedBotJob(
        address trader,
        address bot,
        uint32 botId
    ) external returns (uint256 jobId);

    /// @notice Deactivate all jobs tied to one private bot.
    function disablePrivateBotJobs(address bot) external;

    /// @notice Returns job id for a specific bot/module pair, or 0 if missing.
    function getJobId(address bot, PrivateAutomationModule module) external view returns (uint256 jobId);

    /// @notice Returns all module job ids for a private bot.
    function getJobIdsByBot(address bot) external view returns (PrivateBotJobIds memory jobIds);

    /// @notice Returns normalized job view for operator tooling.
    function getJob(uint256 jobId) external view returns (PrivateJobView memory job);

    /// @notice Configure one job scheduling profile.
    function setJobConfig(uint256 jobId, PrivateJobConfig calldata config) external;

    /// @notice Pause/unpause one job.
    function setJobActive(uint256 jobId, bool active) external;

    function getBotBilling(address bot) external view returns (BotBillingState memory);
    function deposit(address bot, uint256 amount) external;
    function defaultTopUp() external view returns (uint256);
    function fundToken() external view returns (IERC20);
    function minCreditThreshold() external view returns (uint256);
}
