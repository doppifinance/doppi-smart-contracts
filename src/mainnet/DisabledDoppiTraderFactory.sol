// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";

contract DisabledDoppiTraderFactory is IDoppiTraderFactory {
    function isTraderBot(address) external pure returns (bool) {
        return false;
    }

    function getTraderBotByTrader(address) external pure returns (address[] memory) {
        return new address[](0);
    }

    function traderBots(uint32) external pure returns (address) {
        return address(0);
    }

    function getNextBotId() external pure returns (uint32) {
        return 1;
    }

    function traderBotId(address) external pure returns (uint32) {
        return 0;
    }
}
