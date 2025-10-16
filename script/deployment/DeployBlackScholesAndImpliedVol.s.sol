// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/BlackScholes.sol";
import "../../src/mainnet/ImpliedVol.sol";

contract DeployBlackScholesAndImpliedVol is Script {
    
    address constant CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy BlackScholes contract (no constructor parameters)
        BlackScholes blackScholes = new BlackScholes();
        console.log("BlackScholes deployed at:", address(blackScholes));

        // Deploy ImpliedVol contract (requires BlackScholes address)
        ImpliedVol impliedVol = new ImpliedVol(IBlackScholes(blackScholes), CHAINLINK_BTC_USD, 500);
        console.log("ImpliedVol deployed at:", address(impliedVol));

        vm.stopBroadcast();

        // Log deployment addresses for easy access
        console.log("\n=== Deployment Summary ===");
        console.log("BlackScholes:", address(blackScholes));
        console.log("ImpliedVol:", address(impliedVol));
    }
}
