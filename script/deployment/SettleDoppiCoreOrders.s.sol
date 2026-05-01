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
    address public constant DOPPI_CORE = 0x0Fd25f185431480dC698Bd01DD4F288972626cdA; 
    address public constant DOPPI_CORE_ETH = 0x278984A1527202a956641b8389B6568CA4FBC140; 
    address public constant DOPPI_POINTS = 0xc77bE67A9043d7aDE933DD5dD9d5Acc7154D90C5; 
    address public constant DOPPI_TRADER = 0x4F7554796137C8C9B0F76665a2e0dFD4aB1B2231; 
    address public constant DOPPI_REF = 0x35e1A18F0900982F0712B18e9125148C26Cf5D8E; 
    address public constant DOPPI_OFFER = 0xb4ED6eddc9361D164C0deDA1da5D02359f87DF18; 

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
