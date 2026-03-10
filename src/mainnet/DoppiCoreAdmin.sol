// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";

abstract contract DoppiCoreAdmin is Ownable, Pausable {
    
    uint24 public treasury_fee; 
    address public treasury;
    uint256 public minOrderA = 100 ether; 
    uint256 public minOrderB = 0.001 ether; 
    bool public emergencyMode;
    bool public publicOpen = true;
    address public s_forwarderAddress;
    uint16 public UPKEEPS_PER_CHECK = 20; 
    mapping(address => bool) public opportunityBots;
    uint16 public aprToleranceBP = 0; 
    uint256 public maxSwap = 100000 ether;
    
    IDoppiTraderFactory public doppiTraderFactory;
    
    // Configuration functions
    function setMaxSwap(uint256 _maxSwap) external onlyOwner {
        maxSwap = _maxSwap;
    }

    function setTreasury(address _treasury, uint24 _treasury_fee) external onlyOwner {
        treasury_fee = _treasury_fee;
        treasury = _treasury;
    }
    
    function setMinOrder(uint256 _minOrderA, uint256 _minOrderB) external onlyOwner {
        minOrderA = _minOrderA;
        minOrderB = _minOrderB;
    }

    function setAPRTolerance(uint16 _toleranceBP) external onlyOwner {
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
        s_forwarderAddress = forwarderAddress;
    }

    function setPublicOpen(bool _open) external onlyOwner {
        publicOpen = _open;
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }
}
