// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";
import {DoppiCore} from "./DoppiCore.sol";
import {DoppiLiquidity} from "./DoppiLiquidity.sol";
import {IDoppiLiquidityRouter} from "../Interface/IDoppiLiquidityRouter.sol";
import {DoppiTrader} from "./DoppiTrader.sol";
import "forge-std/console.sol";

contract DoppiTraderFactory is Ownable, IDoppiTraderFactory {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 assetA; // eg. USDT
    IERC20 assetB; // eg. BTC

    DoppiCore public doppiCore;
    DoppiLiquidity public doppiLP;
    IDoppiLiquidityRouter public doppiRouter;
    DoppiTrader[] public traderBots;
    address public DEFAULT_FORWARDER_ADDRESS;

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
        // Remove index 0, so id == 0 is invalid
        traderBots.push(DoppiTrader(address(0)));
    }

    function deployTraderBot(uint24[] calldata _weights) external returns (uint256) {
        uint256 id = traderBots.length;
        DoppiTrader newTrader = new DoppiTrader(
            address(this), assetA, assetB, doppiLP, doppiRouter, doppiCore, _weights
        );
        newTrader.setForwarderAddress(DEFAULT_FORWARDER_ADDRESS);
        newTrader.transferOwnership(msg.sender);
        traderBots.push(newTrader);
        traderBotId[address(newTrader)] = id;
        return id;
    }

    function isTraderBot(address _botAddr) public view returns (bool) {
        return traderBotId[_botAddr] > 0;
    }
}
