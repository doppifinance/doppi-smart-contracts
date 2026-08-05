// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiLiquidity.sol";
import "../../src/mainnet/DoppiOpportunity.sol";

contract BetaUpdateDoppiForwarder is Script {

    address public constant DOPPI_CORE = address(0xa2d49d1c8b89Cd0b11AeA445887661CDcF9e9611); 
    address public constant DOPPI_LP = address(0x2deB22F6fCFE371c5024b52045850d9B32d33Bcd); 
    address public constant DOPPI_OPPORTUNITY = address(0x66C4e3c5A73d0fF469462a7fE7D740DF972CbB6D);
    address executor = address(0xFD2D482ABBc3Bc70354311e83B9347e83132E060);
    
    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAINNET");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        DoppiCore doppiCore = DoppiCore(DOPPI_CORE);
        doppiCore.setForwarderAddress(executor);
        console.log("done updating doppiCore forwarder address");

        DoppiLiquidity doppiLP = DoppiLiquidity(DOPPI_LP);
        doppiLP.setForwarderAddress(executor);
        console.log("done updating doppiLP forwarder address");

        DoppiOpportunity doppiOpportunity = DoppiOpportunity(DOPPI_OPPORTUNITY);
        doppiOpportunity.setForwarderAddress(executor);
        console.log("done updating doppiOpportunity forwarder address");
        
        vm.stopBroadcast();
    }
    
    
}