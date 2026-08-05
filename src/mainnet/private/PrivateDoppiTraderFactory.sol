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
import {IPrivateOpportunityAdmin} from "../../Interface/IPrivateOpportunityAdmin.sol";
import {IPrivateLiquidityAdmin} from "../../Interface/IPrivateLiquidityAdmin.sol";
import {IPrivateRouterAdmin, IPrivateRouterView} from "../../Interface/IPrivateRouterAdmin.sol";
import {ISetForwarder, ISetTraderFactory, IPrivateBot, IPrivateFeePoolAdmin, ISetPrivateAutomationHub} from "../../Interface/IPrivateBotInterfaces.sol";

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
    error PrivateAutomationHubNotSet();

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
    uint32 public defaultRatioLP = 5000; // 50% of capital go to LP

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
    
    constructor(
        IERC20  _assetA,
        IERC20  _assetB,
        address _sharedDoppiOffer,
        address _sharedDoppiPoints,
        address _mainFactory,
        address _traderBotImpl,
        address _coreImpl,
        address _opportunityImpl
    ) Ownable(msg.sender) {
        assetA                    = _assetA;
        assetB                    = _assetB;
        sharedDoppiPoints         = _sharedDoppiPoints;
        mainFactory               = _mainFactory;
        traderBotImplementation   = _traderBotImpl;
        doppiCoreImplementation   = _coreImpl;
        doppiOpportunityImplementation = _opportunityImpl;
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
        IPrivateCoreAdmin(privateCore).setOpportunityBot(privateOpportunity, true);

        if (defaultPrivateTreasury != address(0)) {
            IPrivateCoreAdmin(privateCore).setTreasury(defaultPrivateTreasury, defaultPrivateTreasuryFee);
            IPrivateFeePoolAdmin(defaultPrivateTreasury).setAuthorizedCore(privateCore, true);
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

        IPrivateBot(privateBot).setRatioLP(defaultRatioLP);

        if (privateAutomationHub != address(0)) {
            ISetPrivateAutomationHub(privateBot).setPrivateAutomationHub(privateAutomationHub);

            RegisterPrivateBotParams memory registerParams = RegisterPrivateBotParams({
                trader: msg.sender,
                bot: privateBot,
                core: privateCore,
                opportunity: privateOpportunity,
                liquidity: privateLiquidity,
                router: privateRouter,
                botId: botId
            });

            IPrivateAutomationHub(privateAutomationHub).registerPrivateBotJobs(registerParams);

            // Auto-set hub as the forwarder for all 4 modules (no further manual wiring needed)
            ISetForwarder(privateBot).setForwarderAddress(privateAutomationHub);
            ISetForwarder(privateCore).setForwarderAddress(privateAutomationHub);
            ISetForwarder(privateOpportunity).setForwarderAddress(privateAutomationHub);
            ISetForwarder(privateLiquidity).setForwarderAddress(privateAutomationHub);
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

    function setDefaultRatioLP(uint32 _ratioLP) external onlyOwner {
        defaultRatioLP = _ratioLP;
    }

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
    /// @dev Callable by the bot's validTrader EOA.
    function setPrivateBotForwarder(address bot, address forwarderAddress) external {
        _requireTrader(bot);
        if (forwarderAddress == address(0)) revert ZeroForwarder();

        ISetForwarder(botPrivateCore[bot]).setForwarderAddress(forwarderAddress);
        ISetForwarder(botPrivateOpportunity[bot]).setForwarderAddress(forwarderAddress);
        ISetForwarder(botPrivateLiquidity[bot]).setForwarderAddress(forwarderAddress);
        IPrivateBot(bot).setForwarderAddress(forwarderAddress);
    }

    // ─── IDoppiTraderFactory compat ───────────────────────────────────────────

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
        _requireTrader(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setEmergencyMode(_emergency);
    }

    function setPrivateCorePause(address bot) external {
        _requireTrader(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setPause();
    }

    function setPrivateCoreUnPause(address bot) external {
        _requireTrader(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setUnPause();
    }

    function setPrivateCoreMaxSwap(address bot, uint256 _maxSwap) external {
        _requireTrader(bot);
        IPrivateCoreAdmin(botPrivateCore[bot]).setMaxSwap(_maxSwap);
    }

    function setPrivateCoreTreasury(address bot, address _treasury, uint24 _treasury_fee) external onlyOwner {
        _requireRegisteredBot(bot);
        address core = botPrivateCore[bot];
        IPrivateCoreAdmin(core).setTreasury(_treasury, _treasury_fee);
    }

    
    function setPrivateLiquidityConfig(address bot) external {
        _requireTrader(bot);
        IPrivateLiquidityAdmin(botPrivateLiquidity[bot]).setConfig(lpConfig);
    }

    // ─── Private Opportunity wrappers ───────  ────────────────────────────────────────

    function setOpportunityBufferParams(address bot, uint16 _bufferCutBps, uint16 _minBufferBps) external {
        _requireTrader(bot);
        IPrivateOpportunityAdmin(botPrivateOpportunity[bot]).setOpportunityBufferParams(_bufferCutBps, _minBufferBps);
    }

    // ─── Private Router wrappers ───────────────────────────────────────────────

    function setPrivateRouterPause(address bot) external {
        _requireTrader(bot);
        IPrivateRouterAdmin(botPrivateRouter[bot]).setPause();
        IPrivateLiquidityAdmin(botPrivateLiquidity[bot]).setPause();
    }

    function setPrivateRouterUnPause(address bot) external {
        _requireTrader(bot);
        IPrivateRouterAdmin(botPrivateRouter[bot]).setUnPause();
        IPrivateLiquidityAdmin(botPrivateLiquidity[bot]).setUnPause();
    }

    function setPrivateRouterEmergencyMode(address bot, bool _emergency) external {
        _requireTrader(bot);
        IPrivateRouterAdmin(botPrivateRouter[bot]).setEmergencyMode(_emergency);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function getNextBotId()                      external view returns (uint32)  { return botRegistry.nextBotId; }

    // ─── Internal auth helpers ───────────────────────────────────────────────

    function _requireRegisteredBot(address bot) internal view {
        if (!botRegistry.isBot(bot)) revert NotRegisteredBot();
    }

    function _requireTrader(address bot) internal view {
        _requireRegisteredBot(bot);
        if (msg.sender != IPrivateBot(bot).validTrader()) revert NotAuthorized();
    }
}
