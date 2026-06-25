// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";

abstract contract DoppiCoreAdmin is Ownable, Pausable {
    error ZeroTreasury();
    error TreasuryFeeTooHigh();
    error AprToleranceTooHigh();
    error ZeroForwarder();
    
    uint256 public priceDecimal;
    uint24 public treasury_fee; 
    address public treasury;
    uint256 public minOrderA = 100 ether; 
    uint256 public minOrderB = 0.001 ether; 
    bool public emergencyMode;
    address public s_forwarderAddress;
    uint16 public UPKEEPS_PER_CHECK = 20; 
    mapping(address => bool) public opportunityBots;
    uint16 public aprToleranceBP = 0; 
    uint256 public maxSwap = 100000 ether;
    
    IDoppiTraderFactory public doppiTraderFactory;
    
    // Configuration functions
    function setPriceDecimal(uint256 _priceDecimal) external onlyOwner {
        priceDecimal = _priceDecimal;
    }
    function setMaxSwap(uint256 _maxSwap) external onlyOwner {
        maxSwap = _maxSwap;
    }

    function setTreasury(address _treasury, uint24 _treasury_fee) external onlyOwner {
        if (_treasury == address(0)) revert ZeroTreasury();
        if (_treasury_fee > 2500) revert TreasuryFeeTooHigh();
        treasury_fee = _treasury_fee;
        treasury = _treasury;
    }
    
    function setMinOrder(uint256 _minOrderA, uint256 _minOrderB) external onlyOwner {
        minOrderA = _minOrderA;
        minOrderB = _minOrderB;
    }

    function setAPRTolerance(uint16 _toleranceBP) external onlyOwner {
        if (_toleranceBP > 1000) revert AprToleranceTooHigh();
        aprToleranceBP = _toleranceBP;
    }

    function setUpkeeps_per_check(uint16 _percheck) external onlyOwner {
        UPKEEPS_PER_CHECK = _percheck;
    }

    function setDoppiTraderFactory(IDoppiTraderFactory _traderFactory) external onlyOwner {
        doppiTraderFactory = _traderFactory;
    }

    function setOpportunityBot(address _opportunityBot, bool _status) external onlyOwner {
        opportunityBots[_opportunityBot] = _status;
    }

    function setEmergencyMode(bool _emergency) external onlyOwner whenPaused {
        emergencyMode = _emergency;
    }

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        if (forwarderAddress == address(0)) revert ZeroForwarder();
        s_forwarderAddress = forwarderAddress;
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }
}
