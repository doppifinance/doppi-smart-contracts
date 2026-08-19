// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPrivateAutomationHub} from "../../Interface/IPrivateAutomationHub.sol";
import {IDoppiPoints} from "../../Interface/IDoppiPoints.sol";
import {AggregatorV3Interface} from "../../Interface/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {DALiquidityLib} from "../../Library/DALiquidityLib.sol";
import {
    PrivateBotJobIds,
    PrivateAutomationModule,
    PrivateJobConfig,
    PrivateJobView,
    BotBillingState
} from "./PrivateAutomationHubTypes.sol";
// import "forge-std/console2.sol";

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
    error MaxCheckUpkeepCallGasTooHigh();
    error InvalidAggregateCheckGas();


    // ── Access ────────────────────────────────────────────────────────────
    event RegistrarUpdated(address indexed account, bool allowed);
    event ExecutorUpdated(address indexed account, bool allowed);
    event GlobalLimitsUpdated(uint16 maxJobsPerUpkeep, uint32 scanLimit);
    event DefaultJobConfigUpdated(uint32 minInterval, uint32 gasLimitHint);
    event MaxAggregateCheckGasUpdated(uint32 maxGas);

    // ── Jobs ──────────────────────────────────────────────────────────────
    event JobRegistered(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module, address target);
    event JobUpdated(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module, address target);
    event JobDisabled(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module);
    event JobConfigUpdated(uint256 indexed jobId, bool active, uint32 minInterval, uint32 gasLimitHint);
    event JobExecutionSucceeded(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module);
    event JobExecutionFailed(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module);
    event JobAutoPaused(uint256 indexed jobId, address indexed bot, PrivateAutomationModule module, uint32 failCount);

    // ── Billing ───────────────────────────────────────────────────────────
    event FundTokenUpdated(address indexed fundToken);
    event BillingAssetConfigured(address indexed fundToken, address indexed nativeToFundTokenFeed, uint256 fundTokenDecimals, uint256 minCreditThreshold, uint256 defaultTopUp);
    event ChainlinkFeedUpdated(address indexed chainlinkFeed, uint256 priceDecimals);
    event DefaultTopUpUpdated(uint256 defaultTopUp);
    event TreasuryUpdated(address indexed treasury);
    event PlatformMarkupUpdated(uint24 markupBps);
    event MinCreditThresholdUpdated(uint256 threshold);
    event GasOverheadBufferUpdated(uint256 buffer);
    event MaxOracleDelayUpdated(uint32 delay);
    event CreditDeposited(address indexed bot, address indexed depositor, uint256 amount);
    event CreditWithdrawn(address indexed bot, address indexed trader, uint256 amount);
    event LegacyCreditRolledOver(address indexed bot, address indexed token, uint256 amount);
    event LegacyCreditWithdrawn(address indexed bot, address indexed token, address indexed trader, uint256 amount);
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
        uint32 gasLimitHint;
        uint32 failCount;
        uint64 lastRunAt;
        uint64 nextEligibleAt;
    }

    // ── Scheduling ────────────────────────────────────────────────────────
    uint256 public nextJobId  = 1;
    uint256 public scanCursor = 1;

    uint16 public maxJobsPerUpkeep = 8;
    uint32 public checkScanLimit   = 64;

    uint256 public defaultTopUp         = 10 ether;
    uint32 public defaultMinInterval         = 30;
    uint32 public defaultGasLimitHint        = 5_000_000;
    uint32 public maxCheckUpkeepCallGas        = 1_000_000;
    uint32 public maxAggregateCheckGas         = 10_000_000;

    // ── Billing config ────────────────────────────────────────────────────
    IERC20                public fundToken;
    uint256               public fundTokenDecimals = 1e18;
    address               public treasury;
    AggregatorV3Interface public chainlinkFeed;
    uint256               public priceDecimals;
    uint32                public maxOracleDelay;
    uint24                public platformMarkupBps;   // e.g. 2000 = 20%
    uint256               public minCreditThreshold;  // in fundToken units
    uint256               public gasOverheadBuffer;   // added to each per-call gas measurement

    // ── Doppi offset scaffold ─────────────────────────────────────────────
    address public doppiToken;

    // ── DoppiPoints Integration ────────────────────────────────────────────
    IDoppiPoints public doppiPoints;
    uint256 public doppiPointsExchangeRateBps = 10;  // basis points, e.g., 10 = 1 point : 0.001 fund token
    bool public useDynamicPointPrice;
    address public doppiPointsPriceFeed;

    // ── Access ────────────────────────────────────────────────────────────
    mapping(address => bool) public registrars;
    mapping(address => bool) public executors;
    mapping(address => IERC20) public botCreditToken;

    // ── Job storage ───────────────────────────────────────────────────────
    mapping(uint256 => JobState)                  internal jobs;
    mapping(address => mapping(uint8 => uint256)) internal jobIdByBotModule;

    // ── Billing storage ───────────────────────────────────────────────────
    mapping(address => BotBillingState) internal botBilling;
    mapping(address => mapping(address => uint256)) public legacyCreditBalance;

    bytes4 private constant CHECK_UPKEEP_SELECTOR   = bytes4(keccak256("checkUpkeep(bytes)"));
    bytes4 private constant PERFORM_UPKEEP_SELECTOR = bytes4(keccak256("performUpkeep(bytes)"));
    uint24 private constant MAX_MARKUP_BPS           = 5000; // 50% hard cap
    uint32 private constant CHECK_GAS_RESERVE         = 150_000;
    uint32 private constant MAX_AGGREGATE_CHECK_GAS   = 25_000_000;

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
    /// @param _chainlinkFeed   Chainlink native-asset/fund-token feed (address(0) disables billing).
    /// @param _maxOracleDelay  Max acceptable oracle staleness in seconds.
    /// @param _treasury        Fee destination (address(0) disables billing at deploy).
    constructor(
        address initialOwner,
        address _fundToken,
        address _chainlinkFeed,
        uint32  _maxOracleDelay,
        address _treasury
    ) Ownable(initialOwner) {
        _setChainlinkFeed(_chainlinkFeed);
        maxOracleDelay = _maxOracleDelay;
        if (_fundToken != address(0)) _setFundToken(_fundToken);
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
        uint32 _gasLimitHint
    ) external onlyOwner {
        if (_gasLimitHint == 0) revert InvalidJob();
        defaultMinInterval         = _minInterval;
        defaultGasLimitHint        = _gasLimitHint;
        emit DefaultJobConfigUpdated(_minInterval, _gasLimitHint);
    }

    function setDefaultTopUp(
        uint256 _defaultTopUp
    ) external onlyOwner {
        defaultTopUp = _defaultTopUp;
        emit DefaultTopUpUpdated(_defaultTopUp);
    }

    // ── Billing admin ─────────────────────────────────────────────────────

    /// @notice Atomically changes the billing token, its native/token feed, and token-denominated limits.
    function setBillingAssetConfig(
        address _fundToken,
        address _nativeToFundTokenFeed,
        uint256 _minCreditThreshold,
        uint256 _defaultTopUp
    ) external onlyOwner {
        _setFundToken(_fundToken);
        _setChainlinkFeed(_nativeToFundTokenFeed);
        minCreditThreshold = _minCreditThreshold;
        defaultTopUp = _defaultTopUp;

        emit MinCreditThresholdUpdated(_minCreditThreshold);
        emit DefaultTopUpUpdated(_defaultTopUp);
        emit BillingAssetConfigured(
            _fundToken,
            _nativeToFundTokenFeed,
            fundTokenDecimals,
            _minCreditThreshold,
            _defaultTopUp
        );
    }

    function setChainlinkFeed(address _chainlinkFeed) external onlyOwner {
        _setChainlinkFeed(_chainlinkFeed);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setPlatformMarkup(uint24 _markupBps) external onlyOwner {
        if (_markupBps > MAX_MARKUP_BPS) revert MarkupTooHigh();
        platformMarkupBps = _markupBps;
        emit PlatformMarkupUpdated(_markupBps);
    }

    function setMaxCheckUpkeepCallGas(uint32 _maxGas) external onlyOwner {
        if (_maxGas > 5_000_000) revert MaxCheckUpkeepCallGasTooHigh();
        maxCheckUpkeepCallGas = _maxGas;
    }

    function setMaxAggregateCheckGas(uint32 _maxGas) external onlyOwner {
        if (_maxGas <= CHECK_GAS_RESERVE || _maxGas > MAX_AGGREGATE_CHECK_GAS) {
            revert InvalidAggregateCheckGas();
        }
        maxAggregateCheckGas = _maxGas;
        emit MaxAggregateCheckGasUpdated(_maxGas);
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

    /// @notice Set Doppi/native V3 pool for dynamic pricing (when Doppi token launches).
    /// @param _pool Address of a Uniswap/Pancake V3 Doppi/native pool (NOT a Chainlink feed)
    /// @param _useDynamic If true, use TWAP price from the pool; if false, use fixed exchange rate
    function setDoppiPointsPriceFeed(address _pool, bool _useDynamic) external onlyOwner {
        if (_useDynamic) {
            if (_pool == address(0) || _pool.code.length == 0) revert InvalidAddress();
            // Reverts if _pool is not a V3 pool exposing this selector, catching Chainlink feed misconfiguration.
            IUniswapV3Pool(_pool).token0();
        }
        doppiPointsPriceFeed = _pool;
        useDynamicPointPrice = _useDynamic;
        emit DoppiPointsPriceFeedUpdated(_pool, _useDynamic);
    }

    // ── Credit management ─────────────────────────────────────────────────

    /// @notice Deposit fundToken credit for a bot. Callable by anyone.
    /// @dev Re-enables paused jobs if credit crosses minCreditThreshold.
    function deposit(address bot, uint256 amount) external nonReentrant {
        if (bot == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();

        BotBillingState storage billing = botBilling[bot];
        _rolloverLegacyCredit(bot);

        IERC20 token = fundToken;
        if (address(token) == address(0)) revert InvalidAddress();
        botCreditToken[bot] = token;

        token.safeTransferFrom(msg.sender, address(this), amount);
        billing.creditBalance += amount;

        emit CreditDeposited(bot, msg.sender, amount);

        if (billing.lowCreditPaused) {
            // Check combined value: fundToken + available points
            uint256 combinedValue = billing.creditBalance;
            if (billing.usePoint && address(doppiPoints) != address(0)) {
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

        _rolloverLegacyCredit(bot);
        if (billing.creditBalance < amount) revert InsufficientCredit();

        billing.creditBalance -= amount;

        IERC20 token = botCreditToken[bot];
        token.safeTransfer(billing.trader, amount);
        if (billing.creditBalance == 0) {
            delete botCreditToken[bot];
        }

        emit CreditWithdrawn(bot, billing.trader, amount);
    }

    /// @notice Withdraw credit retained in a previous fund-token denomination.
    function withdrawLegacy(address bot, address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();

        BotBillingState storage billing = botBilling[bot];
        if (msg.sender != billing.trader) revert NotBotTrader();

        _rolloverLegacyCredit(bot);
        uint256 balance = legacyCreditBalance[bot][token];
        if (balance < amount) revert InsufficientCredit();

        legacyCreditBalance[bot][token] = balance - amount;
        IERC20(token).safeTransfer(billing.trader, amount);

        emit LegacyCreditWithdrawn(bot, token, billing.trader, amount);
    }

    /// @notice Returns full billing state for a bot.
    function getBotBilling(address bot) external view returns (BotBillingState memory) {
        BotBillingState memory billing = botBilling[bot];
        if (address(botCreditToken[bot]) != address(fundToken)) billing.creditBalance = 0;
        return billing;
    }

    /// @notice Enable DoppiPoints payment for a bot. Only the bot's trader may call.
    function enablePointsPayment(address bot) external {
        BotBillingState storage billing = botBilling[bot];
        if (msg.sender != billing.trader) revert NotBotTrader();
        if (billing.usePoint) return; // already enabled
        billing.usePoint = true;
        emit PointsPaymentEnabled(bot, msg.sender);
    }

    /// @notice Disable DoppiPoints payment for a bot. Only the bot's trader may call.
    function disablePointsPayment(address bot) external {
        BotBillingState storage billing = botBilling[bot];
        if (msg.sender != billing.trader) revert NotBotTrader();
        if (!billing.usePoint) return; // already disabled
        billing.usePoint = false;
        emit PointsPaymentDisabled(bot, msg.sender);
    }

    /// @notice Get available DoppiPoints for a bot (readyPoints - spent).
    function getAvailablePoints(address bot) external view returns (uint256) {
        if (address(doppiPoints) == address(0)) return 0;
        BotBillingState memory billing = botBilling[bot];
        if (billing.trader == address(0)) return 0;
        (, uint256 readyPoints, ) = doppiPoints.getAllPointData(billing.trader);
        return readyPoints;
    }

    /// @notice Get the active fund-token value of DoppiPoints based on the current exchange rate.
    /// @dev The legacy function name is retained for integration compatibility.
    function getPointValueInUSDT(uint256 numPoints) external view returns (uint256) {
        return _getPointValueInFundToken(numPoints);
    }

    // ── Job registration ──────────────────────────────────────────────────

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
        j.gasLimitHint        = config.gasLimitHint;
        emit JobConfigUpdated(jobId, config.active, config.minInterval, config.gasLimitHint);
    }

    function setJobActive(uint256 jobId, bool active) external onlyOwner {
        JobState storage j = jobs[jobId];
        if (j.bot == address(0)) revert InvalidJob();
        j.active = active;
        if (active && j.nextEligibleAt == 0) j.nextEligibleAt = uint64(block.timestamp);
        emit JobConfigUpdated(jobId, j.active, j.minInterval, j.gasLimitHint);
    }

    // ── Automation ────────────────────────────────────────────────────────

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {

        if (address(chainlinkFeed) == address(0) || address(fundToken) == address(0) || treasury == address(0)) {
            return (false, bytes(""));
        }
        
        uint256 upperBound = nextJobId;
        if (upperBound <= 1) return (false, bytes(""));
        uint256 totalJobs = upperBound - 1;

        uint16  maxJobs              = maxJobsPerUpkeep;
        uint256[] memory candidateJobIds      = new uint256[](maxJobs);
        bytes[]   memory candidatePerformData = new bytes[](maxJobs);

        uint256 cursor  = _normalizedCursor(scanCursor, upperBound);
        uint256 scanned;
        uint256 selected;
        uint256 scanBudget = checkScanLimit;
        if (scanBudget > totalJobs) scanBudget = totalJobs;
        uint256 scanGasStart = gasleft();
        bool gasBudgetExhausted;

        while (scanned < scanBudget && selected < maxJobs) {
            uint256 gasSpent = scanGasStart - gasleft();
            if (gasSpent >= maxAggregateCheckGas) {
                gasBudgetExhausted = true;
                break;
            }

            uint256 remainingGasBudget = maxAggregateCheckGas - gasSpent;
            if (remainingGasBudget <= CHECK_GAS_RESERVE) {
                gasBudgetExhausted = true;
                break;
            }

            if (cursor >= upperBound) cursor = 1;
            JobState storage j = jobs[cursor];
            if (_isDue(j) && _canExecuteWithBilling(j.bot)) {
                gasSpent = scanGasStart - gasleft();
                if (gasSpent >= maxAggregateCheckGas) {
                    gasBudgetExhausted = true;
                    break;
                }
                remainingGasBudget = maxAggregateCheckGas - gasSpent;
                if (remainingGasBudget <= CHECK_GAS_RESERVE) {
                    gasBudgetExhausted = true;
                    break;
                }

                uint256 checkGas = j.gasLimitHint;
                if (checkGas == 0) checkGas = defaultGasLimitHint;
                if (checkGas > maxCheckUpkeepCallGas) checkGas = maxCheckUpkeepCallGas;
                uint256 availableCallGas = remainingGasBudget - CHECK_GAS_RESERVE;
                if (checkGas > availableCallGas) checkGas = availableCallGas;

                (bool ok, bytes memory out) = j.target.staticcall{gas: checkGas}(
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

        uint256 normalizedNextCursor = _normalizedCursor(cursor, upperBound);
        bool partialScan = gasBudgetExhausted || scanned < totalJobs;
        if (selected == 0) {
            if (!partialScan) return (false, bytes(""));
            return (
                true,
                abi.encode(normalizedNextCursor, new uint256[](0), new bytes[](0))
            );
        }

        uint256[] memory finalJobIds      = new uint256[](selected);
        bytes[]   memory finalPerformData = new bytes[](selected);
        for (uint256 i = 0; i < selected; ) {
            finalJobIds[i]      = candidateJobIds[i];
            finalPerformData[i] = candidatePerformData[i];
            unchecked { ++i; }
        }
        upkeepNeeded = true;
        performData  = abi.encode(normalizedNextCursor, finalJobIds, finalPerformData);
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
                // Strict mode: do not run jobs when billing prerequisites/funds are unavailable.
                if (!_canExecuteWithBilling(j.bot)) {
                    _pauseBotForBilling(j.bot);
                    unchecked { ++i; }
                    continue;
                }

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

        if (address(chainlinkFeed) == address(0) || address(fundToken) == address(0) || treasury == address(0)) {
            return;
        }

        uint256 price = DALiquidityLib.getPrice(chainlinkFeed, maxOracleDelay);
        if (price == 0) return;

        // The feed quotes fund tokens per native asset. The first conversion
        // produces an 18-decimal token amount, then normalizes to token units.
        uint256 rawCost18 = Math.mulDiv(gasUsed * tx.gasprice, price, priceDecimals);
        uint256 rawCost = Math.mulDiv(rawCost18, fundTokenDecimals, 1e18);
        uint256 markup   = (rawCost * platformMarkupBps) / 10000;
        uint256 totalFee = rawCost + markup;
        if (totalFee == 0) return;

        BotBillingState storage billing = botBilling[bot];
        _rolloverLegacyCredit(bot);

        // Deduct points first (if enabled), then fundToken for remainder
        uint256 fundTokenFee = totalFee;
        uint256 pointsDeducted = 0;
        
        if (billing.usePoint && address(doppiPoints) != address(0)) {
            pointsDeducted = _deductPointsForFee(bot, totalFee);
            if (pointsDeducted > 0) {
                uint256 pointValueInToken = _getPointValueInFundToken(pointsDeducted);
                if (pointValueInToken >= fundTokenFee) {
                    fundTokenFee = 0;
                } else {
                    fundTokenFee -= pointValueInToken;
                }
                emit PointsUsedForFee(jobId, bot, pointsDeducted, pointValueInToken);
            }
        }

        // Deduct remaining fee from fundToken credit
        if (fundTokenFee > 0) {
            if (billing.creditBalance < fundTokenFee) {
                fundTokenFee = billing.creditBalance;
            }

            if (fundTokenFee > 0) {
                billing.creditBalance -= fundTokenFee;

                IERC20 token = botCreditToken[bot];
                token.safeTransfer(treasury, fundTokenFee);

                if (billing.creditBalance == 0) {
                    delete botCreditToken[bot];
                }
            }
        }
        
        billing.totalGasFeePaid += totalFee;

        emit JobFeeCharged(jobId, bot, gasUsed, tx.gasprice, rawCost, fundTokenFee);

        // Check low credit threshold considering BOTH fundToken and available points value
        if (!billing.lowCreditPaused) {
            uint256 combinedValue = billing.creditBalance;
            if (billing.usePoint && address(doppiPoints) != address(0)) {
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
        if (readyPoints == 0) return 0;

        uint256 normalizedFee = Math.mulDiv(feeInFundToken, 1e18, fundTokenDecimals);

        // Calculate points needed from a whole-token BPS exchange rate.
        uint256 pointsNeeded;
        if (useDynamicPointPrice && doppiPointsPriceFeed != address(0)) {
            uint256 doppiPrice = _getDoppiTwapPriceSafe();

            if (doppiPrice == 0) return 0;
            pointsNeeded = Math.mulDiv(normalizedFee, 1e8, doppiPrice, Math.Rounding.Ceil);
        } else {
            if (doppiPointsExchangeRateBps == 0) return 0;
            pointsNeeded = Math.mulDiv(
                normalizedFee,
                10000,
                doppiPointsExchangeRateBps,
                Math.Rounding.Ceil
            );
        }

        pointsDeducted = readyPoints < pointsNeeded ? readyPoints : pointsNeeded;
        
        // Record the deduction in DoppiPoints to prevent double-counting
        if (pointsDeducted > 0 && address(doppiPoints) != address(0)) {
            doppiPoints.deductPointsForFee(billing.trader, pointsDeducted);
        }
    }

    /// @dev Get fundToken value of a specific number of points
    function _getPointValueInFundToken(uint256 numPoints) internal view returns (uint256) {
        uint256 normalizedValue;
        if (useDynamicPointPrice && doppiPointsPriceFeed != address(0)) {
            uint256 doppiPrice = _getDoppiTwapPriceSafe();
            if (doppiPrice == 0) return 0;
            normalizedValue = Math.mulDiv(numPoints, doppiPrice, 1e8);
        } else {
            if (doppiPointsExchangeRateBps == 0) return 0;
            normalizedValue = Math.mulDiv(numPoints, doppiPointsExchangeRateBps, 10000);
        }
        return Math.mulDiv(normalizedValue, fundTokenDecimals, 1e18);
    }

    /// @dev Get total value of a bot's available points in fundToken units
    function _getTotalPointsValueInFundToken(address bot) internal view returns (uint256) {
        BotBillingState memory billing = botBilling[bot];
        if (billing.trader == address(0)) return 0;
        
        (, uint256 readyPoints, ) = doppiPoints.getAllPointData(billing.trader);
        return _getPointValueInFundToken(readyPoints);
    }

    function _canExecuteWithBilling(address bot) internal view returns (bool) {

        if (address(chainlinkFeed) == address(0) || address(fundToken) == address(0) || treasury == address(0)) {
            return false;
        }
        
        if (DALiquidityLib.getPrice(chainlinkFeed, maxOracleDelay) == 0) return false;

        BotBillingState memory billing = botBilling[bot];
        uint256 combinedValue = address(botCreditToken[bot]) == address(fundToken)
            ? billing.creditBalance
            : 0;
        if (billing.usePoint && address(doppiPoints) != address(0)) {
            combinedValue += _getTotalPointsValueInFundToken(bot);
        }

        return combinedValue >= minCreditThreshold;
    }

    function _rolloverLegacyCredit(address bot) internal {
        BotBillingState storage billing = botBilling[bot];
        IERC20 creditToken = botCreditToken[bot];
        if (address(creditToken) == address(fundToken)) return;

        uint256 amount = billing.creditBalance;
        if (amount > 0) {
            if (address(creditToken) == address(0)) revert InvalidAddress();
            legacyCreditBalance[bot][address(creditToken)] += amount;
            billing.creditBalance = 0;
            emit LegacyCreditRolledOver(bot, address(creditToken), amount);
        }
        delete botCreditToken[bot];
    }

    function _pauseBotForBilling(address bot) internal {
        BotBillingState storage billing = botBilling[bot];
        if (!billing.lowCreditPaused) {
            billing.lowCreditPaused = true;
            _pauseAllJobsForBot(bot);
            emit BotLowCreditPaused(bot, billing.creditBalance);
        }
    }

    function _setChainlinkFeed(address _chainlinkFeed) internal {
        if (_chainlinkFeed != address(0) && _chainlinkFeed.code.length == 0) revert InvalidAddress();

        chainlinkFeed  = AggregatorV3Interface(_chainlinkFeed);
        priceDecimals  = _chainlinkFeed != address(0)
            ? 10 ** DALiquidityLib.getPriceDecimals(AggregatorV3Interface(_chainlinkFeed))
            : 1e8;

        emit ChainlinkFeedUpdated(_chainlinkFeed, priceDecimals);
    }

    /// @dev Never reverts; a misbehaving/misconfigured V3 pool must not block checkUpkeep or billing.
    function _getDoppiTwapPriceSafe() internal view returns (uint256) {
        try this.getDoppiTwapPrice() returns (uint256 twapPrice) {
            return twapPrice;
        } catch {
            return 0;
        }
    }

    /// @dev External wrapper so pool failures can be caught with try/catch.
    function getDoppiTwapPrice() external view returns (uint256) {
        return DALiquidityLib.getTWAPPrice(doppiPointsPriceFeed, 3600);
    }

    function _setFundToken(address _fundToken) internal {
        if (_fundToken == address(0) || _fundToken.code.length == 0) revert InvalidAddress();

        uint8 decimals = IERC20Metadata(_fundToken).decimals();
        if (decimals > 77) revert InvalidJob();

        fundToken = IERC20(_fundToken);
        fundTokenDecimals = 10 ** decimals;
        emit FundTokenUpdated(_fundToken);
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
            created.gasLimitHint        = defaultGasLimitHint;
            created.nextEligibleAt      = uint64(block.timestamp);

            emit JobRegistered(jobId, bot, module, target);
            return jobId;
        }

        JobState storage existing = jobs[jobId];
        existing.target = target;
        existing.active = true;
        if (existing.gasLimitHint        == 0) existing.gasLimitHint        = defaultGasLimitHint;
        if (existing.nextEligibleAt      == 0) existing.nextEligibleAt      = uint64(block.timestamp);

        emit JobUpdated(jobId, bot, module, target);
    }

    function _isDue(JobState storage j) internal view returns (bool) {
        if (j.bot == address(0) || j.target == address(0) || !j.active) return false;
        return block.timestamp >= j.nextEligibleAt;
    }

    function _recordFailure(uint256 jobId, JobState storage j) internal {
        unchecked { ++j.failCount; }
        emit JobExecutionFailed(jobId, j.bot, j.module);
        j.nextEligibleAt = uint64(block.timestamp + j.minInterval);
    }

    function _normalizedCursor(uint256 cursor, uint256 upperBound) internal pure returns (uint256) {
        if (upperBound <= 1) return 1;
        if (cursor == 0 || cursor >= upperBound) return 1;
        return cursor;
    }
}
