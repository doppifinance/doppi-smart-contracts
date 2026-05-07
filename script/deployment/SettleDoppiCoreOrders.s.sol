// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiTrader.sol";
import "../../src/mainnet/DoppiCoreTypes.sol";
import "../../src/mainnet/DoppiReferral.sol";
import "../../src/mainnet/DoppiOffer.sol";


contract SettleDoppiCoreOrders is Script {
    
    // Replace with your actual DoppiCore contract address
    address public constant DOPPI_CORE = 0xDca3163e914bf4Cb4D45FC81a863D881F43e9c7E; 
    address public constant DOPPI_CORE_ETH = 0x375ebC1196d84D817A8E3b58d662b3A4A71665b1; 
    address public constant DOPPI_POINTS = 0x4f912dC0a656122bAf396B1a3156f1cBBc3f5256; 
    address public constant DOPPI_TRADER = 0x4F7554796137C8C9B0F76665a2e0dFD4aB1B2231; 
    address public constant DOPPI_REF = 0xB23482c7144e5EcA26070d3F0012FB031164256C; 
    address public constant DOPPI_OFFER = 0xA8787E6F7c796eF644F734a6F4EF23B06032E4Ee; 

    // Replace with the admin address you want to impersonate
    address public constant ADMIN = 0x6Abb788569C3658b4C4798dEb914e6151D7aFc1C; // Add the admin address here
    address public constant trader = 0xB91a71FA558ec371eA09477c1D9f46E6AbA60719;
    address public constant trader2 = 0xB91a71FA558ec371eA09477c1D9f46E6AbA60719;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORWARDER_PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        _settleOrder(DOPPI_CORE);
        _settleOrder(DOPPI_CORE_ETH);
        
        vm.stopBroadcast();
    }

    function _settleOrder(address doppiCoreAddr) internal  {

        DoppiCore doppiCore = DoppiCore(doppiCoreAddr);
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        console.log("Upkeep needed:", upkeepNeeded);
        
        if (upkeepNeeded) {
            console.log("Performing upkeep...");
            
            // Perform the upkeep
            doppiCore.performUpkeep(performData);
            
            console.log("Upkeep performed successfully!");
        } else {
            console.log("No upkeep needed at this time");
        }
    }
    
}
