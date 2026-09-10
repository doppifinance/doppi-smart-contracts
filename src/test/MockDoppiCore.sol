// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


contract MockDoppiCore {
    
    constructor() {
	}
    
    bool public emergencyMode = true;

    function getInterestLiabilities() external view returns (uint256, uint256) {
        return (0, 0);
    }

    function getCurrentDeposits(bool isBuy) public view returns (uint256 currentDeposits)
    {
        return 0;
    }

}
