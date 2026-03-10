// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiCore.sol";
// import "../../src/mainnet/DoppiCoreTypes.sol";
import "../../src/mainnet/DoppiLiquidityRouter.sol";


contract EmergencyWithdrawAndSetup is Script {
    
    // Replace with your actual DoppiCore contract address
    address public constant DOPPI_LP_ROUTER = 0xaEBe9BfAFAeDbBe7785f85FbA61a91FD2cEb2349; 
    address public constant DOPPI_CORE = 0xDbA6d9BD28E49365645dFb808854B322BdAa4BD7; 

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get DoppiCore instance
        DoppiCore doppiCore = DoppiCore(DOPPI_CORE);
        DoppiLiquidityRouter doppiRouter = DoppiLiquidityRouter(DOPPI_LP_ROUTER);
        
        console.log(doppiCore.emergencyMode(), doppiCore.paused());
        
        // doppiCore.setPause();
        // doppiCore.setEmergencyMode(true);
        // doppiRouter.setPause();
        // doppiRouter.setEmergencyMode(true);

        doppiCore.setEmergencyMode(false);
        doppiCore.setUnPause();
        doppiRouter.setEmergencyMode(false);
        doppiRouter.setUnPause();
        

        vm.stopBroadcast();
    }
    
}
