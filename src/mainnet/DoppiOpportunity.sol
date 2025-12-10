// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./DoppiCore.sol";
import "../Interface/AutomationCompatibleInterface.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
// import "forge-std/console.sol";

contract DoppiOpportunity is Ownable, Pausable, AutomationCompatibleInterface {
    DoppiCore public immutable doppiCore;
    IDoppiLiquidity public immutable doppiLP;
    address public s_forwarderAddress;
    uint32 public tolerance = 100;
    
    constructor(address _doppiCore, address _doppiLP) Ownable(msg.sender) {
        doppiCore = DoppiCore(_doppiCore);
        doppiLP = IDoppiLiquidity(_doppiLP);
    }

    function setTolerance(uint32 _tolerance) external onlyOwner {
        tolerance = _tolerance;
    }

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        s_forwarderAddress = forwarderAddress;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        
        if(paused()) return (false, bytes(""));

        uint256 price = doppiLP.getPrice();
        (uint256 buyCount, uint256[] memory buyIndexes) = doppiCore.checkOpportunity(price, true);
        (uint256 sellCount, uint256[] memory sellIndexes) = doppiCore.checkOpportunity(price, false);
        
        upkeepNeeded = (buyCount > 0 || sellCount > 0);
        
        if (upkeepNeeded) {
            performData = abi.encode(price, buyIndexes, sellIndexes);
        } else {
            performData = bytes("");
        }
        
        return (upkeepNeeded, performData);
    }

    function performUpkeep(bytes calldata performData) external override onlyForwarder {
        
        if(paused()) return;
        
        (uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) =
            abi.decode(performData, (uint256, uint256[], uint256[]));

        uint256 currentPrice = doppiLP.getPrice();
        uint256 priceChance = price * 10000 / currentPrice;
        if (priceChance > 10000 + tolerance || priceChance < 10000 - tolerance) {
            return;
        }        
        _opportunity_bot(price, buyIndexes, sellIndexes);
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }

    function _opportunity_bot(uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) internal {
        if (buyIndexes.length > 0) {
            doppiCore.performOpportunity(price, buyIndexes, true);
        }
        
        if (sellIndexes.length > 0) {
            doppiCore.performOpportunity(price, sellIndexes, false);
        }
    }

    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "invalid forwarder");
        _;
    }
}