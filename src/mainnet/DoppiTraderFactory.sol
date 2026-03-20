// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";
import {BotRegistryLib} from "../Library/BotRegistryLib.sol";
import {DoppiTrader} from "./DoppiTrader.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";


contract DoppiTraderFactory is Ownable, IDoppiTraderFactory {
    using Clones for address;

    using BotRegistryLib for BotRegistryLib.BotRegistry;

    // Add this line - the implementation contract address
    address public traderBotImplementation;

    IERC20 public immutable assetA;
    IERC20 public immutable assetB;

    address public doppiUpKeepManager;
    address public immutable doppiCore;
    address public immutable doppiLP;
    address public immutable doppiRouter;
    BotRegistryLib.BotRegistry internal botRegistry;
    bool public publicOpen = true;

    event BotDeployed(address indexed user, address traderBot, uint32 botId);
    
    constructor(
        IERC20 _assetA,
        IERC20 _assetB,
        address _da,
        address _daLP,
        address _router
    ) Ownable(msg.sender) {
        assetA = _assetA;
        assetB = _assetB;
        doppiCore = _da;
        doppiLP = _daLP;
        doppiRouter = _router;
        botRegistry.nextBotId = 1;

        // Deploy the implementation contract once
        traderBotImplementation = address(new DoppiTrader());
    }

    function deployTraderBot(uint24[] calldata _weights) external whenOpen returns (uint32) {
        require(msg.sender.code.length == 0, "contracts not allowed");
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
            doppiUpKeepManager,
            _weights
        );
        
        uint32 id = botRegistry.deployBot(msg.sender, traderBot);
        emit BotDeployed(msg.sender, traderBot, id);
        return id;
    }

	// Update implementation (only owner, for upgrades)
    function updateImplementation(address newImplementation) external onlyOwner {
        traderBotImplementation = newImplementation;
    }

    function setDoppiUpKeepManager(address _doppiUpKeepManager) external onlyOwner {
        doppiUpKeepManager = _doppiUpKeepManager;
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

    modifier whenOpen() {
        require(publicOpen == true, "not open");
        _;
    }
}