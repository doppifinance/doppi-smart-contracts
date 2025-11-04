// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DoppiTraderFactory} from "./DoppiTraderFactory.sol";

//       DualAsset Admin Module (Owner / Keeper Ops)
abstract contract DoppiCoreAdmin is Ownable, Pausable {
    
    bool public emergencyMode;
    bool public publicOpen = true;
    address public s_forwarderAddress;
    uint256 public UPKEEPS_PER_CHECK = 20; // Process 20 upkeeps per check
    mapping(address => bool) public admins;
    
    DoppiTraderFactory public doppiTraderFactory;
    
    // Configuration functions
    function setUpkeeps_per_check(uint24 _percheck) external onlyOwner {
        UPKEEPS_PER_CHECK = _percheck;
    }

    function setDoppiTraderFactory(DoppiTraderFactory _traderFactory) external onlyOwner {
        doppiTraderFactory = _traderFactory;
    }

    function setAdmin(address _admin, bool _status) external onlyOwner {
        admins[_admin] = _status;
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
