// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiUpkeepManager.sol";
import "../../src/mainnet/DoppiOffer.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiLiquidity.sol";
import "../../src/mainnet/DoppiOpportunity.sol";
// import {AutomationCompatibleInterface} from "../../src/Interface/AutomationCompatibleInterface.sol";
import "../../src/Interface/IAutomationRegistryConsumer.sol";

contract ChainlinkAutomation is Script {

    IAutomationRegistryConsumer public registryConsumer;
    uint256 upkeepId = 7887707695776849999432413663142534865625201528489189477999948805364768675837;
    address constant CHAINLINK_RegistryConsumer = address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C);
    address constant CHAINLINK_Registrar = address(0xf671F60bCC964B309D22424886FF202807381B32);
    address payable DOPPI_UPKEEP = payable(0xA2918099Dd898b537EAA60476E809Bdaa849bb2a);


    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        registryConsumer = IAutomationRegistryConsumer(CHAINLINK_RegistryConsumer);
        
        IAutomationRegistryConsumer.UpkeepInfo memory result = registryConsumer.getUpkeep(upkeepId);
        console.log("target: ", result.target);
        console.log("balance: ", result.balance);
        console.log("admin: ", result.admin);
        console.log("maxValidBlocknumber: ", result.maxValidBlocknumber);
        console.log("lastPerformBlockNumber: ", result.lastPerformBlockNumber);
        console.log("amountSpent: ", result.amountSpent);
        console.log("paused: ", result.paused);
        console.log("forwarder: ", result.forwarder);
        
        address forw = registryConsumer.getForwarder(upkeepId);
        console.log("getForwarder: ", forw);


        DoppiUpkeepManager doppiupkeep = DoppiUpkeepManager(DOPPI_UPKEEP);
        console.log("getUpkeepIdByBot:", doppiupkeep.getUpkeepIdByBot(address(0x4F7554796137C8C9B0F76665a2e0dFD4aB1B2231)));
        
        (uint96 fee, address trader) = doppiupkeep.getUnPaidDoppiFee(7887707695776849999432413663142534865625201528489189477999948805364768675837);

        console.log("getUnPaidDoppiFee:", fee, trader);

        vm.stopBroadcast();
    }
    
    
}