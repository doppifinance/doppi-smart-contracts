// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import {TopUpInfo} from "../Interface/IDoppiUpkeepManager.sol";


contract MockDoppiReferral {
    
    constructor() {
	}
    
    function getUplineChain(address trader) external view returns (address l1, address l2, address l3) {
        l1 = address(0);
        l2 = address(0);
        l3 = address(0);
    }
}
