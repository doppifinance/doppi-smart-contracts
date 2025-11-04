// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiTrader.sol";
import "../../src/mainnet/DoppiCoreTypes.sol";
import "../../src/mainnet/DoppiReferral.sol";


contract SettleDoppiCoreOrders is Script {
    
    // Replace with your actual DoppiCore contract address
    address public constant DOPPI_CORE = 0xcfF18562F2484F9630ED1DbC3970EbaB62E11Abf; 
    address public constant DOPPI_POINTS = 0x2f326AB5033f8DBC1B546c380BDe2D8Fd82370CC; 
    address public constant DOPPI_TRADER = 0x4F397052CC6661858F49640515Db7b47AdA17248; 
    address public constant DOPPI_REF = 0xFFB959134A7f4c29826144563252aE329cDcCa64; 

    // Replace with the admin address you want to impersonate
    address public constant ADMIN = 0x5D450b7A2bAFbc071cF1313099C3744f91c3BC24; // Add the admin address here
    address public constant trader = 0xaD8234bC07168d9f7E49c3780e4b5fefa6620f8A;
    address public constant trader2 = 0xaD8234bC07168d9f7E49c3780e4b5fefa6620f8A;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORWARDER_PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get DoppiCore instance
        DoppiCore doppiCore = DoppiCore(DOPPI_CORE);
        DoppiTrader doppiTrader = DoppiTrader(DOPPI_TRADER);
        DoppiPoints doppiPoints = DoppiPoints(DOPPI_POINTS);
        DoppiReferral doppiReferral = DoppiReferral(DOPPI_REF);
        
        uint256[] memory ids = doppiPoints.getMonthIds();
        for(uint256 i; i <ids.length; i++){
            uint256 vol = doppiPoints.getMonthlyVolume(address(trader), ids[i]);
            console.log("month id", ids[i], vol);
        }
        for(uint256 i; i <ids.length; i++){
            uint256 vol = doppiPoints.getMonthlyVolume(address(DOPPI_TRADER), ids[i]);
            console.log("month id", ids[i], vol);
        }

        (uint256 totalL1, uint256 totalL2, uint256 totalL3,
            uint256 currentL1, uint256 currentL2, uint256 currentL3 ) = doppiReferral.getTotalReferralRewards(trader2);

        console.log(totalL1, totalL2, totalL3);
        console.log(currentL1, currentL2, currentL3);
        // Check if upkeep is needed Trader bot
        (bool upkeepNeeded2, bytes memory performData2) = doppiTrader.checkUpkeep("");
        console.log("Doppi Trader Upkeep needed:", upkeepNeeded2);
        if (upkeepNeeded2) {
            console.log("Performing upkeep for trader bot...");
            doppiTrader.performUpkeep(performData2);
            console.log("Trader bot Upkeep performed successfully!");
        } else {
            console.log("No trader bot upkeep needed at this time");
        }


        uint256 buyCount = doppiCore.getBuyPositionCount();
        DualAssetPosition[] memory positions = doppiCore.get_positions_buy();
        for(uint256 i; i <positions.length; i++){
            console.log("expiryTimestamp", positions[i].expiryTimestamp, block.timestamp);
        }
        
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
        
        vm.stopBroadcast();
    }
    
}
