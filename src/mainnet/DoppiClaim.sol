// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "forge-std/console.sol";

interface IDoppiToken {
    function mint(address to, uint256 amount) external;
    function decimals() external view returns (uint8);
}

interface IDoppiPoints {
    function getPoints(address user) external view returns (uint256, uint256);
    function resetPoint(address user) external;
}

interface IDoppiReferral {
    function getTotalReferralRewards(address user)
        external
        view
        returns (uint256 totalL1, uint256 totalL2, uint256 totalL3);
    function resetClaims(address user) external;
}

contract DoppiClaim is Ownable, Pausable, ReentrancyGuard {
    IDoppiToken public immutable doppiToken;
    IDoppiPoints public immutable doppiPoints;
    IDoppiReferral public immutable doppiReferral;

    /// Tokens per point (in DoppiToken decimals, e.g. 1e18 = 1 token per point if token has 18 decimals)
    uint256 public tokensPerPoint;

    event Claimed(
        address indexed user,
        uint256 tradePoints,
        uint256 referralL1,
        uint256 referralL2,
        uint256 referralL3,
        uint256 mintedAmount
    );

    constructor(
        address _doppiToken,
        address _doppiPoints,
        address _doppiReferral,
        uint256 _tokensPerPoint
    ) Ownable(msg.sender) {
        require(_doppiToken != address(0), "token=0");
        require(_doppiPoints != address(0), "points=0");
        require(_doppiReferral != address(0), "referral=0");

        doppiToken = IDoppiToken(_doppiToken);
        doppiPoints = IDoppiPoints(_doppiPoints);
        doppiReferral = IDoppiReferral(_doppiReferral);
        tokensPerPoint = _tokensPerPoint;
    }

    function claim() external whenNotPaused nonReentrant {
        address user = msg.sender;

        (uint256 points, ) = doppiPoints.getPoints(user);
        (uint256 l1, uint256 l2, uint256 l3) = doppiReferral.getTotalReferralRewards(user);

        uint256 totalPoints = points + l1 + l2 + l3;
        require(totalPoints > 0, "no points to claim");

        uint256 mintAmount = totalPoints * tokensPerPoint;

        doppiPoints.resetPoint(user);
        doppiReferral.resetClaims(user);
        doppiToken.mint(user, mintAmount);

        emit Claimed(user, points, l1, l2, l3, mintAmount);
    }

    // --- Admin functions ---
    function setTokensPerPoint(uint256 _tokensPerPoint) external onlyOwner {
        tokensPerPoint = _tokensPerPoint;
    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }
}
