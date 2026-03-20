// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiTrader.sol";

contract PerformUpkeepDoppiTraderBot is Script {

    address public constant FORWARDER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; 
    address[] public bots;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORWARDER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        bots.push(address(0x176AF66c5A7067DD06c52D08b02DbCce2952a38F));
        // bots.push(address(0x344F302F0c7609FF9526AB7ceF2a9e62d8991431));
        // bots.push(address(0x163D6BA3de75cac4C2D57aeD5Ce94AcF5617f043));

        for(uint256 i=0; i< bots.length; i++){
            DoppiTrader doppiTrader = DoppiTrader(bots[i]);

            console.log(doppiTrader.s_forwarderAddress(), "==", FORWARDER);
            console.log("Bot:", bots[i], "Asset A balance:", doppiTrader.assetA().balanceOf(bots[i]));
            console.log("Bot:", bots[i], "Asset B balance:", doppiTrader.assetB().balanceOf(bots[i]));

            (bool upkeepNeeded, bytes memory performData) = doppiTrader.checkUpkeep("");
            console.log("Bot:", bots[i], "Upkeep needed:", upkeepNeeded);
            if (upkeepNeeded) {
                console.log("Performing upkeep for bot:", bots[i]);
                // Perform the upkeep
                doppiTrader.performUpkeep(performData);
                console.log("Upkeep performed successfully for bot:", bots[i]);
            } else {
                console.log("No upkeep needed at this time for bot:", bots[i]);
            }
        }
        vm.stopBroadcast();
    }
}
