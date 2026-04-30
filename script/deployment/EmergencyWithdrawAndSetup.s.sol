// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiCore.sol";
// import "../../src/mainnet/DoppiCoreTypes.sol";
import "../../src/mainnet/DoppiLiquidityRouter.sol";


contract EmergencyWithdrawAndSetup is Script {
    
    // Replace with your actual DoppiCore contract address
    address public constant DOPPI_LP_ROUTER = 0x74c04510B68FE415185086CEE5Db74138199A27a; 
    address public constant DOPPI_CORE = 0x0C049C1A2c8DaB66cf44e36F654e93Dd951390b2; 
    address public constant DOPPI_LP_ROUTER_ETH = 0xC582657B68Cbb9EE049fE36b07a323f9e417D6d5; 
    address public constant DOPPI_CORE_ETH = 0x80def7B2FFc1f57e7f15E9ec3fA9Ca2ca4F5A240; 
    DoppiCore doppiCore;
    DoppiLiquidityRouter doppiRouter;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get DoppiCore instance
        doppiCore  = DoppiCore(DOPPI_CORE);
        doppiRouter = DoppiLiquidityRouter(DOPPI_LP_ROUTER);        
        // _setPauseProtocol();
        _setUnPauseProtocol();
        // _executeEmergencySettlement();


        doppiCore  = DoppiCore(DOPPI_CORE_ETH);
        doppiRouter = DoppiLiquidityRouter(DOPPI_LP_ROUTER_ETH);        
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
        
        if(doppiCore.emergencyMode() || doppiCore.paused()){
            console.log("doppiCore Protocol is already in emergency mode or paused. Exiting.");
        }else{
            doppiCore.setPause();
            doppiCore.setEmergencyMode(true);   
        }

        if(doppiRouter.emergencyMode() || doppiRouter.paused()){
            console.log("doppiRouter Protocol is already in emergency mode or paused. Exiting.");
        }else{
            doppiRouter.setPause();
            doppiRouter.setEmergencyMode(true);
        }
    }

    function _setUnPauseProtocol() internal {
        
        if(!doppiCore.emergencyMode() || !doppiCore.paused()){
            console.log("doppiCore Protocol is already in unpaused. Exiting.");
        }else{
            doppiCore.setEmergencyMode(false);
            doppiCore.setUnPause();
        }

        if(!doppiRouter.emergencyMode() || !doppiRouter.paused()){
            console.log("doppiRouter Protocol is already in unpaused. Exiting.");
        }else{
            doppiRouter.setEmergencyMode(false);
            doppiRouter.setUnPause();
        }
        
        
        
    }
    
}
