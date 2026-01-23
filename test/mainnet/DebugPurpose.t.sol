// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/mainnet/DoppiUpkeepManager.sol";

contract DebugPurposeTest is Test {
    
    DoppiUpkeepManager doppiupkeep;
    address payable DOPPI_UPKEEP = payable(0x84223a8a269103fB590Bf6aaDE2977a27a4CB93d);
    
    function setUp() public {
        
        // Fork Mainnet at a specific block
        uint256 mainnetFork = vm.createFork("mainnet", 76714448); 
        vm.selectFork(mainnetFork);
        
        // Start prank as owner
        // vm.startPrank(owner);
        
        doppiupkeep = DoppiUpkeepManager(DOPPI_UPKEEP);
        
        // vm.stopPrank();
    }

    function testSetupAutomation() public {

        vm.prank(address(0x52Dc553d8853533217bA9c32CcB4dfD9d54Aa3DD));
        uint256 Id = doppiupkeep.setupAutomation(address(0x3555B406B689B438A6CABC3Da43C6C59782cf84e));
        console.log(doppiupkeep.DEFAULT_AMOUNT(), "DEFAULT_AMOUNT");
        console.log(Id, "Id");
        vm.stopPrank();
    }

}
