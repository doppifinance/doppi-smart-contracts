// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BotRegistryLib} from "../../Library/BotRegistryLib.sol";
import {PrivateLiquidityDeployer} from "./PrivateLiquidityDeployer.sol";
import {IDoppiPoints} from "../../Interface/IDoppiPoints.sol";
import {IDoppiTraderFactory} from "../../Interface/IDoppiTraderFactory.sol";
import {IPrivateAutomationHub} from "../../Interface/IPrivateAutomationHub.sol";
import {ConfigParam} from "../DoppiLiquidityTypes.sol";
import {RegisterPrivateBotParams, PrivateBotJobIds} from "./PrivateAutomationHubTypes.sol";
import {PrivateBotDeployer} from "./PrivateBotDeployer.sol";
import {IPrivateCoreAdmin} from "../../Interface/IPrivateCoreAdmin.sol";
import {IPrivateLiquidityAdmin} from "../../Interface/IPrivateLiquidityAdmin.sol";
import {IPrivateRouterAdmin, IPrivateRouterView} from "../../Interface/IPrivateRouterAdmin.sol";
import {ISetForwarder, ISetTraderFactory, IPrivateBot, IPrivateFeePoolAdmin} from "../../Interface/IPrivateBotInterfaces.sol";

/**
 * @title PrivateDoppiTraderFactory
 * @notice Registry and coordinator for private trader bots.
 *         All heavy deployment logic lives in PrivateBotDeployer to stay under EIP-170.
 */
