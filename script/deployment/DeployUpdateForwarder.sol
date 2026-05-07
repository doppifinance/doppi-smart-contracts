// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiUpkeepManager.sol";
import "../../src/mainnet/DoppiOffer.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiLiquidity.sol";
import "../../src/mainnet/DoppiOpportunity.sol";

contract TestEnv is Script {

    address public constant DOPPI_CORE = address(0xa2d49d1c8b89Cd0b11AeA445887661CDcF9e9611); 
    address public constant DOPPI_OPPO = address(0x66C4e3c5A73d0fF469462a7fE7D740DF972CbB6D); 
    address public constant DOPPI_LP = address(0x2deB22F6fCFE371c5024b52045850d9B32d33Bcd); 
    address admin = address(0x11aA37b9ed1510d3eb111D9069bf385C63A1c611);
    address forwarder_doppicore = address(0x832E2E2702b17b7E073e196ee7c6500c2AC00e41);
    address forwarder_doppiOppo = address(0xB1a52DC29f0FC0528996c94c010D09dbb9884049);
    address forwarder_doppiLP = address(0xa5E9e23bd05518a0e738921fCA33976c85Bb1564);
    
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