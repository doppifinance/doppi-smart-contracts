// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDoppiLiquidityRouter} from "../Interface/IDoppiLiquidityRouter.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IShares} from "../Interface/IShares.sol";
import {IERC7575, ERC7575} from "./ERC7575.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract DoppiLiquidityRouter is Ownable, IDoppiLiquidityRouter {
    using SafeERC20 for IERC20;

    IDoppiLiquidity public doppiLP;
    IERC7575 public entryPointA;
    IERC7575 public entryPointB;
    address public assetA;
    address public assetB;

    constructor(IERC20 _assetA, IERC20 _assetB, IDoppiLiquidity _doppiLP) Ownable(msg.sender) {
        doppiLP = _doppiLP;
        entryPointA = new EntryPointAssetA(_assetA, IShares(address(_doppiLP)));
        entryPointB = new EntryPointAssetB(_assetB, IShares(address(_doppiLP)));
        assetA = address(_assetA);
        assetB = address(_assetB);
    }

    function deposit(address _asset, uint256 _amount) external returns (uint256 shares) {
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);

        if (_asset == assetA) {
            IERC20(_asset).safeIncreaseAllowance(address(entryPointA), _amount);
            shares = entryPointA.deposit(_amount, msg.sender);
        } else if (_asset == assetB) {
            IERC20(_asset).safeIncreaseAllowance(address(entryPointB), _amount);
            shares = entryPointB.deposit(_amount, msg.sender);
        } else {
            assert(false);
        }
    }

    function redeem(address _asset, uint256 _amount) external {
        // TODO: might not need this line
        IERC20(doppiLP).safeTransferFrom(msg.sender, address(this), _amount);

        if (_asset == assetA) {
            entryPointA.redeem(_amount, msg.sender, address(this));
        } else if (_asset == assetB) {
            entryPointB.redeem(_amount, msg.sender, address(this));
        } else {
            assert(false);
        }
    }
}

contract EntryPointAssetA is ERC7575 {
    constructor(IERC20 _asset, IShares _share) ERC7575(_asset, _share) {}

    function totalAssets() public view override returns (uint256) {
        return IDoppiLiquidity(shareToken()).totalAssetsInAssetA();
    }
}

contract EntryPointAssetB is ERC7575 {
    constructor(IERC20 _asset, IShares _share) ERC7575(_asset, _share) {}

    function totalAssets() public view override returns (uint256) {
        return IDoppiLiquidity(shareToken()).totalAssetsInAssetB();
    }
}
