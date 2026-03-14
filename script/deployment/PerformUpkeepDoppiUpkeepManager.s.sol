// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiUpkeepManager.sol";

contract PerformUpkeepDoppiUpkeepManager is Script {

    address public constant DOPPI_UPKEEP = 0x0909645Fb7a98594836279d08c45C5b4f946c2A4; 
    address public constant FORWARDER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; 

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORWARDER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        DoppiUpkeepManager doppiUpkeepManager = DoppiUpkeepManager(DOPPI_UPKEEP);

        (bool upkeepNeeded, bytes memory performData) = doppiUpkeepManager.checkUpkeep("");
        
        console.log("Upkeep needed:", upkeepNeeded);
        
        if (upkeepNeeded) {
            console.log("Performing upkeep...");
            
            // Perform the upkeep
            doppiUpkeepManager.performUpkeep(performData);
            
            console.log("Upkeep performed successfully!");
        } else {
            console.log("No upkeep needed at this time");
        }

        uint256 keepId = 102390274110166331921383567080599101690013628011807524703421743174776153357678;
        address bot = address(0x234765F220DB7F6C062Bc552AAfe0005Cc8Ce04a);

        console.log("Upkeep balance after performing upkeep:", doppiUpkeepManager.getUpkeepBalance(keepId));
        console.log("Upkeep ID for bot:", doppiUpkeepManager.getUpkeepIdByBot(bot));
        console.log("registryConsumer address:", address(doppiUpkeepManager.registryConsumer()));
        

        vm.stopBroadcast();

        
    }
}
