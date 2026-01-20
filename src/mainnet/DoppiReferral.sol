// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
DoppiReferral

- Users can self-register a first-level referrer (registerReferrer).
- The contract tracks monthly trading volume per trader (recorded by an oracle).
- When distributing referral rewards, level-1 always gets its share (if present).
  Level-2 (referrer of level-1) only gets paid for a given trader if that trader's
  volume in the current month >= MIN_VOLUME_FOR_L2.
- Rewards are paid in an ERC20 token.
- Owner can set oracle, reward token, and basis point rates for L1 and L2.
*/

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DoppiPoints} from "./DoppiPoints.sol";
// import "forge-std/console.sol";

contract DoppiReferral is Ownable {
    using SafeERC20 for IERC20;

    struct ReferralInfo {
        // address referrer;
        uint24 claimedMonthId;
        uint256 claimedLevel1;
        uint256 claimedLevel2;
        uint256 claimedLevel3;
    }

    // --- Configurable ---
    DoppiPoints public immutable doppiPoints;
    address public doppiClaim;
    uint256 public constant MAX_L1_REFEREES = 20;    // Max direct referees per user
    uint256 public constant MAX_L2_PER_L1 = 5;       // Max L2 referees per L1 referee
    uint256 public constant MAX_L3_PER_L2 = 1;       // Max L3 referees per L2 referee
    uint16 public LEVEL1_REWARD_BP = 150; // 1.5%
    uint16 public LEVEL2_REWARD_BP = 100; // 1.0%
    uint16 public LEVEL3_REWARD_BP = 50; // 0.5%
    uint16 public constant BP_DENOMINATOR = 10000;
    uint256 public MIN_VOLUME_FOR_L2 = 500_000 ether;
    uint256 public MIN_VOLUME_FOR_L3 = 1_000_000 ether;
    uint32 public constant startTimestamp = 1735689600; // Jan 1, 2025

    // --- Referral state ---
    mapping(address => ReferralInfo) public referrals; // trader => referrer
    // referral code system
    mapping(address => address) public refereeToReferrer; // who is my upline
    mapping(bytes32 => address) public referralCodeToAddress; // code => referrer
    mapping(address => bytes32) public addressToReferralCode; // ensures unique codes
    mapping(address => address[]) public directReferees; // NEW: downline tracking
    

    // --- Events ---
    event ReferrerRegistered(address indexed user, address indexed referrer);
    event ReferrerCodeRegistered(address indexed user, bytes32 code);
    event Claimed(address indexed referrer, uint256 level1Reward, uint256 level2Reward, uint256 level3Reward, uint24 claimedMonthId);
    
    constructor(
        address _doppiPoints, 
        uint16 _l1Bps, 
        uint16 _l2Bps, 
        uint16 _l3Bps
    ) Ownable(msg.sender) {
        require(_l1Bps + _l2Bps + _l3Bps <= BP_DENOMINATOR, "bps sum too large");
        doppiPoints = DoppiPoints(_doppiPoints);
        LEVEL1_REWARD_BP = _l1Bps;
        LEVEL2_REWARD_BP = _l2Bps;
        LEVEL3_REWARD_BP = _l3Bps;
    }

    // -----------------------
    // Referral code setup
    // -----------------------
    /// @notice A user generates their referral code once.
    function registerReferralCode(bytes32 code) external {
        require(code != bytes32(0), "invalid code");
        require(referralCodeToAddress[code] == address(0), "code already used");
        require(addressToReferralCode[msg.sender] == bytes32(0), "already registered");

        referralCodeToAddress[code] = msg.sender;
        addressToReferralCode[msg.sender] = code;

        referrals[msg.sender] = ReferralInfo({
            claimedMonthId: _currentMonthId() - 1,
            claimedLevel1: 0,
            claimedLevel2: 0,
            claimedLevel3: 0
        });

        emit ReferrerCodeRegistered(msg.sender, code);
    }

    // -----------------------
    // Referral registration
    // -----------------------
    /// @notice Register your first-level referrer. Can only be set once and cannot be self.
    function registerReferrer(bytes32 refCode) external {

        address referrer = referralCodeToAddress[refCode];
        require(referrer != address(0), "invalid referral code");
        require(referrer != msg.sender, "cannot refer self");
        require(refereeToReferrer[msg.sender] == address(0), "already register");
        require(!_isInDownlineRecursive(msg.sender, referrer), "cannot register under your downline");
        require(directReferees[msg.sender].length == 0, "cannot register upline");
        require(directReferees[referrer].length < MAX_L1_REFEREES, "reached maximum L1 referees");

        directReferees[referrer].push(msg.sender); 
        refereeToReferrer[msg.sender] = referrer;
        emit ReferrerRegistered(msg.sender, referrer);
    }

    function getReferees(address trader)
        external
        view
        returns (
            address upline,
            address[] memory level1Referees, 
            address[] memory level2Referees, 
            address[] memory level3Referees
        )
    {
        upline = refereeToReferrer[trader];
        address[] memory level1Refs = directReferees[trader];
        level1Referees = new address[](level1Refs.length);

        // First pass: count totals
        uint256 totalLevel2 = 0;
        uint256 totalLevel3 = 0;

        for (uint256 i = 0; i < level1Refs.length; i++) {
            level1Referees[i] = level1Refs[i];
            
            address[] memory level2Refs = directReferees[level1Refs[i]];
            totalLevel2 += level2Refs.length > MAX_L2_PER_L1 ? MAX_L2_PER_L1 : level2Refs.length;
            
            for (uint256 j = 0; j < level2Refs.length; j++) {
                address[] memory level3Refs = directReferees[level2Refs[j]];
                totalLevel3 += level3Refs.length > MAX_L3_PER_L2 ? MAX_L3_PER_L2 : level3Refs.length;
            }
        }

         // Create properly sized arrays
        level2Referees = new address[](totalLevel2);
        level3Referees = new address[](totalLevel3);

         // Second pass: fill arrays
        uint256 level2Index = 0;
        uint256 level3Index = 0;

        for (uint256 i = 0; i < level1Refs.length; i++) {
            address[] memory level2Refs = directReferees[level1Refs[i]];
            
            for (uint256 j = 0; j < totalLevel2; j++) {
                level2Referees[level2Index] = level2Refs[j];
                level2Index++;
                
                address[] memory level3Refs = directReferees[level2Refs[j]];
                for (uint256 k = 0; k < totalLevel3; k++) {
                    level3Referees[level3Index] = level3Refs[k];
                    level3Index++;
                }
            }
        }
    }

    function getReferralRewardsByMonthId(address trader, uint24 monthId) external view
        returns (uint256 totalL1, uint256 totalL2, uint256 totalL3) 
    {
        (totalL1, totalL2, totalL3) = _calculateRewardsForMonth(trader, monthId);
    }

    /// @notice Get all pending rewards earned by `referrer` from their downline
    function getTotalReferralRewards(address trader)
        external
        view
        returns (
            uint256 totalL1, uint256 totalL2, uint256 totalL3,
            uint256 currentL1, uint256 currentL2, uint256 currentL3
        )
    {
        return _getTotalReferralRewards(trader);
    }

    function resetClaimsByMonthId(address referrer, uint24 monthId) external onlyDoppiClaim {
        uint24 currentMonthId = _currentMonthId();
        ReferralInfo storage ref = referrals[referrer];
        uint24 claimedMonth = ref.claimedMonthId;
        require(addressToReferralCode[referrer] != bytes32(0), "not registered");
        require(claimedMonth + 1 == monthId, "should claimed earlier month");
        require(currentMonthId > ref.claimedMonthId + 1, "still in current month");
        
        // Only reset if we're in a new month
        if (currentMonthId > ref.claimedMonthId + 1) {
            (uint256 level1Reward, uint256 level2Reward, uint256 level3Reward) = _calculateRewardsForMonth(referrer, monthId);
            ref.claimedLevel1 += level1Reward;
            ref.claimedLevel2 += level2Reward;
            ref.claimedLevel3 += level3Reward;
            ref.claimedMonthId = monthId; // Claim up to previous month
            emit Claimed(referrer, level1Reward, level2Reward, level3Reward, ref.claimedMonthId);
        }
    }

    function resetClaims(address referrer) external onlyDoppiClaim {
        uint24 currentMonthId = _currentMonthId();
        ReferralInfo storage ref = referrals[referrer];
        require(addressToReferralCode[referrer] != bytes32(0), "not registered");
        require(currentMonthId > ref.claimedMonthId + 1, "still in current month");
        
        // Only reset if we're in a new month
        if (currentMonthId > ref.claimedMonthId + 1) {
            (uint256 level1Reward, uint256 level2Reward, uint256 level3Reward,,,) = 
                _getTotalReferralRewards(referrer);
            
            ref.claimedLevel1 += level1Reward;
            ref.claimedLevel2 += level2Reward;
            ref.claimedLevel3 += level3Reward;
            ref.claimedMonthId = currentMonthId - 1; // Claim up to previous month
            emit Claimed(referrer, level1Reward, level2Reward, level3Reward, ref.claimedMonthId);
        }
    }

    function getReferralInfo(address user) external view returns (ReferralInfo memory) {
        return referrals[user];
    }

    function getUnclaimedMonthId(address user) external view returns (uint24 start, uint24 current) {
        ReferralInfo memory refinfo = referrals[user];
        current = _currentMonthId();
        start = refinfo.claimedMonthId + 1;
    }

    // internal function 
    function _isInDownlineRecursive(address user, address target) internal view returns (bool) {
        if (user == target) return true;
        
        address[] memory referees = directReferees[user];
        for (uint256 i = 0; i < referees.length; i++) {
            if (_isInDownlineRecursive(referees[i], target)) {
                return true;
            }
        }
        return false;
    }

    function _getTotalReferralRewards(address referrer)
        internal
        view
        returns (
            uint256 totalL1, uint256 totalL2, uint256 totalL3,
            uint256 currentL1, uint256 currentL2, uint256 currentL3
            )
    {
        ReferralInfo memory ref = referrals[referrer];
        uint24 currentMonthId = _currentMonthId();
        
        (currentL1, currentL2, currentL3) = _calculateRewardsForMonth(referrer, currentMonthId);
            
        uint24 startMonthId = ref.claimedMonthId + 1;
        // Only calculate for completed months (exclude current month)
        uint24 endMonthId = currentMonthId - 1;

        for (uint24 monthId = startMonthId; monthId <= endMonthId; monthId++) {
            (uint256 l1, uint256 l2, uint256 l3) = _calculateRewardsForMonth(referrer, monthId);
            totalL1 += l1;
            totalL2 += l2;
            totalL3 += l3;
        }
    }

    function _calculateRewardsForMonth(address referrer, uint24 monthId)
        internal
        view
        returns (uint256 l1, uint256 l2, uint256 l3)
    {
        address[] memory level1Refs = directReferees[referrer];
        
        for (uint256 i = 0; i < level1Refs.length; i++) {
            address level1Ref = level1Refs[i];
            uint256 vol1 = doppiPoints.getMonthlyVolume(level1Ref, monthId);
            
            if (vol1 > 0) {
                l1 += (vol1 * LEVEL1_REWARD_BP) / BP_DENOMINATOR;
            }

            // Level 2 rewards
            address[] memory level2Refs = directReferees[level1Ref];
            uint256 totalL2 = level2Refs.length > MAX_L2_PER_L1 ? MAX_L2_PER_L1 : level2Refs.length;
            for (uint256 j = 0; j < totalL2; j++) {
                address level2Ref = level2Refs[j];
                uint256 vol2 = doppiPoints.getMonthlyVolume(level2Ref, monthId);
                
                if (vol2 >= MIN_VOLUME_FOR_L2) {
                    l2 += (vol2 * LEVEL2_REWARD_BP) / BP_DENOMINATOR;
                }

                // Level 3 rewards
                address[] memory level3Refs = directReferees[level2Ref];
                uint256 totalL3 = level3Refs.length > MAX_L3_PER_L2 ? MAX_L3_PER_L2 : level3Refs.length;
                for (uint256 k = 0; k < totalL3; k++) {
                    address level3Ref = level3Refs[k];
                    uint256 vol3 = doppiPoints.getMonthlyVolume(level3Ref, monthId);
                    
                    if (vol3 >= MIN_VOLUME_FOR_L3) {
                        l3 += (vol3 * LEVEL3_REWARD_BP) / BP_DENOMINATOR;
                    }
                }
            }
        }
    }

    function _currentMonthId() internal view returns (uint24) {
        // 30-day rolling months
        return uint24((block.timestamp - startTimestamp) / 30 days);
    }
    
    // -----------------------
    // Admin functions
    // -----------------------

    /// @notice Set level1 and level2 rates in basis points. Sum should not exceed 10000.
    function setRates(uint16 _level1Bps, uint16 _level2Bps, uint16 _level3Bps) external onlyOwner {
        require(_level1Bps + _level2Bps + _level3Bps <= BP_DENOMINATOR, "bps sum too large");
        LEVEL1_REWARD_BP = _level1Bps;
        LEVEL2_REWARD_BP = _level2Bps;
        LEVEL3_REWARD_BP = _level3Bps;
    }

    function setMinVolumeForL2(uint256 _minL2, uint256 _minL3) external onlyOwner {
        MIN_VOLUME_FOR_L2 = _minL2;
        MIN_VOLUME_FOR_L3 = _minL3;
    }

    function setDoppiClaim(address _doppiClaim) external onlyOwner {
        doppiClaim = _doppiClaim;
    }

    modifier onlyDoppiClaim() {
        require(msg.sender == doppiClaim, "only doppiClaim");
        _;
    }
}
