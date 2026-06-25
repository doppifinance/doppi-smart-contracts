// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BotRegistryLib} from "../../Library/BotRegistryLib.sol";
import {PrivateLiquidityDeployer} from "./PrivateLiquidityDeployer.sol";
import {IDoppiPoints} from "../../Interface/IDoppiPoints.sol";
import {IDoppiTraderFactory} from "../../Interface/IDoppiTraderFactory.sol";
import {ConfigParam} from "../DoppiLiquidityTypes.sol";
import {PrivateBotDeployer} from "./PrivateBotDeployer.sol";

interface ISetForwarder {
    function setForwarderAddress(address forwarderAddress) external;
}

interface ISetTraderFactory {
    function setDoppiTraderFactory(IDoppiTraderFactory _traderFactory) external;
}

interface IPrivateLiquidityAdmin {
    function setDoppiCore(address _doppiCore) external;
    function setDoppiTraderFactory(address _traderFactory) external;
    function setEntryPoint(address entryPoint, bool isValid) external;
}

interface IPrivateRouterAdmin {
    function setDoppiCore(address _doppiCore) external;
    function setPrivateMode(bool _privateMode) external;
    function setAllowedUser(address user, bool allowed) external;
}

interface IPrivateRouterView {
    function entryPointA() external view returns (address);
    function entryPointB() external view returns (address);
}

interface IPrivateBot {
    function validTrader() external view returns (address);
    function setForwarderAddress(address forwarderAddress) external;
}

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
    address public immutable doppiUpKeepManager;
    address public immutable mainFactory;

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

    constructor(
        IERC20  _assetA,
        IERC20  _assetB,
        address _sharedDoppiOffer,
        address _sharedDoppiPoints,
        address _doppiUpKeepManager,
        address _mainFactory,
        address _traderBotImpl,
        address _coreImpl,
        address _opportunityImpl,
        ConfigParam memory _lpConfig
    ) Ownable(msg.sender) {
        assetA                    = _assetA;
        assetB                    = _assetB;
        sharedDoppiPoints         = _sharedDoppiPoints;
        doppiUpKeepManager        = _doppiUpKeepManager;
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
            _sharedDoppiPoints,
            _doppiUpKeepManager
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
        ISetTraderFactory(privateCore).setDoppiTraderFactory(IDoppiTraderFactory(address(this)));

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

    /// @notice Update the forwarder on all components of a private bot in one call.
    /// @dev Callable by owner OR the bot's validTrader EOA.
    function setPrivateBotForwarder(address bot, address forwarderAddress) external {
        if (!botRegistry.isBot(bot))                                                    revert NotRegisteredBot();
        if (forwarderAddress == address(0))                                             revert ZeroForwarder();
        if (!(msg.sender == owner() || msg.sender == IPrivateBot(bot).validTrader()))   revert NotAuthorized();

        ISetForwarder(botPrivateCore[bot]).setForwarderAddress(forwarderAddress);
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

    // ─── View helpers ─────────────────────────────────────────────────────────

    function getPrivateCore(address _bot)        external view returns (address) { return botPrivateCore[_bot]; }
    function getPrivateOpportunity(address _bot) external view returns (address) { return botPrivateOpportunity[_bot]; }
    function getPrivateLiquidity(address _bot)   external view returns (address) { return botPrivateLiquidity[_bot]; }
    function getPrivateRouter(address _bot)      external view returns (address) { return botPrivateRouter[_bot]; }
    function getNextBotId()                      external view returns (uint32)  { return botRegistry.nextBotId; }
}
