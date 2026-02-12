// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDoppiTraderFactory {
    function getTraderBotByTrader(address _owner) external view returns (address[] memory);
    function deployTraderBot(uint24[] calldata _weights) external returns (uint32);
    function isTraderBot(address _botAddr) external view returns (bool);
    function traderBots(uint32 _id) external view returns (address);
    function getNextBotId() external view returns (uint32);
}
