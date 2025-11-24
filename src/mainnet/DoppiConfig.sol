// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// import "forge-std/console.sol";

/// One DoppiConfig for one pair ie. USDT/BTC
contract DoppiConfig is Ownable {

    address public doppiUpKeepManager;
    // address public doppiOffer;
    
    constructor() Ownable(msg.sender) {
    }

    function setDoppiUpKeepManager(address _doppiUpKeepManager) external onlyOwner {
        doppiUpKeepManager = _doppiUpKeepManager;
    }

    // function setDoppiOffer(address _doppiOffer) external onlyOwner {
    //     doppiOffer = _doppiOffer;
    // }

}
