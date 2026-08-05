// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract DoppiFeePool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidAddress();
    error InvalidSplitBps();
    error NotAuthorizedCore();
    error NotOwnerOrAuthorizer();

    address public sharedLiquidity;
    address public feeReceiver;
    uint16 public sharedLPSplitBps;
    
    mapping(address => bool) public coreAuthorizers;
    mapping(address => bool) public authorizedCore;

    event FeeTargetsUpdated(address indexed sharedLiquidity, address indexed feeReceiver);
    event SharedLPSplitUpdated(uint16 sharedLPSplitBps);
    event AuthorizedCoreUpdated(address indexed core, bool allowed);
    event CoreAuthorizerUpdated(address indexed coreAuthorizer);
    event FeeDistributed(address indexed token, uint256 totalAmount, uint256 toSharedLiquidity, uint256 toFeeReceiver);

    constructor(address _sharedLiquidity, address _feeReceiver, uint16 _sharedLPSplitBps) Ownable(msg.sender) {
        _setFeeTargets(_sharedLiquidity, _feeReceiver);
        _setSharedLPSplit(_sharedLPSplitBps);
    }

    function setFeeTargets(address _sharedLiquidity, address _feeReceiver) external onlyOwner {
        _setFeeTargets(_sharedLiquidity, _feeReceiver);
    }

    function setSharedLPSplit(uint16 _sharedLPSplitBps) external onlyOwner {
        _setSharedLPSplit(_sharedLPSplitBps);
    }

    function setCoreAuthorizer(address _coreAuthorizer) external onlyOwner {
        coreAuthorizers[_coreAuthorizer] = true;
        emit CoreAuthorizerUpdated(_coreAuthorizer);
    }

    function setAuthorizedCore(address core, bool allowed) external {
        if (msg.sender != owner() && !coreAuthorizers[msg.sender]) revert NotOwnerOrAuthorizer();
        authorizedCore[core] = allowed;
        emit AuthorizedCoreUpdated(core, allowed);
    }

    /// @notice Called by authorized private DoppiCore right after fee transfer.
    function onFeeReceived(address token, uint256 amount) external nonReentrant {
        if (!authorizedCore[msg.sender]) revert NotAuthorizedCore();
        if (amount == 0) return;

        IERC20 erc20 = IERC20(token);
        uint256 balance = erc20.balanceOf(address(this));
        if (balance == 0) return;

        uint256 distributable = amount > balance ? balance : amount;
        uint256 toShared = (distributable * sharedLPSplitBps) / 10000;
        uint256 toReceiver = distributable - toShared;

        if (toShared > 0) {
            erc20.safeTransfer(sharedLiquidity, toShared);
        }
        if (toReceiver > 0) {
            erc20.safeTransfer(feeReceiver, toReceiver);
        }

        emit FeeDistributed(token, distributable, toShared, toReceiver);
    }

    function _setFeeTargets(address _sharedLiquidity, address _feeReceiver) internal {
        if (_sharedLiquidity == address(0) || _feeReceiver == address(0)) revert InvalidAddress();
        sharedLiquidity = _sharedLiquidity;
        feeReceiver = _feeReceiver;
        emit FeeTargetsUpdated(_sharedLiquidity, _feeReceiver);
    }

    function _setSharedLPSplit(uint16 _sharedLPSplitBps) internal {
        if (_sharedLPSplitBps > 10000) revert InvalidSplitBps();
        sharedLPSplitBps = _sharedLPSplitBps;
        emit SharedLPSplitUpdated(_sharedLPSplitBps);
    }
}
