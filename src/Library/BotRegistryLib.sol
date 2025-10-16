// BotRegistryLib.sol
library BotRegistryLib {
    struct BotRegistry {
        mapping(address => address[]) traderToBot;
        mapping(address => uint256) traderBotId;
        mapping(uint256 => address) traderBots;
        uint256 nextBotId;
    }

    function deployBot(
        BotRegistry storage registry,
        address trader,
        address newTrader
    ) internal returns (uint256) {
        uint256 id = registry.nextBotId++;
        registry.traderToBot[trader].push(newTrader);
        registry.traderBots[id] = newTrader;
        registry.traderBotId[newTrader] = id;
        return id;
    }

	function getIdByBot(BotRegistry storage registry, address botAddr) 
        internal view returns (uint256) {
        return registry.traderBotId[botAddr];
    }

	function getBotsById(BotRegistry storage registry, uint256 Id) 
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