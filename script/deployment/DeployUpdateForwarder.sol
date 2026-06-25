// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiUpkeepManager.sol";
import "../../src/mainnet/DoppiOffer.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiLiquidity.sol";
import "../../src/mainnet/DoppiOpportunity.sol";

contract TestEnv is Script {

    address public constant DOPPI_CORE = address(0x8532f74529F4295f882f73Cd3D3cCfBcD6900e08); 
    address public constant DOPPI_OPPO = address(0xF2Abe0Bed649D5925E10C16B67F6C0622F2C1eaA); 
    address public constant DOPPI_LP = address(0x9b0e4260311a8874a0f7EeDB9545e93960e113c6); 
    address admin = address(0x11aA37b9ed1510d3eb111D9069bf385C63A1c611);
    address forwarder_doppicore = address(0xaD0df884eFd0702e7A01c142fD9e147d3143a031);
    address forwarder_doppiOppo = address(0x6A0610af3a6BB725DA5182D6637690dDD79C4fa9);
    address forwarder_doppiLP = address(0xDe255866d11098EA7b2e151E94b3262B78711dFb);
    
    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAINNET");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get DoppiCore instance
        DoppiCore doppiCore = DoppiCore(DOPPI_CORE);
        doppiCore.setForwarderAddress(forwarder_doppicore);
        console.log("done updating doppiCore forwarder address");

        DoppiOpportunity doppiOpportunity = DoppiOpportunity(DOPPI_OPPO);
        doppiOpportunity.setForwarderAddress(forwarder_doppiOppo);
        console.log("done updating doppiOpportunity forwarder address");

        DoppiLiquidity doppiLP = DoppiLiquidity(DOPPI_LP);
        doppiLP.setForwarderAddress(forwarder_doppiLP);
        console.log("done updating doppiLP forwarder address");
    
        vm.stopBroadcast();
    }
    
    
}