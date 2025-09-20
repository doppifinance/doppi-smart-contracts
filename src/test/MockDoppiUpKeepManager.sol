// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;


contract MockDoppiUpKeepManager {
    
	uint256 private keepId;
	address private forwarder; 
    constructor(address _forwarder) {
		keepId = 85572568362417814516910336273473322297533253932261901153407809393837727925278;
		forwarder = _forwarder;
	}
    
    function getUpkeepIdByBot(address _traderbot) external view returns (uint256) {
        return keepId;
    }
    
    function getForwarder(uint256 _upkeepId) external view returns (address) {
        return forwarder;
    }
    
    
}
