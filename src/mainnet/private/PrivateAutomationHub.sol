// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPrivateAutomationHub} from "../../Interface/IPrivateAutomationHub.sol";
import {AggregatorV3Interface} from "../../Interface/AggregatorV3Interface.sol";
import {DALiquidityLib} from "../../Library/DALiquidityLib.sol";
import {
    RegisterPrivateBotParams,
    PrivateBotJobIds,
    PrivateAutomationModule,
    PrivateJobConfig,
    PrivateJobView,
    BotBillingState
} from "./PrivateAutomationHubTypes.sol";

interface IDoppiPoints {
    function getAllPointData(address trader) external view returns (uint256 totalClaimed, uint256 readyPoints, uint256 currentMonth);
    function deductPointsForFee(address trader, uint256 points) external;
}

/// @notice Shared upkeep target: schedules and executes private bot module jobs in bounded batches.
/// @dev Billing: per-bot fundToken credit deducted at gas-cost + platform markup per successful execution.
contract PrivateAutomationHub is IPrivateAutomationHub, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidAddress();
    error InvalidJob();
    error InvalidLengths();
    error NotRegistrar();
    error NotExecutor();
    error NotBotTrader();
    error MarkupTooHigh();
    error ZeroAmount();
    error InsufficientCredit();

    // ── Access ────────────────────────────────────────────────────────────
    event RegistrarUpdated(address indexed account, bool allowed);
    event ExecutorUpdated(address indexed account, bool allowed);
    event GlobalLimitsUpdated(uint16 maxJobsPerUpkeep, uint32 scanLimit);
    event DefaultJobConfigUpdated(uint32 minInterval, uint32 maxStaleness, uint32 gasLimitHint, uint16 maxConsecutiveFails);

    // ── Jobs ──────────────────────────────────────────────────────────────
    event JobRegistered(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module, address target);
    event JobUpdated(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module, address target);
    event JobDisabled(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module);
    event JobConfigUpdated(uint256 indexed jobId, bool active, uint32 minInterval, uint32 maxStaleness, uint32 gasLimitHint, uint16 maxConsecutiveFails);
    event JobExecutionSucceeded(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module);
    event JobExecutionFailed(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module);
    event JobAutoPaused(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module, uint32 failCount);

    // ── Billing ───────────────────────────────────────────────────────────
    event FundTokenUpdated(address indexed fundToken);
    event TreasuryUpdated(address indexed treasury);
    event PlatformMarkupUpdated(uint24 markupBps);
    event MinCreditThresholdUpdated(uint256 threshold);
    event GasOverheadBufferUpdated(uint256 buffer);
    event MaxOracleDelayUpdated(uint32 delay);
    event CreditDeposited(address indexed bot, address indexed depositor, uint256 amount);
    event CreditWithdrawn(address indexed bot, address indexed trader, uint256 amount);
    event BotLowCreditPaused(address indexed bot, uint256 remainingCredit);
    event BotLowCreditResumed(address indexed bot, uint256 newCredit);
    event JobFeeCharged(uint256 indexed jobId, address indexed bot, uint256 gasUsed, uint256 gasPrice, uint256 rawCostInFundToken, uint256 totalFeeInFundToken);

    // ── Doppi offset scaffold (storage + event only, no billing logic yet) ─
    event DoppiTokenSet(address indexed doppiToken);

    // ── DoppiPoints Integration ────────────────────────────────────────────
    event DoppiPointsContractSet(address indexed doppiPoints);
    event DoppiPointsExchangeRateUpdated(uint256 rateBps);
    event DoppiPointsPriceFeedUpdated(address indexed feed, bool isDynamic);
    event PointsPaymentEnabled(address indexed bot, address indexed trader);
    event PointsPaymentDisabled(address indexed bot, address indexed trader);
    event PointsUsedForFee(uint256 indexed jobId, address indexed bot, uint256 pointsDeducted, uint256 fundTokenSaved);

    struct JobState {
        address bot;
        address target;
        PrivateAutomationModule module;
        bool active;
        bool lowCreditDisabled;         // set true only when auto-paused by low-credit
        uint32 minInterval;
        uint32 maxStaleness;
        uint32 gasLimitHint;
        uint16 maxConsecutiveFails;
        uint32 failCount;
        uint64 lastRunAt;
        uint64 nextEligibleAt;
    }

    // ── Scheduling ────────────────────────────────────────────────────────
    uint256 public nextJobId  = 1;
    uint256 public scanCursor = 1;

    uint16 public maxJobsPerUpkeep = 8;
    uint32 public checkScanLimit   = 64;

    uint32 public defaultMinInterval         = 30;
    uint32 public defaultMaxStaleness        = 3600;
    uint32 public defaultGasLimitHint        = 700_000;
    uint16 public defaultMaxConsecutiveFails = 5;

    // ── Billing config ────────────────────────────────────────────────────
    IERC20                public fundToken;
    address               public treasury;
    AggregatorV3Interface public immutable chainlinkFeed;
    uint256               public immutable priceDecimals;
    uint32                public maxOracleDelay;
    uint24                public platformMarkupBps;   // e.g. 2000 = 20%
    uint256               public minCreditThreshold;  // in fundToken units
    uint256               public gasOverheadBuffer;   // added to each per-call gas measurement

    // ── Doppi offset scaffold ─────────────────────────────────────────────
    address public doppiToken;

    // ── DoppiPoints Integration ────────────────────────────────────────────
    IDoppiPoints public doppiPoints;
    uint256 public doppiPointsExchangeRateBps;  // basis points, e.g., 10000 = 1:1
    bool public useDynamicPointPrice;
    address public doppiPointsPriceFeed;
    mapping(address => uint256) public pointsUsedBalance;  // track points spent per bot
    mapping(address => bool) public pointsPaymentEnabled;   // opt-in per bot

    // ── Access ────────────────────────────────────────────────────────────
    mapping(address => bool) public registrars;
    mapping(address => bool) public executors;

    // ── Job storage ───────────────────────────────────────────────────────
    mapping(uint256 => JobState)                  internal jobs;
    mapping(address => mapping(uint8 => uint256)) internal jobIdByBotModule;

    // ── Billing storage ───────────────────────────────────────────────────
    mapping(address => BotBillingState) internal botBilling;

    bytes4 private constant CHECK_UPKEEP_SELECTOR   = bytes4(keccak256("checkUpkeep(bytes)"));
    bytes4 private constant PERFORM_UPKEEP_SELECTOR = bytes4(keccak256("performUpkeep(bytes)"));
    uint24 private constant MAX_MARKUP_BPS           = 5000; // 50% hard cap

    modifier onlyRegistrar() {
        if (!registrars[msg.sender] && msg.sender != owner()) revert NotRegistrar();
        _;
    }

    modifier onlyExecutor() {
        if (!executors[msg.sender] && msg.sender != owner()) revert NotExecutor();
        _;
    }

    /// @param initialOwner     Contract owner.
    /// @param _fundToken       ERC-20 used for credit (address(0) disables billing at deploy).
    /// @param _chainlinkFeed   Chainlink native-asset/USD feed (address(0) disables billing).
    /// @param _maxOracleDelay  Max acceptable oracle staleness in seconds.
    /// @param _treasury        Fee destination (address(0) disables billing at deploy).
    constructor(
        address initialOwner,
        address _fundToken,
        address _chainlinkFeed,
        uint32  _maxOracleDelay,
        address _treasury
    ) Ownable(initialOwner) {
        chainlinkFeed  = AggregatorV3Interface(_chainlinkFeed);
        priceDecimals  = _chainlinkFeed != address(0)
            ? 10 ** DALiquidityLib.getPriceDecimals(AggregatorV3Interface(_chainlinkFeed))
            : 1e8;
        maxOracleDelay = _maxOracleDelay;
        if (_fundToken != address(0)) fundToken = IERC20(_fundToken);
        if (_treasury  != address(0)) treasury  = _treasury;
    }

    // ── Access admin ──────────────────────────────────────────────────────

    function setRegistrar(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        registrars[account] = allowed;
        emit RegistrarUpdated(account, allowed);
    }

    function setExecutor(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        executors[account] = allowed;
        emit ExecutorUpdated(account, allowed);
    }

    function setGlobalLimits(uint16 _maxJobsPerUpkeep, uint32 _checkScanLimit) external onlyOwner {
        if (_maxJobsPerUpkeep == 0 || _checkScanLimit == 0) revert InvalidJob();
        maxJobsPerUpkeep = _maxJobsPerUpkeep;
        checkScanLimit   = _checkScanLimit;
        emit GlobalLimitsUpdated(_maxJobsPerUpkeep, _checkScanLimit);
    }

    function setDefaultJobConfig(
        uint32 _minInterval,
        uint32 _maxStaleness,
        uint32 _gasLimitHint,
        uint16 _maxConsecutiveFails
    ) external onlyOwner {
        if (_gasLimitHint == 0 || _maxConsecutiveFails == 0) revert InvalidJob();
        defaultMinInterval         = _minInterval;
        defaultMaxStaleness        = _maxStaleness;
        defaultGasLimitHint        = _gasLimitHint;
        defaultMaxConsecutiveFails = _maxConsecutiveFails;
        emit DefaultJobConfigUpdated(_minInterval, _maxStaleness, _gasLimitHint, _maxConsecutiveFails);
    }

    // ── Billing admin ─────────────────────────────────────────────────────

    function setFundToken(address _fundToken) external onlyOwner {
        fundToken = IERC20(_fundToken);
        emit FundTokenUpdated(_fundToken);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setPlatformMarkup(uint24 _markupBps) external onlyOwner {
        if (_markupBps > MAX_MARKUP_BPS) revert MarkupTooHigh();
        platformMarkupBps = _markupBps;
        emit PlatformMarkupUpdated(_markupBps);
    }

    function setMinCreditThreshold(uint256 _threshold) external onlyOwner {
        minCreditThreshold = _threshold;
        emit MinCreditThresholdUpdated(_threshold);
    }

    function setGasOverheadBuffer(uint256 _buffer) external onlyOwner {
        gasOverheadBuffer = _buffer;
        emit GasOverheadBufferUpdated(_buffer);
    }

    function setMaxOracleDelay(uint32 _delay) external onlyOwner {
        maxOracleDelay = _delay;
        emit MaxOracleDelayUpdated(_delay);
    }

    /// @notice Scaffold: stores Doppi token address for a future fee-offset feature. No billing logic yet.
    function setDoppiToken(address _doppiToken) external onlyOwner {
        doppiToken = _doppiToken;
        emit DoppiTokenSet(_doppiToken);
    }

    /// @notice Set DoppiPoints contract for points-based fee payment.
    function setDoppiPointsContract(address _doppiPoints) external onlyOwner {
        if (_doppiPoints == address(0)) revert InvalidAddress();
        doppiPoints = IDoppiPoints(_doppiPoints);
        emit DoppiPointsContractSet(_doppiPoints);
    }

    /// @notice Set exchange rate for DoppiPoints to fundToken (in basis points).
    /// @param _rateBps e.g., 10000 = 1:1, 5000 = 0.5:1, 20000 = 2:1
    function setDoppiPointsExchangeRate(uint256 _rateBps) external onlyOwner {
        if (_rateBps == 0) revert InvalidJob();
        doppiPointsExchangeRateBps = _rateBps;
        emit DoppiPointsExchangeRateUpdated(_rateBps);
    }

    /// @notice Set Doppi price feed for dynamic pricing (when Doppi token launches).
    /// @param _feed Address of Doppi/BNB or Doppi/USD Chainlink feed
    /// @param _useDynamic If true, use dynamic price from feed; if false, use fixed exchange rate
    function setDoppiPointsPriceFeed(address _feed, bool _useDynamic) external onlyOwner {
        doppiPointsPriceFeed = _feed;
        useDynamicPointPrice = _useDynamic;
        emit DoppiPointsPriceFeedUpdated(_feed, _useDynamic);
    }

    // ── Credit management ─────────────────────────────────────────────────

    /// @notice Deposit fundToken credit for a bot. Callable by anyone.
    /// @dev Re-enables paused jobs if credit crosses minCreditThreshold.
    function deposit(address bot, uint256 amount) external nonReentrant {
        if (bot == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        if (address(fundToken) == address(0)) revert InvalidAddress();

        fundToken.safeTransferFrom(msg.sender, address(this), amount);
        BotBillingState storage billing = botBilling[bot];
        billing.creditBalance += amount;

        emit CreditDeposited(bot, msg.sender, amount);

        if (billing.lowCreditPaused) {
            // Check combined value: fundToken + available points
            uint256 combinedValue = billing.creditBalance;
            if (pointsPaymentEnabled[bot] && address(doppiPoints) != address(0)) {
                combinedValue += _getTotalPointsValueInFundToken(bot);
            }
            
            if (combinedValue >= minCreditThreshold) {
                billing.lowCreditPaused = false;
                _resumeAllJobsForBot(bot);
                emit BotLowCreditResumed(bot, billing.creditBalance);
            }
        }
    }

    /// @notice Withdraw unused credit. Only the registered bot trader may call.
    function withdraw(address bot, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        BotBillingState storage billing = botBilling[bot];
        if (msg.sender != billing.trader) revert NotBotTrader();
        if (billing.creditBalance < amount) revert InsufficientCredit();

        billing.creditBalance -= amount;
        fundToken.safeTransfer(billing.trader, amount);

        emit CreditWithdrawn(bot, billing.trader, amount);
    }

    /// @notice Returns full billing state for a bot.
    function getBotBilling(address bot) external view returns (BotBillingState memory) {
        return botBilling[bot];
    }

    /// @notice Enable DoppiPoints payment for a bot. Only the bot's trader may call.
    function enablePointsPayment(address bot) external {
        BotBillingState storage billing = botBilling[bot];
        if (msg.sender != billing.trader) revert NotBotTrader();
        if (pointsPaymentEnabled[bot]) return; // already enabled
        pointsPaymentEnabled[bot] = true;
        emit PointsPaymentEnabled(bot, msg.sender);
    }

    /// @notice Disable DoppiPoints payment for a bot. Only the bot's trader may call.
    function disablePointsPayment(address bot) external {
        BotBillingState storage billing = botBilling[bot];
        if (msg.sender != billing.trader) revert NotBotTrader();
        if (!pointsPaymentEnabled[bot]) return; // already disabled
        pointsPaymentEnabled[bot] = false;
        emit PointsPaymentDisabled(bot, msg.sender);
    }

    /// @notice Get available DoppiPoints for a bot (readyPoints - spent).
    function getAvailablePoints(address bot) external view returns (uint256) {
        if (address(doppiPoints) == address(0)) return 0;
        BotBillingState memory billing = botBilling[bot];
        if (billing.trader == address(0)) return 0;
        (, uint256 readyPoints, ) = doppiPoints.getAllPointData(billing.trader);
        uint256 spent = pointsUsedBalance[bot];
        return readyPoints > spent ? readyPoints - spent : 0;
    }

    /// @notice Get the fundToken value of DoppiPoints based on current exchange rate.
    function getPointValueInUSDT(uint256 numPoints) external view returns (uint256) {
        if (useDynamicPointPrice && doppiPointsPriceFeed != address(0)) {
            // Dynamic pricing: query Doppi price from oracle
            uint256 doppiPrice = DALiquidityLib.getPrice(AggregatorV3Interface(doppiPointsPriceFeed), maxOracleDelay);
            if (doppiPrice == 0) return 0;
            return (numPoints * doppiPrice) / priceDecimals;
        } else {
            // Fixed exchange rate in basis points
            if (doppiPointsExchangeRateBps == 0) return 0;
            return (numPoints * doppiPointsExchangeRateBps) / 10000;
        }
    }

    // ── Job registration ──────────────────────────────────────────────────

    function registerPrivateBotJobs(RegisterPrivateBotParams calldata params)
        external
        onlyRegistrar
        returns (PrivateBotJobIds memory jobIds)
    {
        if (
            params.trader      == address(0) ||
            params.bot         == address(0) ||
            params.core        == address(0) ||
            params.opportunity == address(0) ||
            params.liquidity   == address(0)
        ) revert InvalidAddress();

        jobIds.traderJobId      = _upsertJob(params.bot, PrivateAutomationModule.Trader,      params.bot);
        jobIds.coreJobId        = _upsertJob(params.bot, PrivateAutomationModule.Core,        params.core);
        jobIds.opportunityJobId = _upsertJob(params.bot, PrivateAutomationModule.Opportunity, params.opportunity);
        jobIds.liquidityJobId   = _upsertJob(params.bot, PrivateAutomationModule.Liquidity,   params.liquidity);

        // Record billing trader on first registration only.
        if (botBilling[params.bot].trader == address(0)) {
            botBilling[params.bot].trader = params.trader;
        }
    }

    function disablePrivateBotJobs(address bot) external onlyRegistrar {
        if (bot == address(0)) revert InvalidAddress();
        _disableJob(bot, PrivateAutomationModule.Trader);
        _disableJob(bot, PrivateAutomationModule.Core);
        _disableJob(bot, PrivateAutomationModule.Opportunity);
        _disableJob(bot, PrivateAutomationModule.Liquidity);
    }

    /**
     * @notice Register a shared bot job (trader only, no core/opportunity/liquidity).
     *         Used when shared bots migrate to PrivateAutomationHub for billing.
     */
    function registerSharedBotJob(
        address trader,
        address bot,
        uint32 botId
    ) external onlyRegistrar returns (uint256 jobId) {
        if (trader == address(0) || bot == address(0)) revert InvalidAddress();
        
        jobId = _upsertJob(bot, PrivateAutomationModule.Trader, bot);
        
        if (botBilling[bot].trader == address(0)) {
            botBilling[bot].trader = trader;
        }
    }

    // ── Job queries ───────────────────────────────────────────────────────

    function getJobId(address bot, PrivateAutomationModule module) external view returns (uint256 jobId) {
        return jobIdByBotModule[bot][uint8(module)];
    }

    function getJobIdsByBot(address bot) external view returns (PrivateBotJobIds memory jobIds) {
        jobIds.traderJobId      = jobIdByBotModule[bot][uint8(PrivateAutomationModule.Trader)];
        jobIds.coreJobId        = jobIdByBotModule[bot][uint8(PrivateAutomationModule.Core)];
        jobIds.opportunityJobId = jobIdByBotModule[bot][uint8(PrivateAutomationModule.Opportunity)];
        jobIds.liquidityJobId   = jobIdByBotModule[bot][uint8(PrivateAutomationModule.Liquidity)];
    }

    function getJob(uint256 jobId) external view returns (PrivateJobView memory job) {
        JobState storage j = jobs[jobId];
        if (j.bot == address(0)) revert InvalidJob();
        return PrivateJobView({
            jobId:          jobId,
            module:         j.module,
            bot:            j.bot,
            target:         j.target,
            active:         j.active,
            minInterval:    j.minInterval,
            maxStaleness:   j.maxStaleness,
            gasLimitHint:   j.gasLimitHint,
            failCount:      j.failCount,
            lastRunAt:      j.lastRunAt,
            nextEligibleAt: j.nextEligibleAt
        });
    }

    function setJobConfig(uint256 jobId, PrivateJobConfig calldata config) external onlyOwner {
        JobState storage j = jobs[jobId];
        if (j.bot == address(0)) revert InvalidJob();
        j.active              = config.active;
        j.minInterval         = config.minInterval;
        j.maxStaleness        = config.maxStaleness;
        j.gasLimitHint        = config.gasLimitHint;
        j.maxConsecutiveFails = config.maxConsecutiveFails;
        emit JobConfigUpdated(jobId, config.active, config.minInterval, config.maxStaleness, config.gasLimitHint, config.maxConsecutiveFails);
    }

    function setJobActive(uint256 jobId, bool active) external onlyOwner {
        JobState storage j = jobs[jobId];
        if (j.bot == address(0)) revert InvalidJob();
        j.active = active;
        if (active && j.nextEligibleAt == 0) j.nextEligibleAt = uint64(block.timestamp);
        emit JobConfigUpdated(jobId, j.active, j.minInterval, j.maxStaleness, j.gasLimitHint, j.maxConsecutiveFails);
    }

    // ── Automation ────────────────────────────────────────────────────────

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 upperBound = nextJobId;
        if (upperBound <= 1) return (false, bytes(""));

        uint16  maxJobs              = maxJobsPerUpkeep;
        uint256[] memory candidateJobIds      = new uint256[](maxJobs);
        bytes[]   memory candidatePerformData = new bytes[](maxJobs);

        uint256 cursor  = _normalizedCursor(scanCursor, upperBound);
        uint256 scanned;
        uint256 selected;

        while (scanned < checkScanLimit && selected < maxJobs) {
            if (cursor >= upperBound) cursor = 1;
            JobState storage j = jobs[cursor];
            if (_isDue(j)) {
                (bool ok, bytes memory out) = j.target.staticcall(
                    abi.encodeWithSelector(CHECK_UPKEEP_SELECTOR, bytes(""))
                );
                if (ok && out.length >= 64) {
                    (bool needed, bytes memory jobPerformData) = abi.decode(out, (bool, bytes));
                    if (needed) {
                        candidateJobIds[selected]      = cursor;
                        candidatePerformData[selected] = jobPerformData;
                        unchecked { ++selected; }
                    }
                }
            }
            unchecked { ++cursor; ++scanned; }
        }

        if (selected == 0) return (false, bytes(""));

        uint256[] memory finalJobIds      = new uint256[](selected);
        bytes[]   memory finalPerformData = new bytes[](selected);
        for (uint256 i = 0; i < selected; ) {
            finalJobIds[i]      = candidateJobIds[i];
            finalPerformData[i] = candidatePerformData[i];
            unchecked { ++i; }
        }
        upkeepNeeded = true;
        performData  = abi.encode(_normalizedCursor(cursor, upperBound), finalJobIds, finalPerformData);
    }

    function performUpkeep(bytes calldata performData) external override onlyExecutor nonReentrant {
        (uint256 nextCursor, uint256[] memory jobIds, bytes[] memory payloads) =
            abi.decode(performData, (uint256, uint256[], bytes[]));

        if (jobIds.length != payloads.length) revert InvalidLengths();
        uint256 cap = jobIds.length;
        if (cap > maxJobsPerUpkeep) cap = maxJobsPerUpkeep;

        for (uint256 i = 0; i < cap; ) {
            uint256 jobId = jobIds[i];
            JobState storage j = jobs[jobId];

            if (_isDue(j)) {
                uint256 gasStart = gasleft();

                (bool success, ) = j.target.call{gas: j.gasLimitHint}(
                    abi.encodeWithSelector(PERFORM_UPKEEP_SELECTOR, payloads[i])
                );

                uint256 gasUsed = gasStart - gasleft() + gasOverheadBuffer;

                if (success) {
                    j.failCount      = 0;
                    j.lastRunAt      = uint64(block.timestamp);
                    j.nextEligibleAt = uint64(block.timestamp + j.minInterval);
                    emit JobExecutionSucceeded(jobId, j.bot, j.module);
                    _chargeGasFee(j.bot, jobId, gasUsed);
                } else {
                    _recordFailure(jobId, j);
                }
            }
            unchecked { ++i; }
        }

        scanCursor = _normalizedCursor(nextCursor, nextJobId);
    }

    // ── Internal: billing ─────────────────────────────────────────────────

    /// @dev Silently skips if billing is not fully configured or oracle is stale / gasprice is 0.
    function _chargeGasFee(address bot, uint256 jobId, uint256 gasUsed) internal {
        if (address(fundToken)     == address(0)) return;
        if (address(chainlinkFeed) == address(0)) return;
        if (treasury               == address(0)) return;

        uint256 price = DALiquidityLib.getPrice(chainlinkFeed, maxOracleDelay);
        if (price == 0) return;

        // cost (fundToken units) = gasUsed * gasPrice (wei) * nativeAsset/USD / priceDecimals
        uint256 rawCost  = (gasUsed * tx.gasprice * price) / priceDecimals;
        uint256 markup   = (rawCost * platformMarkupBps) / 10000;
        uint256 totalFee = rawCost + markup;
        if (totalFee == 0) return;

        BotBillingState storage billing = botBilling[bot];

        // Deduct points first (if enabled), then fundToken for remainder
        uint256 fundTokenFee = totalFee;
        uint256 pointsDeducted = 0;
        
        if (pointsPaymentEnabled[bot] && address(doppiPoints) != address(0)) {
            pointsDeducted = _deductPointsForFee(bot, totalFee);
            if (pointsDeducted > 0) {
                uint256 pointValueInToken = _getPointValueInFundToken(pointsDeducted);
                fundTokenFee -= pointValueInToken;
                emit PointsUsedForFee(jobId, bot, pointsDeducted, pointValueInToken);
            }
        }

        // Deduct remaining fee from fundToken credit
        if (fundTokenFee > 0) {
            if (billing.creditBalance < fundTokenFee) fundTokenFee = billing.creditBalance;
            billing.creditBalance -= fundTokenFee;
        }
        
        billing.totalGasFeePaid += totalFee;

        if (fundTokenFee > 0) fundToken.safeTransfer(treasury, fundTokenFee);

        emit JobFeeCharged(jobId, bot, gasUsed, tx.gasprice, rawCost, fundTokenFee);

        // Check low credit threshold considering BOTH fundToken and available points value
        if (!billing.lowCreditPaused) {
            uint256 combinedValue = billing.creditBalance;
            if (pointsPaymentEnabled[bot] && address(doppiPoints) != address(0)) {
                combinedValue += _getTotalPointsValueInFundToken(bot);
            }
            if (combinedValue < minCreditThreshold) {
                billing.lowCreditPaused = true;
                _pauseAllJobsForBot(bot);
                emit BotLowCreditPaused(bot, billing.creditBalance);
            }
        }
    }

    /// @dev Deduct points for fee, returns number of points deducted.
    function _deductPointsForFee(address bot, uint256 feeInFundToken) internal returns (uint256 pointsDeducted) {
        BotBillingState storage billing = botBilling[bot];
        if (billing.trader == address(0)) return 0;

        (, uint256 readyPoints, ) = doppiPoints.getAllPointData(billing.trader);
        uint256 availablePoints = readyPoints > pointsUsedBalance[bot] ? readyPoints - pointsUsedBalance[bot] : 0;
        if (availablePoints == 0) return 0;

        // Calculate points needed: feeInFundToken * 10000 / exchangeRate
        uint256 pointsNeeded;
        if (useDynamicPointPrice && doppiPointsPriceFeed != address(0)) {
            uint256 doppiPrice = DALiquidityLib.getPrice(AggregatorV3Interface(doppiPointsPriceFeed), maxOracleDelay);
            if (doppiPrice == 0) return 0;
            // pointsNeeded = feeInFundToken / doppiPrice * priceDecimals
            pointsNeeded = (feeInFundToken * priceDecimals) / doppiPrice;
        } else {
            // Fixed rate: pointsNeeded = (feeInFundToken * 10000) / doppiPointsExchangeRateBps
            if (doppiPointsExchangeRateBps == 0) return 0;
            pointsNeeded = (feeInFundToken * 10000) / doppiPointsExchangeRateBps;
        }

        pointsDeducted = availablePoints < pointsNeeded ? availablePoints : pointsNeeded;
        pointsUsedBalance[bot] += pointsDeducted;
        
        // Record the deduction in DoppiPoints to prevent double-counting
        if (pointsDeducted > 0 && address(doppiPoints) != address(0)) {
            doppiPoints.deductPointsForFee(billing.trader, pointsDeducted);
        }
    }

    /// @dev Get fundToken value of a specific number of points
    function _getPointValueInFundToken(uint256 numPoints) internal view returns (uint256) {
        if (useDynamicPointPrice && doppiPointsPriceFeed != address(0)) {
            uint256 doppiPrice = DALiquidityLib.getPrice(AggregatorV3Interface(doppiPointsPriceFeed), maxOracleDelay);
            if (doppiPrice == 0) return 0;
            return (numPoints * doppiPrice) / priceDecimals;
        } else {
            if (doppiPointsExchangeRateBps == 0) return 0;
            return (numPoints * doppiPointsExchangeRateBps) / 10000;
        }
    }

    /// @dev Get total value of a bot's available points in fundToken units
    function _getTotalPointsValueInFundToken(address bot) internal view returns (uint256) {
        BotBillingState memory billing = botBilling[bot];
        if (billing.trader == address(0)) return 0;
        
        (, uint256 readyPoints, ) = doppiPoints.getAllPointData(billing.trader);
        uint256 availablePoints = readyPoints > pointsUsedBalance[bot] ? readyPoints - pointsUsedBalance[bot] : 0;
        return _getPointValueInFundToken(availablePoints);
    }

    function _pauseAllJobsForBot(address bot) internal {
        for (uint8 m = 0; m < 4; ) {
            uint256 jid = jobIdByBotModule[bot][m];
            if (jid != 0) {
                JobState storage j = jobs[jid];
                if (j.active) {
                    j.active            = false;
                    j.lowCreditDisabled = true;
                    emit JobDisabled(jid, bot, j.module);
                }
            }
            unchecked { ++m; }
        }
    }

    /// @dev Only re-enables jobs that were disabled by the low-credit auto-pause.
    function _resumeAllJobsForBot(address bot) internal {
        for (uint8 m = 0; m < 4; ) {
            uint256 jid = jobIdByBotModule[bot][m];
            if (jid != 0) {
                JobState storage j = jobs[jid];
                if (j.lowCreditDisabled) {
                    j.active            = true;
                    j.lowCreditDisabled = false;
                    if (j.nextEligibleAt < block.timestamp) j.nextEligibleAt = uint64(block.timestamp);
                }
            }
            unchecked { ++m; }
        }
    }

    // ── Internal: scheduling ──────────────────────────────────────────────

    function _upsertJob(address bot, PrivateAutomationModule module, address target) internal returns (uint256 jobId) {
        if (target == address(0)) revert InvalidAddress();
        uint8 moduleId = uint8(module);
        jobId = jobIdByBotModule[bot][moduleId];

        if (jobId == 0) {
            jobId = nextJobId;
            unchecked { ++nextJobId; }
            jobIdByBotModule[bot][moduleId] = jobId;

            JobState storage created = jobs[jobId];
            created.bot                 = bot;
            created.target              = target;
            created.module              = module;
            created.active              = true;
            created.minInterval         = defaultMinInterval;
            created.maxStaleness        = defaultMaxStaleness;
            created.gasLimitHint        = defaultGasLimitHint;
            created.maxConsecutiveFails = defaultMaxConsecutiveFails;
            created.nextEligibleAt      = uint64(block.timestamp);

            emit JobRegistered(jobId, bot, module, target);
            return jobId;
        }

        JobState storage existing = jobs[jobId];
        existing.target = target;
        existing.active = true;
        if (existing.gasLimitHint        == 0) existing.gasLimitHint        = defaultGasLimitHint;
        if (existing.maxConsecutiveFails == 0) existing.maxConsecutiveFails = defaultMaxConsecutiveFails;
        if (existing.nextEligibleAt      == 0) existing.nextEligibleAt      = uint64(block.timestamp);

        emit JobUpdated(jobId, bot, module, target);
    }

    function _disableJob(address bot, PrivateAutomationModule module) internal {
        uint256 jobId = jobIdByBotModule[bot][uint8(module)];
        if (jobId == 0) return;
        JobState storage j = jobs[jobId];
        if (!j.active) return;
        j.active = false;
        emit JobDisabled(jobId, bot, module);
    }

    function _isDue(JobState storage j) internal view returns (bool) {
        if (j.bot == address(0) || j.target == address(0) || !j.active) return false;
        return block.timestamp >= j.nextEligibleAt;
    }

    function _recordFailure(uint256 jobId, JobState storage j) internal {
        unchecked { ++j.failCount; }
        emit JobExecutionFailed(jobId, j.bot, j.module);
        if (j.failCount >= j.maxConsecutiveFails) {
            j.active = false;
            emit JobAutoPaused(jobId, j.bot, j.module, j.failCount);
        } else {
            j.nextEligibleAt = uint64(block.timestamp + j.minInterval);
        }
    }

    function _normalizedCursor(uint256 cursor, uint256 upperBound) internal pure returns (uint256) {
        if (upperBound <= 1) return 1;
        if (cursor == 0 || cursor >= upperBound) return 1;
        return cursor;
    }
}
