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
    
    constructor(address _doppiCore, address _doppiLP) Ownable(msg.sender) {
        doppiCore = DoppiCore(_doppiCore);
        doppiLP = IDoppiLiquidity(_doppiLP);
    }

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        require(forwarderAddress != address(0), "zero forwarder");
        s_forwarderAddress = forwarderAddress;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        
        if(paused()) return (false, bytes(""));

        uint256 price = doppiLP.getPrice();
        (   
            uint256[] memory targetPrices, 
            uint256[] memory targetPricesUnwind, 
            uint256 totalAmountBuy,
            uint256 totalAmountBuyUnwind
        ) = doppiCore.checkOpportunity(price, true);
        
        (   
            uint256[] memory targetPricesSell, 
            uint256[] memory targetPricesSellUnwind, 
            uint256 totalAmountSell,
            uint256 totalAmountSellUnwind
        ) = doppiCore.checkOpportunity(price, false);

        upkeepNeeded = (targetPrices.length > 0 || targetPricesUnwind.length > 0 || targetPricesSell.length > 0 || targetPricesSellUnwind.length > 0);
        
        if (upkeepNeeded) {
            performData = abi.encode(
                targetPrices, targetPricesUnwind, totalAmountBuy, totalAmountBuyUnwind,
                targetPricesSell, targetPricesSellUnwind, totalAmountSell, totalAmountSellUnwind
                );
        } else {
            performData = bytes("");
        }
        
        return (upkeepNeeded, performData);
    }

    function performUpkeep(bytes calldata performData) external override onlyForwarder {
        
        if(paused()) return;
        
        (
            uint256[] memory targetPrices, 
            uint256[] memory targetPricesUnwind, 
            uint256 totalAmountBuy,
            uint256 totalAmountBuyUnwind,
            uint256[] memory targetPricesSell, 
            uint256[] memory targetPricesSellUnwind, 
            uint256 totalAmountSell,
            uint256 totalAmountSellUnwind
        ) = abi.decode(performData, (uint256[], uint256[], uint256, uint256, uint256[], uint256[], uint256, uint256));
        
        if(targetPrices.length > 0 || targetPricesUnwind.length > 0){
            doppiCore.performOpportunity(targetPrices, targetPricesUnwind, totalAmountBuy, totalAmountBuyUnwind, true);
        }
        if(targetPricesSell.length > 0 || targetPricesSellUnwind.length > 0){
            doppiCore.performOpportunity(targetPricesSell, targetPricesSellUnwind, totalAmountSell, totalAmountSellUnwind, false);
        }
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }

    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "invalid forwarder");
        _;
    }
}