// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {DoppiTrader} from "../../src/mainnet/DoppiTrader.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";

contract DeployDoppiTraderImplementation is Script {
    error FactoryHasNoCode(address factory);
    error NotFactoryOwner(address caller, address owner);
    error ImplementationUpdateFailed(address expected, address actual);
    address constant DOPPI_TRADER_FACTORY = address(0x95B6758a05B6CE9aE4E14f579e959eE5471f6d5D);
    
    function run() external returns (address implementation) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAINNET");
        address factoryAddress = DOPPI_TRADER_FACTORY;
        if (factoryAddress.code.length == 0) revert FactoryHasNoCode(factoryAddress);

        DoppiTraderFactory factory = DoppiTraderFactory(factoryAddress);
        address deployer = vm.addr(deployerPrivateKey);
        address factoryOwner = factory.owner();
        if (factoryOwner != deployer) revert NotFactoryOwner(deployer, factoryOwner);

        address previousImplementation = factory.traderBotImplementation();
        console.log("Chain ID:", block.chainid);
        console.log("Trader factory:", factoryAddress);
        console.log("Previous implementation:", previousImplementation);

        vm.startBroadcast(deployerPrivateKey);
        implementation = address(new DoppiTrader());
        factory.updateImplementation(implementation);
        vm.stopBroadcast();

        address configuredImplementation = factory.traderBotImplementation();
        if (configuredImplementation != implementation) {
            revert ImplementationUpdateFailed(implementation, configuredImplementation);
        }

        console.log("New DoppiTrader implementation:", implementation);
        console.log("Factory implementation updated:", configuredImplementation);
    }
}
