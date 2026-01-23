// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiUpkeepManager.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";

contract RedeployDoppiUpkeepManager is Script {

    address public constant DOPPI_FACTORY = address(0x2044A8671c068fcDf44f9a24C872e9eB3a935eA2); 
    address constant LINK = address(0x404460C6A5EdE2D891e8297795264fDe62ADBB75);
    address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
    address constant BTC = address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    address constant BNBLINK = address(0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD);
    address constant CHAINLINK_RegistryConsumer = address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C);
    address constant CHAINLINK_Registrar = address(0xf671F60bCC964B309D22424886FF202807381B32);
    address constant CHAINLINK_LINK_USD = address(0xca236E327F629f9Fc2c30A4E95775EbF0B89fac8);
    address constant LINK_PEGGED_SWAP = address(0x1FCc3B22955e76Ca48bF025f1A6993685975Bb9e);
    address constant PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    address constant PCSWAP_V3_QUOTER = address(0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997);
    address constant PCSWAP_V3Pool = address(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);
    address constant treasury = address(0x5dE88c6A183E8BE8A630dfa6BAc1926e1e323CF1);
    
    
    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAINNET");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get DoppiCore instance
        DoppiTraderFactory doppiFactory = DoppiTraderFactory(DOPPI_FACTORY);
        DoppiUpkeepManager doppiUpkeepManager = _deployDoppiUpkeepManager(doppiFactory);
        
        console.log("DoppiUpkeepManager:", address(doppiUpkeepManager));
        
        vm.stopBroadcast();
    }

    function _deployDoppiUpkeepManager(DoppiTraderFactory _doppiFactory) internal returns (DoppiUpkeepManager) {

        console.log("Deploying DoppiUpkeepManager...");
        IAutomationRegistrar registrar = IAutomationRegistrar(CHAINLINK_Registrar);
        IAutomationRegistryConsumer registryConsumer = IAutomationRegistryConsumer(CHAINLINK_RegistryConsumer);
        // MockRegistryConsumer registryConsumer = new MockRegistryConsumer();

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
        
        console.log("registryConsumer deployed at:", address(registryConsumer));
        console.log("DoppiUpkeepManager deployed at:", address(doppiUpkeepManager));
        // doppiUpkeepManager.setMaxDelay(10 minutes);
        doppiUpkeepManager.setDefault_Amount(50 ether);
        doppiUpkeepManager.setDefault_GasLimit(2_500_000);
        _doppiFactory.setDoppiUpKeepManager(address(doppiUpkeepManager));
        return doppiUpkeepManager;
    }  
    
}