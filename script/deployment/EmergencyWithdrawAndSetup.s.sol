// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiCore.sol";
// import "../../src/mainnet/DoppiCoreTypes.sol";
import "../../src/mainnet/DoppiLiquidityRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract EmergencyWithdrawAndSetup is Script {
    
    // Replace with your actual DoppiCore contract address
    address public constant DOPPI_LP_ROUTER = 0x4Ea3706871E9188eC7aae2954b6B08a877b6788d; 
    address public constant DOPPI_CORE = 0x0Fd25f185431480dC698Bd01DD4F288972626cdA; 
    address public constant DOPPI_LP_ROUTER_ETH = 0x3B28860f4682AbA7B0e1184b35ea755fcB52551c; 
    address public constant DOPPI_CORE_ETH = 0x8532f74529F4295f882f73Cd3D3cCfBcD6900e08; 
    DoppiCore doppiCore;
    DoppiLiquidityRouter doppiRouter;

    address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAINNET");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get DoppiCore instance
        doppiCore  = DoppiCore(DOPPI_CORE_ETH);
        doppiRouter = DoppiLiquidityRouter(DOPPI_LP_ROUTER_ETH);  

        // doppiCore.setUpkeeps_per_check(1);
        // console.log("Updated upkeeps per check to 1");

        _setPauseProtocol();
        // _setUnPauseProtocol();

        // uint256 usdtBalance = IERC20(USDT).balanceOf(DOPPI_CORE_ETH);
        // console.log("USDT Balance in DOPPI_CORE_ETH Before:", usdtBalance);

        // doppiCore.settleOrders(1);
        // console.log("Settled orders for DoppiCore");

        // usdtBalance = IERC20(USDT).balanceOf(DOPPI_CORE_ETH);
        // console.log("USDT Balance in DOPPI_CORE_ETH After:", usdtBalance);

        // _executeEmergencySettlement();


        // doppiCore  = DoppiCore(DOPPI_CORE_ETH);
        // doppiRouter = DoppiLiquidityRouter(DOPPI_LP_ROUTER_ETH);        
        // _setPauseProtocol();
        // _setUnPauseProtocol();
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
