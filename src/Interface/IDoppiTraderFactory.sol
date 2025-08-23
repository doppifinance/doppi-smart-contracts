// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDoppiTraderFactory {
    function traderBotId(address) external view returns (uint256);
    function deployTraderBot(uint24[] calldata _weights) external returns (uint256);
    function isTraderBot(address _botAddr) external view returns (bool);
}
