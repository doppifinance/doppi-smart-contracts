// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiUpkeepManager.sol";
import "../../src/mainnet/DoppiOffer.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiLiquidity.sol";
import "../../src/mainnet/DoppiOpportunity.sol";

contract TestEnv is Script {

    address public constant DOPPI_CORE = address(0x4Fe2973Df9c541c23Ce0C1e8752D16E797920d99); 
    address public constant DOPPI_OPPO = address(0xA5bBf8eB82EA8a0E13f6A071073f6CFD8A57fd7f); 
    address public constant DOPPI_LP = address(0xc7D5CB3567CbB2f52189C64e0067Bf9B2c2ab0eB); 
    address admin = address(0x96D275Bf3ade54b2Bd648E21495b50f18F374b08);
    address forwarder_doppicore = address(0x5fD1C1f0B2B2264c6EEF0163574B5ADd6a2E981a);
    address forwarder_doppiOppo = address(0x45C12A4B5853bD546D22E6711E872E9E8C03aB54);
    address forwarder_doppiLP = address(0xD5FB72D3015382806bE1F672deC044bCfB516d32);
    
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