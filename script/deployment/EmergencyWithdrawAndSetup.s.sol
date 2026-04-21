// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiCore.sol";
// import "../../src/mainnet/DoppiCoreTypes.sol";
import "../../src/mainnet/DoppiLiquidityRouter.sol";


contract EmergencyWithdrawAndSetup is Script {
    
    // Replace with your actual DoppiCore contract address
    address public constant DOPPI_LP_ROUTER = 0xc18FD23c3F9d23595f9d374ec37fE6c7B244dbDC; 
    address public constant DOPPI_CORE = 0x32A79472c47dBaf1feD227eefC2f9628BAD35277; 
    DoppiCore doppiCore;
    DoppiLiquidityRouter doppiRouter;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get DoppiCore instance
        doppiCore  = DoppiCore(DOPPI_CORE);
        doppiRouter = DoppiLiquidityRouter(DOPPI_LP_ROUTER);
        
        console.log(doppiCore.emergencyMode(), doppiCore.paused());
        
        // _setPauseProtocol();
        _setUnPauseProtocol();
        // _executeEmergencySettlement();

        vm.stopBroadcast();
    }

    function _executeEmergencySettlement() internal {
        
        if(doppiCore.emergencyMode() && doppiCore.paused()){
            doppiCore.emergencySettlement(1);
            console.log("Executed emergency settlement for order 1");
        } else {
            console.log("Protocol is not in the correct state for emergency settlement. Exiting.");
            return;
        }
    }

    function _setPauseProtocol() internal {
        doppiCore.setPause();
        doppiCore.setEmergencyMode(true);
        doppiRouter.setPause();
        doppiRouter.setEmergencyMode(true);
    }

    function _setUnPauseProtocol() internal {
        doppiCore.setEmergencyMode(false);
        doppiCore.setUnPause();
        doppiRouter.setEmergencyMode(false);
        doppiRouter.setUnPause();
    }
    
}
