// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// import "forge-std/console.sol";

interface IDoppiToken {
    function mint(address to, uint256 amount) external;
    function decimals() external view returns (uint8);
}

interface IDoppiPoints {
    function getCurrentMonthId() external view returns (uint256);
    function getMonthlyVolume(address trader, uint24 monthId) external view returns (uint256);
    function claimedPoint(address trader) external view returns (uint24 claimedMonthId, uint256 totalPointClaimed);
    function resetPoint(address user) external;
    function getAllPointData(
        address trader
    )
        external
        view
        returns (
            uint256 totalClaimedPoint,
            uint256 readyPoint,
            uint256 currentMonthPoint
        );
}

interface IDoppiReferral {
    function getReferralRewardsByMonthId(address trader, uint24 monthId)
        external
        view
        returns (uint256 totalL1, uint256 totalL2, uint256 totalL3);

    function getUnclaimedMonthId(address user) external view returns (uint24 start, uint24 current);

    function getTotalReferralRewards(
        address user
    )
        external
        view
        returns (
            uint256 totalL1,
            uint256 totalL2,
            uint256 totalL3,
            uint256 currentL1,
            uint256 currentL2,
            uint256 currentL3
        );
    function resetClaims(address user) external;
}

contract DoppiClaim is Ownable, Pausable, ReentrancyGuard {
    struct RateCheckpoint {
        uint24 effectiveMonthId;
        uint16 rate;
    }

    IDoppiToken public immutable doppiToken;
    IDoppiPoints public immutable doppiPoints;
    IDoppiReferral public immutable doppiReferral;

    uint16 public tokensPerPoint; // in bps. 10000 if 1:1
    uint16 private constant BASIS_POINTS = 10000;
    RateCheckpoint[] private rateCheckpoints;
    
    event Claimed(
        address indexed user,
        uint256 tradePoints,
        uint256 referralL1,
        uint256 referralL2,
        uint256 referralL3,
        uint256 mintedAmount
    );
    event TokensPerPointScheduled(uint16 oldRate, uint16 newRate, uint24 effectiveMonthId);

    constructor(
        address _doppiToken,
        address _doppiPoints,
        address _doppiReferral,
        uint16 _tokensPerPoint
    ) Ownable(msg.sender) {
        require(_doppiToken != address(0), "token=0");
        require(_doppiPoints != address(0), "points=0");
        require(_doppiReferral != address(0), "referral=0");
        require(_tokensPerPoint > 0, "invalid rate");

        doppiToken = IDoppiToken(_doppiToken);
        doppiPoints = IDoppiPoints(_doppiPoints);
        doppiReferral = IDoppiReferral(_doppiReferral);
        tokensPerPoint = _tokensPerPoint;
        rateCheckpoints.push(RateCheckpoint({effectiveMonthId: 0, rate: _tokensPerPoint}));
    }

    function claimTradingPoint() external whenNotPaused nonReentrant {
        address user = msg.sender;
        (uint256 readyPoint, uint256 mintAmount) = _getClaimableTrading(user);
        require(readyPoint > 0, "no points to claim");
        require(mintAmount > 0, "mint amount too small");
        doppiPoints.resetPoint(user);
        doppiToken.mint(user, mintAmount);
        emit Claimed(user, readyPoint, 0, 0, 0, mintAmount);
    }

    function claimReferralPoint() external whenNotPaused nonReentrant {
        address user = msg.sender;

        (uint256 l1, uint256 l2, uint256 l3, uint256 totalPoints, uint256 mintAmount) = _getClaimableReferral(user);
        require(totalPoints > 0, "no points to claim");
        require(mintAmount > 0, "mint amount too small");

        doppiReferral.resetClaims(user);
        doppiToken.mint(user, mintAmount);

        emit Claimed(user, 0, l1, l2, l3, mintAmount);
    }

    function getMyReferralPointToToken(address _user) external view returns (uint256) {
        (, , , , uint256 mintAmount) = _getClaimableReferral(_user);
        return mintAmount;
    }

    function getMyTradingPointToToken(address _user) external view returns (uint256) {
        (, uint256 mintAmount) = _getClaimableTrading(_user);
        return mintAmount;
    }

    function getTokensPerPointForMonth(uint24 monthId) external view returns (uint16) {
        return _rateForMonth(monthId);
    }

    function getRateCheckpointCount() external view returns (uint256) {
        return rateCheckpoints.length;
    }

    function getRateCheckpoint(uint256 index) external view returns (uint24 effectiveMonthId, uint16 rate) {
        RateCheckpoint memory cp = rateCheckpoints[index];
        return (cp.effectiveMonthId, cp.rate);
    }

    // --- Admin functions ---
    function setTokensPerPoint(uint16 _tokensPerPoint) external onlyOwner {
        require(_tokensPerPoint > 0, "invalid rate");

        uint24 effectiveMonthId = uint24(doppiPoints.getCurrentMonthId()) + 1;
        uint16 oldRate = _rateForMonth(effectiveMonthId);

        uint256 len = rateCheckpoints.length;
        if (len > 0 && rateCheckpoints[len - 1].effectiveMonthId == effectiveMonthId) {
            rateCheckpoints[len - 1].rate = _tokensPerPoint;
        } else {
            rateCheckpoints.push(RateCheckpoint({effectiveMonthId: effectiveMonthId, rate: _tokensPerPoint}));
        }

        tokensPerPoint = _tokensPerPoint;
        emit TokensPerPointScheduled(oldRate, _tokensPerPoint, effectiveMonthId);
    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    function _getClaimableTrading(address user) internal view returns (uint256 totalPoints, uint256 mintAmount) {
        (uint24 claimedMonthId, ) = doppiPoints.claimedPoint(user);
        uint24 currentMonthId = uint24(doppiPoints.getCurrentMonthId());

        uint24 startMonthId = claimedMonthId + 1;
        if (startMonthId >= currentMonthId) {
            return (0, 0);
        }

        for (uint24 monthId = startMonthId; monthId < currentMonthId; monthId++) {
            uint256 monthlyPoint = doppiPoints.getMonthlyVolume(user, monthId);
            if (monthlyPoint == 0) continue;

            totalPoints += monthlyPoint;
            mintAmount += (monthlyPoint * _rateForMonth(monthId)) / BASIS_POINTS;
        }
    }

    function _getClaimableReferral(address user)
        internal
        view
        returns (uint256 l1Total, uint256 l2Total, uint256 l3Total, uint256 totalPoints, uint256 mintAmount)
    {
        (uint24 startMonthId, uint24 currentMonthId) = doppiReferral.getUnclaimedMonthId(user);
        if (startMonthId >= currentMonthId) {
            return (0, 0, 0, 0, 0);
        }

        for (uint24 monthId = startMonthId; monthId < currentMonthId; monthId++) {
            (uint256 l1, uint256 l2, uint256 l3) = doppiReferral.getReferralRewardsByMonthId(user, monthId);
            uint256 monthlyPoint = l1 + l2 + l3;
            if (monthlyPoint == 0) continue;

            l1Total += l1;
            l2Total += l2;
            l3Total += l3;
            totalPoints += monthlyPoint;
            mintAmount += (monthlyPoint * _rateForMonth(monthId)) / BASIS_POINTS;
        }
    }

    function _rateForMonth(uint24 monthId) internal view returns (uint16 rate) {
        uint256 len = rateCheckpoints.length;
        if (len == 0) return tokensPerPoint;

        for (uint256 i = len; i > 0; ) {
            unchecked { --i; }
            RateCheckpoint memory cp = rateCheckpoints[i];
            if (monthId >= cp.effectiveMonthId) {
                return cp.rate;
            }
        }

        return rateCheckpoints[0].rate;
    }
}
