// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IShares} from "../Interface/IShares.sol";
import {IERC7575, ERC7575} from "./ERC7575.sol";
// import "forge-std/console.sol";

contract DoppiLiquidityRouter is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public doppiCore;
    IDoppiLiquidity public immutable doppiLP;
    IERC7575 public immutable entryPointA;
    IERC7575 public immutable entryPointB;
    address public immutable assetA;
    address public immutable assetB;
    bool public emergencyMode;
    bool public publicOpen = true;

    event Deposited(address indexed user, uint256 amount, address asset, uint256 shares);
    event Redeemed(address indexed user, uint256 shares, uint256 assetsA, uint256 assetsB);
    event EmergencyWithdraw(address indexed user, uint256 shares, uint256 assetsA, uint256 assetsB);
    
    constructor(IERC20 _assetA, IERC20 _assetB, IDoppiLiquidity _doppiLP) Ownable(msg.sender) {
        doppiLP = _doppiLP;
        entryPointA = new EntryPointAssetA(_assetA, IShares(address(_doppiLP)), address(this));
        entryPointB = new EntryPointAssetB(_assetB, IShares(address(_doppiLP)), address(this));
        assetA = address(_assetA);
        assetB = address(_assetB);
    }

    function deposit(address _asset, uint256 _amount) external whenOpen nonReentrant whenNotPaused returns (uint256 shares) {
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

    function redeem(uint256 _shares) external nonReentrant whenNotPaused returns (uint256 assetsA, uint256 assetsB) {
        
        uint256 maxWithdrawable = getWithdrawableAmount(msg.sender);
        require(_shares <= maxWithdrawable, "exceeds available capacity");
        (assetsA, assetsB) = _redeem(_shares);
        emit Redeemed(msg.sender, _shares, assetsA, assetsB);
    }

    function emergencyWithdraw() external whenEmergency whenPaused nonReentrant {
        uint256 userShares = doppiLP.balanceOf(msg.sender);
        require(userShares > 0, "No shares to withdraw");   

        uint256 maxWithdrawable = getWithdrawableAmount(msg.sender);
        uint256 sharesToWithdraw = userShares < maxWithdrawable ? userShares : maxWithdrawable;

        (uint256 assetsA, uint256 assetsB) = _redeem(sharesToWithdraw);
        emit EmergencyWithdraw(msg.sender, sharesToWithdraw, assetsA, assetsB);
    }

    function isEmergency() external view returns (bool) {
        return emergencyMode;
    }

    function setDoppiCore(address _doppiCore) external onlyOwner {
        doppiCore = _doppiCore;
    }

    function setEmergencyMode(bool _emergency) external whenPaused onlyOwner {
        emergencyMode = _emergency;
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }

    function getWithdrawableAmount(address user) public view returns (uint256 maxWithdrawable) {
        uint256 userShares = doppiLP.balanceOf(user);
        uint256 totalShares = doppiLP.totalSupply();
        
        if (totalShares == 0) return 0;
        
        // Get total assets in A
        uint256 totalPoolAssetsInA = doppiLP.totalAssetsInAssetA();
        
        // Get total interest liabilities from DoppiCore
        uint256 price = doppiLP.getPrice();
        (uint256 interestLiabilityA, uint256 interestLiabilityB) = _getTotalInterestLiabilities();

        uint256 liabilityBInA = interestLiabilityB * price / (10 ** doppiLP.getPriceDecimals());
        uint256 totalLiability = liabilityBInA + interestLiabilityA;

        // Calculate required reserves (liabilities + safety margin)
        uint256 requiredReserve = totalLiability * 11000 / 10000; // 10% safety margin
        if (requiredReserve >= totalPoolAssetsInA) {
            return 0; 
        }

        // Calculate available assets after reserving for liabilities
        if (totalPoolAssetsInA <= requiredReserve) {
            return 0;
        }
        uint256 availableAsset = totalPoolAssetsInA - requiredReserve;
        maxWithdrawable = (availableAsset * userShares) / totalPoolAssetsInA;

        if (maxWithdrawable > userShares) {
            maxWithdrawable = userShares;
        }
    }

    modifier whenEmergency() {
        require(emergencyMode, "Not in emergency mode");
        _;
    }

    modifier whenOpen() {
        require(publicOpen == true, "not open");
        _;
    }

    // internal
    function _getTotalInterestLiabilities() internal view returns (uint256 liabilityA, uint256 liabilityB) {
        
        (bool success, bytes memory data) = doppiCore.staticcall(abi.encodeWithSignature("getInterestLiabilities()"));
        if (success && data.length == 64) {
            (liabilityA, liabilityB) = abi.decode(data, (uint256, uint256));
        }
    }

    function _redeem(uint256 _shares) internal returns (uint256 assetsA, uint256 assetsB) {

        IERC20(doppiLP).safeTransferFrom(msg.sender, address(this), _shares);
        (uint256 ratioA, uint256 ratioB) = doppiLP.assetRatio();
        uint256 firstHalf = _shares * ratioA / (ratioA + ratioB);
        uint256 secondHalf = _shares - firstHalf;        
        assetsA = entryPointA.redeem(firstHalf, msg.sender, address(this));
        assetsB = entryPointB.redeem(secondHalf, msg.sender, address(this));
        doppiLP.cleanUpUnwind(assetsA, assetsB);
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

    function mint(uint256 shares, address receiver) public pure override returns (uint256) {
        revert("Mint not supported");
    }

    function withdraw(uint256 assets, address receiver, address owner) public pure override returns (uint256) {
        revert("Withdraw not supported");
    }

    function totalAssets() public view override returns (uint256) {
        return IDoppiLiquidity(shareToken()).totalAssetsInAssetA();
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

    function mint(uint256 shares, address receiver) public override pure returns (uint256) {
        revert("Mint not supported");
    }

    function withdraw(uint256 assets, address receiver, address owner) public override pure returns (uint256) {
        revert("Withdraw not supported");
    }

    function totalAssets() public view override returns (uint256) {
        return IDoppiLiquidity(shareToken()).totalAssetsInAssetB();
    }

    modifier onlyRouter() {
        require(msg.sender == router, "Only router can call");
        _;
    }
}