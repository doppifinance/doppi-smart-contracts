// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDoppiTraderFactory {
    function getTraderBotByTrader(address _owner) external view returns (address[] memory);
    function deployTraderBot(uint24[] calldata _weights) external returns (uint256);
    function isTraderBot(address _botAddr) external view returns (bool);
    function traderBots(uint256 _id) external view returns (address);
}
