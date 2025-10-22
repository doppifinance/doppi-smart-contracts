// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IDoppiLiquidityRouter} from "../Interface/IDoppiLiquidityRouter.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IShares} from "../Interface/IShares.sol";
import {IERC7575, ERC7575} from "./ERC7575.sol";
import "forge-std/console.sol";

contract DoppiLiquidityRouter is Ownable, Pausable, ReentrancyGuard, IDoppiLiquidityRouter {
    using SafeERC20 for IERC20;

    IDoppiLiquidity public immutable doppiLP;
    IERC7575 public immutable entryPointA;
    IERC7575 public immutable entryPointB;
    address public immutable assetA;
    address public immutable assetB;

    event Deposited(address indexed user, uint256 amount, address asset, uint256 shares);
    event Redeemed(address indexed user, uint256 shares, uint256 assetsA, uint256 assetsB);
    
    constructor(IERC20 _assetA, IERC20 _assetB, IDoppiLiquidity _doppiLP) Ownable(msg.sender) {
        doppiLP = _doppiLP;
        entryPointA = new EntryPointAssetA(_assetA, IShares(address(_doppiLP)), address(this));
        entryPointB = new EntryPointAssetB(_assetB, IShares(address(_doppiLP)), address(this));
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
        emit Deposited(msg.sender, _amount, _asset, shares);
    }

    function redeem(uint256 _shares) external nonReentrant returns (uint256 assetsA, uint256 assetsB) {
        IERC20(doppiLP).safeTransferFrom(msg.sender, address(this), _shares);
        (uint256 ratioA, uint256 ratioB) = entryPointB.assetRatio();
        uint256 firstHalf = _shares * ratioA / (ratioA + ratioB);
        uint256 secondHalf = _shares - firstHalf;        
        assetsA = entryPointA.redeem(firstHalf, msg.sender, address(this));
        assetsB = entryPointB.redeem(secondHalf, msg.sender, address(this));
        emit Redeemed(msg.sender, _shares, assetsA, assetsB);
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }
}

contract EntryPointAssetA is ERC7575 {
    
    address public immutable router;
    
    constructor(IERC20 _asset, IShares _share, address _router) ERC7575(_asset, _share) {
        router = _router;
    }

    function deposit(uint256 assets, address receiver) public override onlyRouter returns (uint256) {
        return super.deposit(assets, receiver);
    }
    
    function redeem(uint256 shares, address receiver, address owner) public override onlyRouter returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    function mint(uint256 shares, address receiver) public override onlyRouter returns (uint256) {
        revert("Mint not supported");
    }

    function withdraw(uint256 assets, address receiver, address owner) public override onlyRouter returns (uint256) {
        revert("Withdraw not supported");
    }

    function totalAssets() public view override returns (uint256) {
        return IDoppiLiquidity(shareToken()).totalAssetsInAssetA();
    }

    function assetRatio() public view returns (uint256, uint256) {
        return IDoppiLiquidity(shareToken()).assetRatio();
    }

    modifier onlyRouter() {
        require(msg.sender == router, "Only router can call");
        _;
    }
}

contract EntryPointAssetB is ERC7575 {
    
    address public immutable router;
    
    constructor(IERC20 _asset, IShares _share, address _router) ERC7575(_asset, _share) {
        router = _router;
    }

    function deposit(uint256 assets, address receiver) public override onlyRouter returns (uint256) {
        return super.deposit(assets, receiver);
    }
    
    function redeem(uint256 shares, address receiver, address owner) public override onlyRouter returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    function mint(uint256 shares, address receiver) public override onlyRouter returns (uint256) {
        revert("Mint not supported");
    }

    function withdraw(uint256 assets, address receiver, address owner) public override onlyRouter returns (uint256) {
        revert("Withdraw not supported");
    }

    function totalAssets() public view override returns (uint256) {
        return IDoppiLiquidity(shareToken()).totalAssetsInAssetB();
    }

    function assetRatio() public view returns (uint256, uint256) {
        return IDoppiLiquidity(shareToken()).assetRatio();
    }

    modifier onlyRouter() {
        require(msg.sender == router, "Only router can call");
        _;
    }
}