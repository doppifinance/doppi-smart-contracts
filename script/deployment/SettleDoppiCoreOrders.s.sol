// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiTrader.sol";
import "../../src/mainnet/DoppiCoreTypes.sol";


contract SettleDoppiCoreOrders is Script {
    
    // Replace with your actual DoppiCore contract address
    address public constant DOPPI_CORE = 0x2FE09E2f6fe5D7270749b191ddE88Fb096A614A0; // Add your DoppiCore address here
    address public constant DOPPI_POINTS = 0x0F30b6db7ffFe0D465f989BFcC8a73A7cc4D69E9; // Add your DoppiCore address here
    address public constant DOPPI_TRADER = 0x1Fbe951f061779e09CC2108A36B363cF22f8a161; // Add your DoppiCore address here
    
    // Replace with the admin address you want to impersonate
    address public constant ADMIN = 0x5D450b7A2bAFbc071cF1313099C3744f91c3BC24; // Add the admin address here
    address public constant trader = 0xaD8234bC07168d9f7E49c3780e4b5fefa6620f8A;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORWARDER_PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // // Impersonate the admin
        // vm.startPrank(ADMIN);
        
        // Get DoppiCore instance
        DoppiCore doppiCore = DoppiCore(DOPPI_CORE);
        DoppiTrader doppiTrader = DoppiTrader(DOPPI_TRADER);
        DoppiPoints doppiPoints = DoppiPoints(DOPPI_POINTS);
        
        uint256[] memory ids = doppiPoints.getMonthIds();
        // () = doppiPoints.getPoints(address(0xaD8234bC07168d9f7E49c3780e4b5fefa6620f8A);
        for(uint256 i; i <ids.length; i++){
            uint256 vol = doppiPoints.getMonthlyVolume(address(0xaD8234bC07168d9f7E49c3780e4b5fefa6620f8A), ids[i]);
            console.log("month id", ids[i], vol);
        }
        for(uint256 i; i <ids.length; i++){
            uint256 vol = doppiPoints.getMonthlyVolume(address(0x1Fbe951f061779e09CC2108A36B363cF22f8a161), ids[i]);
            console.log("month id", ids[i], vol);
        }

        // // console.log("Time forwarded by 1 day");
        // // console.log("New block timestamp:", block.timestamp);
        
        // // Check if upkeep is needed Trader bot
        // (bool upkeepNeeded2, bytes memory performData2) = doppiTrader.checkUpkeep("");
        // console.log("Doppi Trader Upkeep needed:", upkeepNeeded2);
        // if (upkeepNeeded2) {
        //     console.log("Performing upkeep for trader bot...");
        //     doppiTrader.performUpkeep(performData2);
        //     console.log("Trader bot Upkeep performed successfully!");
        // } else {
        //     console.log("No trader bot upkeep needed at this time");
        // }


        console.log("Current blocktime:", block.timestamp);
        
        uint256 buyCount = doppiCore.getBuyPositionCount();
        console.log(buyCount, "buyCount");
        DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        for(uint256 i; i <positions.length; i++){
            console.log("expiryTimestamp", positions[i].expiryTimestamp, block.timestamp);
            // console.log("owner", positions[i].owner);
            // doppiTrader = DoppiTrader(positions[i].owner);
            // console.log("valid trader", doppiTrader.get_validTrader());
        }
        // Forward time by 1 day (86400 seconds)
        // vm.warp(block.timestamp + 196400);
        
        // console.log("New blocktime:", block.timestamp);
        
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
        
        // vm.stopPrank();
        vm.stopBroadcast();
    }
    
}
