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
    address public constant DOPPI_CORE = 0x15c07435B0B38b075E28B1D7969e3C87FBCDDC49; 
    address public constant DOPPI_POINTS = 0x77C31762884052333A4b6CA0E4B063e19Dd50a4b; 
    address public constant DOPPI_TRADER = 0x234765F220DB7F6C062Bc552AAfe0005Cc8Ce04a; 
    address public constant DOPPI_REF = 0x73515beBAEa74f6194C2D18Ce762419272e7cBB7; 
    address public constant DOPPI_OFFER = 0x17F38AB89496E10E34268bDc66ae48D50Fb4A227; 

    // Replace with the admin address you want to impersonate
    address public constant ADMIN = 0x6Abb788569C3658b4C4798dEb914e6151D7aFc1C; // Add the admin address here
    address public constant trader = 0xB91a71FA558ec371eA09477c1D9f46E6AbA60719;
    address public constant trader2 = 0xB91a71FA558ec371eA09477c1D9f46E6AbA60719;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORWARDER_PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get DoppiCore instance
        DoppiCore doppiCore = DoppiCore(DOPPI_CORE);
        DoppiPoints doppiPoints = DoppiPoints(DOPPI_POINTS);
        DoppiReferral doppiReferral = DoppiReferral(DOPPI_REF);
        DoppiOffer impliedVol = DoppiOffer(DOPPI_OFFER);

        // (DualAssetOffer[] memory buyOffers, DualAssetOffer[] memory selloffers) = impliedVol.getAllOffers(1);
        // for(uint256 i=0; i< selloffers.length; i++){
        //     console.log(selloffers[i].strikePrice, selloffers[i].price);
        // }
        // for(uint256 i=0; i< buyOffers.length; i++){
        //     console.log(buyOffers[i].strikePrice, buyOffers[i].price);
        // }

        // uint24[] memory ids = doppiPoints.getMonthIds();
        // for(uint256 i; i <ids.length; i++){
        //     uint256 vol = doppiPoints.getMonthlyVolume(address(trader), ids[i]);
        //     console.log("month id", ids[i], vol);
        // }
        // for(uint256 i; i <ids.length; i++){
        //     uint256 vol = doppiPoints.getMonthlyVolume(address(DOPPI_TRADER), ids[i]);
        //     console.log("month id", ids[i], vol);
        // }

        // (uint256 totalL1, uint256 totalL2, uint256 totalL3,
        //     uint256 currentL1, uint256 currentL2, uint256 currentL3 ) = doppiReferral.getTotalReferralRewards(trader2);

        // console.log(totalL1, totalL2, totalL3);
        // console.log(currentL1, currentL2, currentL3);
        address traderbot2 = address(0x234765F220DB7F6C062Bc552AAfe0005Cc8Ce04a);
        uint256 buyCount = doppiCore.getBuyPositionCount(traderbot2);
        DualAssetPosition[] memory positions = doppiCore.get_positions_buy(traderbot2);
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
