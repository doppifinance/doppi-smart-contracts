// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
library BotRegistryLib {
    struct BotRegistry {
        mapping(address => address[]) traderToBot;
        mapping(address => uint32) traderBotId;
        mapping(uint32 => address) traderBots;
        uint32 nextBotId;
    }

    function deployBot(
        BotRegistry storage registry,
        address trader,
        address newTrader
    ) internal returns (uint32) {
        uint32 id = registry.nextBotId++;
        registry.traderToBot[trader].push(newTrader);
        registry.traderBots[id] = newTrader;
        registry.traderBotId[newTrader] = id;
        return id;
    }

	function getIdByBot(BotRegistry storage registry, address botAddr) 
        internal view returns (uint32) {
        return registry.traderBotId[botAddr];
    }

	function getBotsById(BotRegistry storage registry, uint32 Id) 
        internal view returns (address) {
        return registry.traderBots[Id];
    }

    function getBotsByTrader(BotRegistry storage registry, address trader) 
        internal view returns (address[] memory) {
        return registry.traderToBot[trader];
    }

    function isBot(BotRegistry storage registry, address botAddr) internal view returns (bool) {
        return registry.traderBotId[botAddr] > 0;
    }
}