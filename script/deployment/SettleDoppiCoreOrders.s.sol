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
    address public constant DOPPI_CORE = 0x0C049C1A2c8DaB66cf44e36F654e93Dd951390b2; 
    address public constant DOPPI_CORE_ETH = 0x80def7B2FFc1f57e7f15E9ec3fA9Ca2ca4F5A240; 
    address public constant DOPPI_POINTS = 0x8AEbE38222f4E2261c907198aBfB30bFf41Ae6a0; 
    address public constant DOPPI_TRADER = 0x4F7554796137C8C9B0F76665a2e0dFD4aB1B2231; 
    address public constant DOPPI_REF = 0x5B45FC2D029611e2EE9ee87791BB2df81efA5a24; 
    address public constant DOPPI_OFFER = 0x083F2aFDafb76207eFFccabF7166D86504943a8E; 

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
