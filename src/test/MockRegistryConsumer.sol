// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Interface/IAutomationRegistryConsumer.sol";
import "./MockToken.sol";
import "./MockOracle.sol";
import "../Interface/LinkTokenInterface.sol";

// import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "forge-std/console.sol";

contract MockRegistryConsumer is IAutomationRegistryConsumer {
    
	mapping(uint256 => IAutomationRegistryConsumer.UpkeepInfo) public upkeepInfos;
	LinkTokenInterface public linkToken;

    constructor() {

		linkToken = LinkTokenInterface(address(0x404460C6A5EdE2D891e8297795264fDe62ADBB75));
		uint256 keepId1 = 10126513187475120052854210204634476291137427371787226750303145633439909703611;

		upkeepInfos[keepId1] = UpkeepInfo({
			target: address(0x9EdF8B110633B5a359f9371884200ffC69003c60),
			executeGas: 1000000,
			checkData: hex"",
			balance: 5000000000000000000,
			admin: address(0x7c8999dC9a822c1f0Df42023113EDB4FDd543266),
			maxValidBlocknumber: 4294967295,
			lastPerformBlockNumber: 0,
			amountSpent: 0,
			paused: false,
			offchainConfig: hex"",
			forwarder: address(0)
		});	

		uint256 keepId2 = 85572568362417814516910336273473322297533253932261901153407809393837727925278;
		upkeepInfos[keepId2] = UpkeepInfo({
			target: address(0x26f0273d10E2d5858Db48E56b8b1B4C75063ceB0),
			executeGas: 1000000,
			checkData: hex"",
			balance: 5000000000000000000,
			admin: address(0x7c8999dC9a822c1f0Df42023113EDB4FDd543266),
			maxValidBlocknumber: uint32(4294967295),
			lastPerformBlockNumber: 0,
			amountSpent: 0,
			paused: false,
			offchainConfig: hex"",
			forwarder: address(0)
		});	
	
			
        
    }

	function dummyAdd(uint256 id) internal {

		if(upkeepInfos[id].target == address(0))
		{
			upkeepInfos[id] = UpkeepInfo({
				target: address(0x26f0273d10E2d5858Db48E56b8b1B4C75063ceB0),
				executeGas: 1000000,
				checkData: hex"",
				balance: 5000000000000000000,
				admin: address(0x7c8999dC9a822c1f0Df42023113EDB4FDd543266),
				maxValidBlocknumber: uint32(4294967295),
				lastPerformBlockNumber: 0,
				amountSpent: 0,
				paused: false,
				offchainConfig: hex"",
				forwarder: address(0)
			});	
		}
	}

	function updateAmountSpent (uint256 keepId, uint96 amount) public {
		upkeepInfos[keepId].amountSpent = upkeepInfos[keepId].amountSpent + amount;
		upkeepInfos[keepId].balance = upkeepInfos[keepId].balance == 0 ? 0 : upkeepInfos[keepId].balance - amount;
		upkeepInfos[keepId].lastPerformBlockNumber = uint32(block.number);
	}

    function getBalance(uint256 id) external pure returns (uint96 balance) {
        balance = 1e18;
    }

    function getMinBalance(
        uint256 id
    ) external pure returns (uint96 minBalance) {
        minBalance = 1e18;
    }

    function cancelUpkeep(uint256 id) external {
		// revert("not implement");
		dummyAdd(id);
		upkeepInfos[id].paused = true;
		upkeepInfos[id].maxValidBlocknumber = uint32(block.number) + 50;
	}

    function pauseUpkeep(uint256 id) external {
		
		dummyAdd(id);
		upkeepInfos[id].paused = true;
		// revert("not implement");
	}

    function unpauseUpkeep(uint256 id) external {
		// revert("not implement");
		dummyAdd(id);
		upkeepInfos[id].paused = false;
	}

    function addFunds(uint256 id, uint96 amount) external{
		
		dummyAdd(id);
		linkToken.transferFrom(msg.sender, address(this), amount);
		upkeepInfos[id].balance = upkeepInfos[id].balance + amount;
	}

    function withdrawFunds(uint256 id, address to) external{
		dummyAdd(id);
		upkeepInfos[id].balance = 0;
		linkToken.transfer(to, 12329638941840579811);
	}

    function getUpkeep(
        uint256 id
    ) external view returns (IAutomationRegistryConsumer.UpkeepInfo memory upkeepInfo){

		upkeepInfo = upkeepInfos[id];
		if(upkeepInfo.target == address(0)){
			upkeepInfo = UpkeepInfo({
				target: address(0x234765F220DB7F6C062Bc552AAfe0005Cc8Ce04a),
				executeGas: 1000000,
				checkData: hex"",
				balance: 5000000000000000000,
				admin: address(0x0909645Fb7a98594836279d08c45C5b4f946c2A4),
				maxValidBlocknumber: uint32(4294967295),
				lastPerformBlockNumber: 0,
				amountSpent: 0,
				paused: false,
				offchainConfig: hex"",
				forwarder: address(0)
			});	
		}else{
			return upkeepInfos[id];
		}
	}

    function getForwarder(uint256 upkeepID) external pure returns (address){
		return address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
	}

	function registerUpkeep(
        IAutomationRegistryConsumer.RegistrationParams calldata requestParams
    ) external returns (uint256){
		revert("not implement");
	}

}