contract PrivateDoppiTraderFactory is Ownable, IDoppiTraderFactory {
    using BotRegistryLib for BotRegistryLib.BotRegistry;

    error CoreImplementationNotSet();
    error OpportunityImplementationNotSet();
    error NotRegisteredBot();
    error ZeroForwarder();
    error NotAuthorized();

    // Implementation contracts (cloned per bot)
    address public traderBotImplementation;
    address public doppiCoreImplementation;
    address public doppiOpportunityImplementation;

    // Shared immutable state
    IERC20  public immutable assetA;
    IERC20  public immutable assetB;
    address public immutable sharedDoppiPoints;
    address public immutable mainFactory;

    // Default treasury config for newly deployed private cores
    address public defaultPrivateTreasury;
    uint24 public defaultPrivateTreasuryFee;
    address public privateAutomationHub;

    /// @notice Dedicated deployers that hold the heavy deployment bytecode.
    PrivateLiquidityDeployer public immutable liquidityDeployer;
    /// @notice Dedicated deployer that holds all deployment bytecode
    PrivateBotDeployer public immutable botDeployer;

    // LP configuration for new bots
    ConfigParam public lpConfig;

    // Bot registry
    BotRegistryLib.BotRegistry internal botRegistry;

    // Per-bot component addresses
    mapping(address => address) public botPrivateCore;
    mapping(address => address) public botPrivateOpportunity;
    mapping(address => address) public botPrivateLiquidity;
    mapping(address => address) public botPrivateRouter;

    event PrivateBotDeployed(
        address indexed trader,
        address indexed traderBot,
        address indexed privateCore,
        address privateOpportunity,
        address privateLiquidity,
        address privateRouter,
        uint32 botId
    );
    event DefaultPrivateTreasuryUpdated(address indexed treasury, uint24 feeBps);
    event PrivateAutomationHubUpdated(address indexed hub);
    event PrivateBotJobsRegistered(
        address indexed hub,
        address indexed bot,
        uint256 traderJobId,
        uint256 coreJobId,
        uint256 opportunityJobId,
        uint256 liquidityJobId
    );
    event PrivateBotJobsRegistrationSkipped(address indexed bot, address indexed hub);

    constructor(
        IERC20  _assetA,
        IERC20  _assetB,
        address _sharedDoppiOffer,
        address _sharedDoppiPoints,
        address _mainFactory,
        address _traderBotImpl,
        address _coreImpl,
        address _opportunityImpl,
        ConfigParam memory _lpConfig
    ) Ownable(msg.sender) {
        assetA                    = _assetA;
        assetB                    = _assetB;
        sharedDoppiPoints         = _sharedDoppiPoints;
        mainFactory               = _mainFactory;
        traderBotImplementation   = _traderBotImpl;
        doppiCoreImplementation   = _coreImpl;
        doppiOpportunityImplementation = _opportunityImpl;
        lpConfig                  = _lpConfig;
        botRegistry.nextBotId     = 1;

        liquidityDeployer = new PrivateLiquidityDeployer(_assetA, _assetB);

        // Deploy the stateless deployer once; it will only accept calls from this factory.
        botDeployer = new PrivateBotDeployer(
            _assetA,
            _assetB,
            _sharedDoppiOffer,
            _sharedDoppiPoints
        );
    }

    // ─── Deployment ──────────────────────────────────────────────────────────

    function deployPrivateBot(uint24[] calldata _weights) public returns (uint32) {
        if (doppiCoreImplementation        == address(0)) revert CoreImplementationNotSet();
        if (doppiOpportunityImplementation == address(0)) revert OpportunityImplementationNotSet();

        uint32 pendingBotId = botRegistry.nextBotId;

        (address privateLiquidity, address privateRouter) = liquidityDeployer.deploy(lpConfig, pendingBotId);

        (address privateBot, address privateCore, address privateOpportunity) =
            botDeployer.deploy(
                traderBotImplementation,
                doppiCoreImplementation,
                doppiOpportunityImplementation,
                msg.sender,
                privateLiquidity,
                privateRouter,
                _weights
            );

        // Core owner is this factory; owner-only wiring must happen from factory context.
        ISetTraderFactory(privateCore).setDoppiTraderFactory(address(this));

        if (defaultPrivateTreasury != address(0)) {
            IPrivateCoreAdmin(privateCore).setTreasury(defaultPrivateTreasury, defaultPrivateTreasuryFee);
            if (defaultPrivateTreasury.code.length > 0) {
                // Optional integration with DoppiFeePool-like contracts.
                try IPrivateFeePoolAdmin(defaultPrivateTreasury).setAuthorizedCore(privateCore, true) {
                    // no-op
                } catch {
                    // no-op
                }
            }
        }

        // The deployers have already transferred ownership back to the factory, so these are safe.
        IPrivateLiquidityAdmin(privateLiquidity).setDoppiCore(privateCore);
        IPrivateRouterAdmin(privateRouter).setDoppiCore(privateCore);
        IPrivateRouterAdmin(privateRouter).setPrivateMode(true);
        IPrivateRouterAdmin(privateRouter).setAllowedUser(privateBot, true);
        IPrivateLiquidityAdmin(privateLiquidity).setEntryPoint(IPrivateRouterView(privateRouter).entryPointA(), true);
        IPrivateLiquidityAdmin(privateLiquidity).setEntryPoint(IPrivateRouterView(privateRouter).entryPointB(), true);
        IPrivateLiquidityAdmin(privateLiquidity).setEntryPoint(privateBot, true);
        IPrivateLiquidityAdmin(privateLiquidity).setDoppiTraderFactory(address(this));

        // registerCore requires msg.sender to have registrar role in DoppiPoints
        IDoppiPoints(sharedDoppiPoints).registerCore(privateCore, address(this));

        botPrivateCore[privateBot]        = privateCore;
        botPrivateOpportunity[privateBot] = privateOpportunity;
        botPrivateLiquidity[privateBot]   = privateLiquidity;
        botPrivateRouter[privateBot]      = privateRouter;

        uint32 botId = botRegistry.deployBot(msg.sender, privateBot);

        if (privateAutomationHub != address(0)) {
            RegisterPrivateBotParams memory registerParams = RegisterPrivateBotParams({
                trader: msg.sender,
                bot: privateBot,
                core: privateCore,
                opportunity: privateOpportunity,
                liquidity: privateLiquidity,
                router: privateRouter,
                botId: botId
            });

            try IPrivateAutomationHub(privateAutomationHub).registerPrivateBotJobs(registerParams)
                returns (PrivateBotJobIds memory jobIds)
            {
                emit PrivateBotJobsRegistered(
                    privateAutomationHub,
                    privateBot,
                    jobIds.traderJobId,
                    jobIds.coreJobId,
                    jobIds.opportunityJobId,
                    jobIds.liquidityJobId
                );

                // Auto-set hub as the forwarder for all 4 modules (no further manual wiring needed)
                ISetForwarder(privateBot).setForwarderAddress(privateAutomationHub);
                ISetForwarder(privateCore).setForwarderAddress(privateAutomationHub);
                ISetForwarder(privateOpportunity).setForwarderAddress(privateAutomationHub);
                ISetForwarder(privateLiquidity).setForwarderAddress(privateAutomationHub);
            } catch {
                emit PrivateBotJobsRegistrationSkipped(privateBot, privateAutomationHub);
            }
        }

        emit PrivateBotDeployed(
            msg.sender,
            privateBot,
            privateCore,
            privateOpportunity,
            privateLiquidity,
            privateRouter,
            botId
        );

        return botId;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setImplementations(
        address _traderBotImpl,
        address _coreImpl,
        address _opportunityImpl
    ) external onlyOwner {
        traderBotImplementation        = _traderBotImpl;
        doppiCoreImplementation        = _coreImpl;
        doppiOpportunityImplementation = _opportunityImpl;
    }

    function setLPConfig(ConfigParam calldata _lpConfig) external onlyOwner {
        lpConfig = _lpConfig;
    }

    function setDefaultPrivateTreasury(address _treasury, uint24 _treasuryFee) external onlyOwner {
        defaultPrivateTreasury = _treasury;
        defaultPrivateTreasuryFee = _treasuryFee;
        emit DefaultPrivateTreasuryUpdated(_treasury, _treasuryFee);
    }

    function setPrivateAutomationHub(address _hub) external onlyOwner {
        privateAutomationHub = _hub;
        emit PrivateAutomationHubUpdated(_hub);
    }

    /// @notice Update the forwarder on all components of a private bot in one call.
    /// @dev Callable by owner OR the bot's validTrader EOA.
    function setPrivateBotForwarder(address bot, address forwarderAddress) external {
        _requireOwnerOrTrader(bot);
        if (forwarderAddress == address(0)) revert ZeroForwarder();

        ISetForwarder(botPrivateCore[bot]).setForwarderAddress(forwarderAddress);
        ISetForwarder(botPrivateOpportunity[bot]).setForwarderAddress(forwarderAddress);
        ISetForwarder(botPrivateLiquidity[bot]).setForwarderAddress(forwarderAddress);
        IPrivateBot(bot).setForwarderAddress(forwarderAddress);
    }

    // ─── IDoppiTraderFactory compat ───────────────────────────────────────────

    function deployTraderBot(uint24[] calldata _weights) external returns (uint32) {
        return deployPrivateBot(_weights);
    }

    function traderBotId(address _addr) external view returns (uint32) {
        return botRegistry.getIdByBot(_addr);
    }

    function traderBots(uint32 _id) external view returns (address) {
        return botRegistry.getBotsById(_id);
    }

    function getTraderBotByTrader(address _owner) external view returns (address[] memory) {
        return botRegistry.getBotsByTrader(_owner);
    }

    function isTraderBot(address _botAddr) external view returns (bool) {
        return botRegistry.isBot(_botAddr);
    }

    // ─── Private Core wrappers ───────────────────────────────────────────────

    function setPrivateCoreEmergencyMode(address bot, bool _emergency) external {
        _requireOwnerOrTrader(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setEmergencyMode(_emergency);
    }

    function setPrivateCorePause(address bot) external {
        _requireOwnerOrTrader(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setPause();
    }

    function setPrivateCoreUnPause(address bot) external {
        _requireOwnerOrTrader(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setUnPause();
    }

    function setPrivateCoreUpkeepsPerCheck(address bot, uint16 _percheck) external {
        _requireOwnerOrTrader(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setUpkeeps_per_check(_percheck);
    }

    function setPrivateCoreMinOrder(address bot, uint256 _minOrderA, uint256 _minOrderB) external {
        _requireOwnerOrTrader(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setMinOrder(_minOrderA, _minOrderB);
    }

    function setPrivateCoreMaxSwap(address bot, uint256 _maxSwap) external {
        _requireOwnerOrTrader(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setMaxSwap(_maxSwap);
    }

    function setPrivateCoreAPRTolerance(address bot, uint16 _toleranceBP) external {
        _requireOwnerOrTrader(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setAPRTolerance(_toleranceBP);
    }

    function setPrivateCoreTreasury(address bot, address _treasury, uint24 _treasury_fee) external onlyOwner {
        _requireRegisteredBot(bot);
        address core = botPrivateCore[bot];
        IPrivateCoreAdmin(core).setTreasury(_treasury, _treasury_fee);
    }

    function setPrivateCoreOpportunityBot(address bot, address _opportunityBot, bool _status) external onlyOwner {
        _requireRegisteredBot(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setOpportunityBot(_opportunityBot, _status);
    }

    function setPrivateCoreTraderFactory(address bot, IDoppiTraderFactory _traderFactory) external onlyOwner {
        _requireRegisteredBot(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setDoppiTraderFactory(address(_traderFactory));
    }

    // ─── Private Router wrappers ───────────────────────────────────────────────

    function setPrivateRouterPause(address bot) external {
        _requireOwnerOrTrader(bot);
        IPrivateRouterAdmin(botPrivateRouter[bot]).setPause();
    }

    function setPrivateRouterUnPause(address bot) external {
        _requireOwnerOrTrader(bot);
        IPrivateRouterAdmin(botPrivateRouter[bot]).setUnPause();
    }

    function setPrivateRouterEmergencyMode(address bot, bool _emergency) external {
        _requireOwnerOrTrader(bot);
        IPrivateRouterAdmin(botPrivateRouter[bot]).setEmergencyMode(_emergency);
    }

    function setPrivateRouterAllowedUser(address bot, address user, bool allowed) external onlyOwner {
        _requireRegisteredBot(bot);
        IPrivateRouterAdmin(botPrivateRouter[bot]).setAllowedUser(user, allowed);
    }

    function setPrivateRouterMode(address bot, bool _privateMode) external onlyOwner {
        _requireRegisteredBot(bot);
        IPrivateRouterAdmin(botPrivateRouter[bot]).setPrivateMode(_privateMode);
    }

    function setPrivateRouterCore(address bot, address _doppiCore) external onlyOwner {
        _requireRegisteredBot(bot);
        IPrivateRouterAdmin(botPrivateRouter[bot]).setDoppiCore(_doppiCore);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function getPrivateCore(address _bot)        external view returns (address) { return botPrivateCore[_bot]; }
    function getPrivateOpportunity(address _bot) external view returns (address) { return botPrivateOpportunity[_bot]; }
    function getPrivateLiquidity(address _bot)   external view returns (address) { return botPrivateLiquidity[_bot]; }
    function getPrivateRouter(address _bot)      external view returns (address) { return botPrivateRouter[_bot]; }
    function getNextBotId()                      external view returns (uint32)  { return botRegistry.nextBotId; }

    // ─── Internal auth helpers ───────────────────────────────────────────────

    function _requireRegisteredBot(address bot) internal view {
        if (!botRegistry.isBot(bot)) revert NotRegisteredBot();
    }

    function _requireOwnerOrTrader(address bot) internal view {
        _requireRegisteredBot(bot);
        if (!(msg.sender == owner() || msg.sender == IPrivateBot(bot).validTrader())) revert NotAuthorized();
    }
}
