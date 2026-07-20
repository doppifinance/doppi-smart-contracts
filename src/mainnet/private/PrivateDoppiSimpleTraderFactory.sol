// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IDoppiTraderFactory} from "../../Interface/IDoppiTraderFactory.sol";
import {IDoppiPoints} from "../../Interface/IDoppiPoints.sol";
import {IPrivateAutomationHub} from "../../Interface/IPrivateAutomationHub.sol";
import {ISetForwarder} from "../../Interface/IPrivateBotInterfaces.sol";
import {BotRegistryLib} from "../../Library/BotRegistryLib.sol";
import {DoppiSimpleTrader} from "./DoppiSimpleTrader.sol";

contract PrivateDoppiSimpleTraderFactory is Ownable, IDoppiTraderFactory {
    using Clones for address;
    using BotRegistryLib for BotRegistryLib.BotRegistry;

    IERC20 public immutable assetA;
    IERC20 public immutable assetB;
    address public immutable doppiLP;
    address public immutable doppiOffer;
    address public immutable doppiPoints;
    address public traderBotImplementation;
    address public privateAutomationHub;
    address public defaultPrivateTreasury;
    uint16 public defaultPrivateTreasuryFee;

    BotRegistryLib.BotRegistry internal botRegistry;

    error NotTraderBot();

    event SimpleBotDeployed(address indexed trader, address indexed traderBot, uint32 botId);
    event PrivateAutomationHubUpdated(address indexed hub);
    event DefaultPrivateTreasuryUpdated(address indexed treasury, uint24 feeBps);

    constructor(
        IERC20 _assetA,
        IERC20 _assetB,
        address _doppiLP,
        address _doppiOffer,
        address _doppiPoints,
        address _traderBotImpl
    )
        Ownable(msg.sender)
    {
        assetA = _assetA;
        assetB = _assetB;
        doppiLP = _doppiLP;
        doppiOffer = _doppiOffer;
        doppiPoints = _doppiPoints;
        traderBotImplementation = _traderBotImpl;
        botRegistry.nextBotId = 1;
    }

    function deployPrivateBot(uint24[] calldata) external returns (uint32) {
        address traderBot = traderBotImplementation.clone();
        DoppiSimpleTrader(traderBot).initialize(msg.sender, assetA, assetB, doppiLP, doppiOffer, doppiPoints);

        uint32 id = botRegistry.deployBot(msg.sender, traderBot);

        IDoppiPoints(doppiPoints).registerCore(traderBot, address(this));

        if (privateAutomationHub != address(0)) {
            DoppiSimpleTrader(traderBot).setPrivateAutomationHub(privateAutomationHub);
            IPrivateAutomationHub(privateAutomationHub).registerSharedBotJob(msg.sender, traderBot, id);
            ISetForwarder(traderBot).setForwarderAddress(privateAutomationHub);
        }

        if (defaultPrivateTreasury != address(0)) {
            DoppiSimpleTrader(traderBot).setFeeConfig(defaultPrivateTreasury, defaultPrivateTreasuryFee);
        }

        emit SimpleBotDeployed(msg.sender, traderBot, id);
        return id;
    }

    function updateImplementation(address newImplementation) external onlyOwner {
        traderBotImplementation = newImplementation;
    }

    function setPrivateAutomationHub(address _hub) external onlyOwner {
        privateAutomationHub = _hub;
        emit PrivateAutomationHubUpdated(_hub);
    }

    function setDefaultPrivateTreasury(address _treasury, uint16 _treasuryFee) external onlyOwner {
        defaultPrivateTreasury = _treasury;
        defaultPrivateTreasuryFee = _treasuryFee;
        emit DefaultPrivateTreasuryUpdated(_treasury, _treasuryFee);
    }

    function setFeeConfig(address traderBot, address _feePool, uint16 _profitFeeBps) external onlyOwner {
        if (!botRegistry.isBot(traderBot)) revert NotTraderBot();
        DoppiSimpleTrader(traderBot).setFeeConfig(_feePool, _profitFeeBps);
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
