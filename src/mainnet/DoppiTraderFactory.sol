// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";
import {BotRegistryLib} from "../Library/BotRegistryLib.sol";
import {DoppiTrader} from "./DoppiTrader.sol";

contract DoppiTraderFactory is Ownable, IDoppiTraderFactory {
    
    using BotRegistryLib for BotRegistryLib.BotRegistry;

    IERC20 public immutable assetA;
    IERC20 public immutable assetB;

    address public immutable doppiCore;
    address public immutable doppiLP;
    address public immutable doppiRouter;
    BotRegistryLib.BotRegistry internal botRegistry;

    event BotDeployed(address indexed user, address traderBot, uint256 botId);
    
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
    }

    function deployTraderBot(uint24[] calldata _weights) external returns (uint256) {
        DoppiTrader newTrader = new DoppiTrader(
            msg.sender, assetA, assetB, doppiLP, doppiRouter, doppiCore, _weights
        );
        uint256 id = botRegistry.deployBot(msg.sender, address(newTrader));
        emit BotDeployed(msg.sender, address(newTrader), id);
        return id;
    }

    function traderBotId(address _addr) external view returns (uint256) {
        return botRegistry.getIdByBot(_addr);
    }

    function traderBots(uint256 _id) external view returns (address) {
        return botRegistry.getBotsById(_id);
    }

    function getTraderBotByTrader(address _owner) external view returns (address[] memory) {
        return botRegistry.getBotsByTrader(_owner);
    }

    function isTraderBot(address _botAddr) external view returns (bool) {
        return botRegistry.isBot(_botAddr);
    }
}