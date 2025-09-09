// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";
import {DoppiCore} from "./DoppiCore.sol";
import {DoppiConfig} from "./DoppiConfig.sol";
import {DoppiLiquidity} from "./DoppiLiquidity.sol";
import {IDoppiLiquidityRouter} from "../Interface/IDoppiLiquidityRouter.sol";
import {DoppiTrader} from "./DoppiTrader.sol";
import "forge-std/console.sol";

contract DoppiTraderFactory is Ownable, IDoppiTraderFactory {
    IERC20 public immutable assetA;
    IERC20 public immutable assetB;

    DoppiCore public immutable doppiCore;
    DoppiLiquidity public immutable doppiLP;
    IDoppiLiquidityRouter public immutable doppiRouter;
    DoppiTrader[] public traderBots;
    address public immutable DEFAULT_FORWARDER_ADDRESS;

    mapping(address => uint256) public traderBotId;

    constructor(
        IERC20 _assetA,
        IERC20 _assetB,
        DoppiCore _da,
        DoppiLiquidity _daLP,
        IDoppiLiquidityRouter _router,
        address _forwarderAddress
    ) Ownable(msg.sender) {
        assetA = _assetA;
        assetB = _assetB;
        doppiCore = _da;
        doppiLP = _daLP;
        doppiRouter = _router;
        DEFAULT_FORWARDER_ADDRESS = _forwarderAddress;
        traderBots.push(DoppiTrader(address(0)));
    }

    function deployTraderBot(uint24[] calldata _weights) external returns (uint256) {
        uint256 id = traderBots.length;
        DoppiTrader newTrader = new DoppiTrader(
            address(this), msg.sender, assetA, assetB, doppiLP, doppiRouter, doppiCore, _weights
        );
        newTrader.setForwarderAddress(DEFAULT_FORWARDER_ADDRESS);
        traderBots.push(newTrader);
        traderBotId[address(newTrader)] = id;
        return id;
    }

    function setTraderBotForwarderAddress(address _forwarderAddress, address _botAddr) external onlyOwner {
        uint256 id = traderBotId[_botAddr];
        DoppiTrader traderBot = traderBots[id];
        traderBot.setForwarderAddress(_forwarderAddress);
    }

    function setTraderBotDoppiConfig(address _doppiConfig, address _botAddr) external onlyOwner {
        uint256 id = traderBotId[_botAddr];
        DoppiTrader traderBot = traderBots[id];
        traderBot.setDoppiConfig(DoppiConfig(_doppiConfig));
    }

    function isTraderBot(address _botAddr) external view returns (bool) {
        return traderBotId[_botAddr] > 0;
    }
}