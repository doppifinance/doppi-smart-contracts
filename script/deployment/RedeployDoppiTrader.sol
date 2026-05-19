// TestEnv.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiTrader.sol";
import "../../src/mainnet/DoppiUpkeepManager.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
import "../../src/Interface/IAutomationRegistrar.sol";
import "../../src/Interface/IAutomationRegistryConsumer.sol";

contract RedeployDoppiTrader is Script {

    address public constant DOPPI_FACTORY = address(0x095e4C543839c3C0403DbC5AA8acC259689A419C); 
    address public constant DOPPI_FACTORY_ETH = address(0xAB0a39Ee19797E273c94737100D811498Bf2e75E);
    
    // Chainlink Automation constants
    address constant CHAINLINK_RegistryConsumer = address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C);
    address constant CHAINLINK_Registrar = address(0xf671F60bCC964B309D22424886FF202807381B32);
    address constant CHAINLINK_LINK_USD = address(0xca236E327F629f9Fc2c30A4E95775EbF0B89fac8);
    address constant PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    address constant LINK_PEGGED_SWAP = address(0x1FCc3B22955e76Ca48bF025f1A6993685975Bb9e);
    address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
    address constant LINK = address(0x404460C6A5EdE2D891e8297795264fDe62ADBB75);
    address constant BNBLINK = address(0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD);
    address constant treasury = address(0x7E8c87Feb8D30706ca43A8049ee654875426A721);
    
    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAINNET");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // ==================== BTCB-USDT Pair ====================
        console.log("\n=== Redeploying BTCB-USDT Pair ===");
        DoppiTraderFactory doppiFactory = DoppiTraderFactory(DOPPI_FACTORY);
        
        // Deploy new DoppiTrader implementation
        address traderBotImplementation = address(new DoppiTrader());
        console.log("DoppiTrader BTCB-USDT implementation deployed to:", traderBotImplementation);
        
        // Deploy new DoppiUpkeepManager
        DoppiUpkeepManager doppiUpkeepManager = _deployDoppiUpkeepManager(doppiFactory);
        console.log("DoppiUpkeepManager BTCB-USDT deployed to:", address(doppiUpkeepManager));
        
        // Update factory with new implementation and upkeep manager
        doppiFactory.updateImplementation(traderBotImplementation);
        doppiFactory.setDoppiUpKeepManager(address(doppiUpkeepManager));
        console.log("Factory BTCB-USDT updated with new implementation and upkeep manager");
        
        // ==================== ETH-USDT Pair ====================
        console.log("\n=== Redeploying ETH-USDT Pair ===");
        DoppiTraderFactory doppiFactoryETH = DoppiTraderFactory(DOPPI_FACTORY_ETH);
        
        // Deploy new DoppiTrader implementation
        address traderBotImplementationETH = address(new DoppiTrader());
        console.log("DoppiTrader ETH-USDT implementation deployed to:", traderBotImplementationETH);
        
        // Deploy new DoppiUpkeepManager
        DoppiUpkeepManager doppiUpkeepManagerETH = _deployDoppiUpkeepManager(doppiFactoryETH);
        console.log("DoppiUpkeepManager ETH-USDT deployed to:", address(doppiUpkeepManagerETH));
        
        // Update factory with new implementation and upkeep manager
        doppiFactoryETH.updateImplementation(traderBotImplementationETH);
        doppiFactoryETH.setDoppiUpKeepManager(address(doppiUpkeepManagerETH));
        console.log("Factory ETH-USDT updated with new implementation and upkeep manager");

        vm.stopBroadcast();
    }

    function _deployDoppiUpkeepManager(DoppiTraderFactory _doppiFactory) internal returns (DoppiUpkeepManager) {

        console.log("Deploying DoppiUpkeepManager...");
        IAutomationRegistrar registrar = IAutomationRegistrar(CHAINLINK_Registrar);
        IAutomationRegistryConsumer registryConsumer = IAutomationRegistryConsumer(CHAINLINK_RegistryConsumer);

        DoppiUpkeepManager doppiUpkeepManager = new DoppiUpkeepManager(
            address(registryConsumer), 
            address(registrar), 
            CHAINLINK_LINK_USD, 
            address(PCSWAP_V3_ROUTER),
            LINK_PEGGED_SWAP,
            USDT, 
            LINK, // erc677 link
            BNBLINK, //bnb link
            address(_doppiFactory),
            treasury
        );
        
        console.log("registryConsumer:", address(registryConsumer));
        console.log("DoppiUpkeepManager deployed at:", address(doppiUpkeepManager));
        
        // Configure upkeep manager
        doppiUpkeepManager.setMaxDelay(10 minutes);
        doppiUpkeepManager.setDefault_Amount(80 ether);
        doppiUpkeepManager.setDefault_GasLimit(4_000_000);
        
        return doppiUpkeepManager;
    }    
}