// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IDoppiLiquidityRouter} from "../Interface/IDoppiLiquidityRouter.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IShares} from "../Interface/IShares.sol";
import {IERC7575, ERC7575} from "./ERC7575.sol";

contract DoppiLiquidityRouter is Ownable, Pausable, IDoppiLiquidityRouter {
    using SafeERC20 for IERC20;

    IDoppiLiquidity public immutable doppiLP;
    IERC7575 public immutable entryPointA;
    IERC7575 public immutable entryPointB;
    address public immutable assetA;
    address public immutable assetB;

    constructor(IERC20 _assetA, IERC20 _assetB, IDoppiLiquidity _doppiLP) Ownable(msg.sender) {
        doppiLP = _doppiLP;
        entryPointA = new EntryPointAssetA(_assetA, IShares(address(_doppiLP)));
        entryPointB = new EntryPointAssetB(_assetB, IShares(address(_doppiLP)));
        assetA = address(_assetA);
        assetB = address(_assetB);
    }

    function deposit(address _asset, uint256 _amount) external whenNotPaused returns (uint256 shares) {
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);

        if (_asset == assetA) {
            IERC20(_asset).safeIncreaseAllowance(address(entryPointA), _amount);
            shares = entryPointA.deposit(_amount, msg.sender);
        } else if (_asset == assetB) {
            IERC20(_asset).safeIncreaseAllowance(address(entryPointB), _amount);
            shares = entryPointB.deposit(_amount, msg.sender);
        } else {
            revert("Invalid asset");
        }
    }

    function redeem(uint256 _amount) external {
        IERC20(doppiLP).safeTransferFrom(msg.sender, address(this), _amount);
        (uint256 ratioA, uint256 ratioB) = entryPointB.assetRatio();
        uint256 firstHalf = _amount * ratioA / (ratioA + ratioB);
        uint256 secondHalf = _amount - firstHalf;        
        entryPointA.redeem(firstHalf, msg.sender, address(this));
        entryPointB.redeem(secondHalf, msg.sender, address(this));
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }
}

contract EntryPointAssetA is ERC7575 {
    constructor(IERC20 _asset, IShares _share) ERC7575(_asset, _share) {}

    function totalAssets() public view override returns (uint256) {
        return IDoppiLiquidity(shareToken()).totalAssetsInAssetA();
    }

    function assetRatio() public view returns (uint256, uint256) {
        return IDoppiLiquidity(shareToken()).assetRatio();
    }
}

contract EntryPointAssetB is ERC7575 {
    constructor(IERC20 _asset, IShares _share) ERC7575(_asset, _share) {}

    function totalAssets() public view override returns (uint256) {
        return IDoppiLiquidity(shareToken()).totalAssetsInAssetB();
    }

    function assetRatio() public view returns (uint256, uint256) {
        return IDoppiLiquidity(shareToken()).assetRatio();
    }
}