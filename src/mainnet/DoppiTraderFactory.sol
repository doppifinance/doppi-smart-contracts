// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";
import {BotRegistryLib} from "../Library/BotRegistryLib.sol";
import {DoppiTrader} from "./DoppiTrader.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiOffer} from "../Interface/IDoppiOffer.sol";
import {IDoppiPoints} from "../Interface/IDoppiPoints.sol";
import {IDoppiLiquidityRouter} from "../Interface/IDoppiLiquidityRouter.sol";
import {IPrivateAutomationHub} from "../Interface/IPrivateAutomationHub.sol";

interface ISetForwarder {
    function setForwarderAddress(address forwarderAddress) external;
}


contract DoppiTraderFactory is Ownable, IDoppiTraderFactory {
    using Clones for address;

    using BotRegistryLib for BotRegistryLib.BotRegistry;

    // Add this line - the implementation contract address
    address public traderBotImplementation;
    address public doppiCoreImplementation;
    address public doppiOpportunityImplementation;
    
    /// @notice Maps trader bot → its private DoppiCore
    mapping(address => address) public traderPrivateCore;
    /// @notice Maps trader bot → its private DoppiOpportunity
    mapping(address => address) public traderPrivateOpportunity;

    IERC20 public immutable assetA;
    IERC20 public immutable assetB;

    address public doppiUpKeepManager;
    address public immutable doppiCore;
    address public immutable doppiLP;
    address public immutable doppiRouter;
    address public immutable doppiOffer;
    address public immutable doppiPoints;
    address public privateAutomationHub;
    
    BotRegistryLib.BotRegistry internal botRegistry;
    
    event BotDeployed(address indexed user, address traderBot, uint32 botId);
    
    constructor(
        IERC20 _assetA,
        IERC20 _assetB,
        address _da,
        address _daLP,
        address _router,
        address _doppiOffer,
        address _doppiPoints
    ) Ownable(msg.sender) {
        assetA = _assetA;
        assetB = _assetB;
        doppiCore = _da;
        doppiLP = _daLP;
        doppiRouter = _router;
        doppiOffer = _doppiOffer;
        doppiPoints = _doppiPoints;
        botRegistry.nextBotId = 1;

        // Deploy the implementation contract once
        traderBotImplementation = address(new DoppiTrader());
    }

    function deployTraderBot(uint24[] calldata _weights) external returns (uint32) {
        // Use Clones to create minimal proxy
        address traderBot = Clones.clone(traderBotImplementation);
        
        // Initialize the cloned contract
        DoppiTrader(traderBot).initialize(
            msg.sender, 
            assetA, 
            assetB, 
            doppiLP, 
            doppiRouter, 
            doppiCore, 
            _weights
        );
        
        uint32 id = botRegistry.deployBot(msg.sender, traderBot);
        
        // Register with hub if available
        if (privateAutomationHub != address(0)) {
            try IPrivateAutomationHub(privateAutomationHub).registerSharedBotJob(
                msg.sender,
                traderBot,
                id
            ) {
                // Auto-set hub as the forwarder for shared bot trader job
                ISetForwarder(traderBot).setForwarderAddress(privateAutomationHub);
            } catch {
                // Fail silently if hub registration fails
            }
        }
        
        emit BotDeployed(msg.sender, traderBot, id);
        return id;
    }

	// Update implementation (only owner, for upgrades)
    function updateImplementation(address newImplementation) external onlyOwner {
        traderBotImplementation = newImplementation;
    }

    /// @notice Set implementation for private DoppiCore
    function setDoppiCoreImplementation(address newImplementation) external onlyOwner {
        doppiCoreImplementation = newImplementation;
    }

    /// @notice Set implementation for private DoppiOpportunity
    function setDoppiOpportunityImplementation(address newImplementation) external onlyOwner {
        doppiOpportunityImplementation = newImplementation;
    }

    /// @notice Get private core for a trader bot
    function getPrivateCore(address _traderBot) external view returns (address) {
        return traderPrivateCore[_traderBot];
    }

    /// @notice Get private opportunity for a trader bot
    function getPrivateOpportunity(address _traderBot) external view returns (address) {
        return traderPrivateOpportunity[_traderBot];
    }

    function setDoppiUpKeepManager(address _doppiUpKeepManager) external onlyOwner {
        // Deprecated: use setPrivateAutomationHub instead for new deployments
        doppiUpKeepManager = _doppiUpKeepManager;
    }

    function setPrivateAutomationHub(address _hub) external onlyOwner {
        privateAutomationHub = _hub;
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

    function getNextBotId() external view returns (uint32) {
        return botRegistry.nextBotId;
    }

    function isTraderBot(address _botAddr) external view returns (bool) {
        return botRegistry.isBot(_botAddr);
    }
}