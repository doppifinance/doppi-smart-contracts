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

    struct RateCheckpoint {
        uint24 effectiveMonthId;
        uint16 level1Bps;
        uint16 level2Bps;
        uint16 level3Bps;
    }

    struct MinVolumeCheckpoint {
        uint24 effectiveMonthId;
        uint256 minL2;
        uint256 minL3;
    }

    // --- Configurable ---
    DoppiPoints public immutable doppiPoints;
    address public doppiClaim;
    uint16 public LEVEL1_REWARD_BP = 150; // 1.5% (current, for display)
    uint16 public LEVEL2_REWARD_BP = 100; // 1.0% (current, for display)
    uint16 public LEVEL3_REWARD_BP = 50; // 0.5% (current, for display)
    uint16 public constant BP_DENOMINATOR = 10000;
    uint256 public MIN_VOLUME_FOR_L2 = 500_000 ether; // (current, for display)
    uint256 public MIN_VOLUME_FOR_L3 = 1_000_000 ether; // (current, for display)
    uint32 public constant startTimestamp = 1735689600; // Jan 1, 2025
    
    RateCheckpoint[] private rateCheckpoints;
    MinVolumeCheckpoint[] private minVolumeCheckpoints;

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
    event RatesScheduled(uint16 oldLvl1, uint16 oldLvl2, uint16 oldLvl3, uint16 newLvl1, uint16 newLvl2, uint16 newLvl3, uint24 effectiveMonthId);
    event MinVolumesScheduled(uint256 oldMinL2, uint256 oldMinL3, uint256 newMinL2, uint256 newMinL3, uint24 effectiveMonthId);
    
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
        
        // Initialize first checkpoint at month 0
        rateCheckpoints.push(RateCheckpoint({
            effectiveMonthId: 0,
            level1Bps: _l1Bps,
            level2Bps: _l2Bps,
            level3Bps: _l3Bps
        }));
        
        // Initialize first min volume checkpoint at month 0
        minVolumeCheckpoints.push(MinVolumeCheckpoint({
            effectiveMonthId: 0,
            minL2: MIN_VOLUME_FOR_L2,
            minL3: MIN_VOLUME_FOR_L3
        }));
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
        require(directReferees[msg.sender].length == 0, "cannot register upline");
        
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
            uint256 capLevel2 = level2Refs.length;
            totalLevel2 += level2Refs.length;

            for (uint256 j = 0; j < capLevel2; j++) {
                address[] memory level3Refs = directReferees[level2Refs[j]];
                uint256 capLevel3 = level3Refs.length;
                totalLevel3 += capLevel3;
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
            uint256 capLevel2 = level2Refs.length;

            for (uint256 j = 0; j < capLevel2; j++) {
                level2Referees[level2Index] = level2Refs[j];
                level2Index++;

                address[] memory level3Refs = directReferees[level2Refs[j]];
                uint256 capLevel3 = level3Refs.length;
                for (uint256 k = 0; k < capLevel3; k++) {
                    level3Referees[level3Index] = level3Refs[k];
                    level3Index++;
                }
            }
        }
    }

    function getReferralRewardsByMonthId(address trader, uint24 monthId) external view
        returns (uint256 totalL1, uint256 totalL2, uint256 totalL3) 
    {
        (totalL1, totalL2, totalL3) = doppiPoints.getReferralVolumeByMonth(trader, monthId);
        (totalL1, totalL2, totalL3) = _appliedMinVol(totalL1, totalL2, totalL3, monthId);
    }

    function getTotalReferralRewards(address trader)
        external
        view
        returns (uint256 totalL1, uint256 totalL2, uint256 totalL3,
                uint256 currentL1, uint256 currentL2, uint256 currentL3)
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
            (uint256 level1Reward, uint256 level2Reward, uint256 level3Reward) = doppiPoints.getReferralVolumeByMonth(referrer, monthId);
            (level1Reward, level2Reward, level3Reward) = _appliedMinVol(level1Reward, level2Reward, level3Reward, monthId);
            ref.claimedLevel1 += level1Reward;
            ref.claimedLevel2 += level2Reward;
            ref.claimedLevel3 += level3Reward;
            ref.claimedMonthId = monthId; // Claim up to previous month
            emit Claimed(referrer, level1Reward, level2Reward, level3Reward, ref.claimedMonthId);
        }
    }

    function resetClaims(address referrer) external onlyDoppiClaim {
        require(addressToReferralCode[referrer] != bytes32(0), "not registered");

        uint24 currentMonthId = _currentMonthId();
        ReferralInfo storage ref = referrals[referrer];
        require(currentMonthId > ref.claimedMonthId + 1, "still in current month");
        // Only reset if we're in a new month
        if (currentMonthId > ref.claimedMonthId + 1) {
            (uint256 totalL1, uint256 totalL2, uint256 totalL3, , , ) = _getTotalReferralRewards(referrer);
            ref.claimedLevel1 += totalL1;
            ref.claimedLevel2 += totalL2;
            ref.claimedLevel3 += totalL3;
            ref.claimedMonthId = currentMonthId - 1;

            emit Claimed(referrer, totalL1, totalL2, totalL3, ref.claimedMonthId);
        }
    }

    function getUplineChain(address trader) external view returns (address l1, address l2, address l3) {
        l1 = refereeToReferrer[trader];
        l2 = refereeToReferrer[l1];
        l3 = refereeToReferrer[l2];
    }

    function getReferralInfo(address user) external view returns (ReferralInfo memory) {
        return referrals[user];
    }

    function getUnclaimedMonthId(address user) external view returns (uint24 start, uint24 current) {
        ReferralInfo memory refinfo = referrals[user];
        current = _currentMonthId();
        start = refinfo.claimedMonthId + 1;
    }

    function getMonthStartTimestamp(uint24 monthId) public pure returns (uint256) {
        return uint256(startTimestamp) + (uint256(monthId) * 30 days);
    }

    function getNextMonthStartTimestamp() external view returns (uint24 nextMonthId, uint256 nextMonthStartTimestamp) {
        nextMonthId = _currentMonthId() + 1;
        nextMonthStartTimestamp = getMonthStartTimestamp(nextMonthId);
    }

    function _getTotalReferralRewards(address trader)
        internal
        view
        returns (uint256 totalL1, uint256 totalL2, uint256 totalL3,
                uint256 currentL1, uint256 currentL2, uint256 currentL3)
    {
        ReferralInfo memory info = referrals[trader];
        uint24 currentMonthId = _currentMonthId();
        // current month (non-claimable yet but returned separately)
        (uint256 currentL1v, uint256 currentL2v, uint256 currentL3v) = doppiPoints.getReferralVolumeByMonth(trader, currentMonthId);
        (currentL1, currentL2, currentL3) = _appliedMinVol(currentL1v, currentL2v, currentL3v, currentMonthId);
        
        // existing claimed months
        uint24 startMonthId = info.claimedMonthId + 1;
        // Only calculate for completed months (exclude current month)
        uint24 endMonthId = currentMonthId - 1;
        for (uint24 monthId = startMonthId; monthId <= endMonthId; monthId++) {
            (uint256 l1v, uint256 l2v, uint256 l3v) = doppiPoints.getReferralVolumeByMonth(trader, monthId);
            (l1v, l2v, l3v) = _appliedMinVol(l1v, l2v, l3v, monthId);
            totalL1 += l1v;
            totalL2 += l2v;
            totalL3 += l3v;
        }
    }

    function _appliedMinVol(uint256 l1, uint256 l2, uint256 l3, uint24 monthId) internal view returns (uint256 totalL1, uint256 totalL2, uint256 totalL3) {
        (uint256 minL2, uint256 minL3) = _minVolForMonth(monthId);
        (uint16 level1Bps, uint16 level2Bps, uint16 level3Bps) = _ratesForMonth(monthId);
        
        totalL1 = (l1 * level1Bps) / BP_DENOMINATOR;
        totalL2 = (l2 >= minL2) ? (l2 * level2Bps) / BP_DENOMINATOR : 0;
        totalL3 = (l3 >= minL3) ? (l3 * level3Bps) / BP_DENOMINATOR : 0;
    }

    function _currentMonthId() internal view returns (uint24) {
        // 30-day rolling months
        return uint24((block.timestamp - startTimestamp) / 30 days);
    }

    function _ratesForMonth(uint24 monthId) internal view returns (uint16 level1Bps, uint16 level2Bps, uint16 level3Bps) {
        // Reverse-scan checkpoints to find rates effective for this month
        uint256 len = rateCheckpoints.length;
        for (uint256 i = len; i > 0; i--) {
            if (rateCheckpoints[i - 1].effectiveMonthId <= monthId) {
                RateCheckpoint memory cp = rateCheckpoints[i - 1];
                return (cp.level1Bps, cp.level2Bps, cp.level3Bps);
            }
        }
        // Should not reach here since we initialize checkpoint at month 0
        return (LEVEL1_REWARD_BP, LEVEL2_REWARD_BP, LEVEL3_REWARD_BP);
    }

    function _minVolForMonth(uint24 monthId) internal view returns (uint256 minL2, uint256 minL3) {
        // Reverse-scan checkpoints to find min volumes effective for this month
        uint256 len = minVolumeCheckpoints.length;
        for (uint256 i = len; i > 0; i--) {
            if (minVolumeCheckpoints[i - 1].effectiveMonthId <= monthId) {
                MinVolumeCheckpoint memory cp = minVolumeCheckpoints[i - 1];
                return (cp.minL2, cp.minL3);
            }
        }
        // Should not reach here since we initialize checkpoint at month 0
        return (MIN_VOLUME_FOR_L2, MIN_VOLUME_FOR_L3);
    }
    
    // -----------------------
    // Admin functions
    // -----------------------

    /// @notice Schedule new referral rates effective from next month. Preserves rates for existing months.
    function setRates(uint16 _level1Bps, uint16 _level2Bps, uint16 _level3Bps) external onlyOwner {
        require(_level1Bps + _level2Bps + _level3Bps <= BP_DENOMINATOR, "bps sum too large");
        
        uint24 effectiveMonthId = _currentMonthId() + 1;
        (uint16 oldL1, uint16 oldL2, uint16 oldL3) = _ratesForMonth(effectiveMonthId);
        
        uint256 len = rateCheckpoints.length;
        if (len > 0 && rateCheckpoints[len - 1].effectiveMonthId == effectiveMonthId) {
            // Overwrite pending update for same month
            rateCheckpoints[len - 1].level1Bps = _level1Bps;
            rateCheckpoints[len - 1].level2Bps = _level2Bps;
            rateCheckpoints[len - 1].level3Bps = _level3Bps;
        } else {
            // Add new checkpoint
            rateCheckpoints.push(RateCheckpoint({
                effectiveMonthId: effectiveMonthId,
                level1Bps: _level1Bps,
                level2Bps: _level2Bps,
                level3Bps: _level3Bps
            }));
        }
        
        // Update current display rates
        LEVEL1_REWARD_BP = _level1Bps;
        LEVEL2_REWARD_BP = _level2Bps;
        LEVEL3_REWARD_BP = _level3Bps;
        
        emit RatesScheduled(oldL1, oldL2, oldL3, _level1Bps, _level2Bps, _level3Bps, effectiveMonthId);
    }

    /// @notice Schedule new minimum volumes effective from next month. Preserves min volumes for existing months.
    function setMinVolumeForL2L3(uint256 _minL2, uint256 _minL3) external onlyOwner {
        uint24 effectiveMonthId = _currentMonthId() + 1;
        (uint256 oldMinL2, uint256 oldMinL3) = _minVolForMonth(effectiveMonthId);
        
        uint256 len = minVolumeCheckpoints.length;
        if (len > 0 && minVolumeCheckpoints[len - 1].effectiveMonthId == effectiveMonthId) {
            // Overwrite pending update for same month
            minVolumeCheckpoints[len - 1].minL2 = _minL2;
            minVolumeCheckpoints[len - 1].minL3 = _minL3;
        } else {
            // Add new checkpoint
            minVolumeCheckpoints.push(MinVolumeCheckpoint({
                effectiveMonthId: effectiveMonthId,
                minL2: _minL2,
                minL3: _minL3
            }));
        }
        
        // Update current display values
        MIN_VOLUME_FOR_L2 = _minL2;
        MIN_VOLUME_FOR_L3 = _minL3;
        
        emit MinVolumesScheduled(oldMinL2, oldMinL3, _minL2, _minL3, effectiveMonthId);
    }

    function setDoppiClaim(address _doppiClaim) external onlyOwner {
        doppiClaim = _doppiClaim;
    }
    
    // --- Public query functions for rate checkpoints ---
    function getRateCheckpointCount() external view returns (uint256) {
        return rateCheckpoints.length;
    }
    
    function getRateCheckpoint(uint256 index) external view returns (uint24 effectiveMonthId, uint16 level1Bps, uint16 level2Bps, uint16 level3Bps) {
        require(index < rateCheckpoints.length, "checkpoint index out of bounds");
        RateCheckpoint memory cp = rateCheckpoints[index];
        return (cp.effectiveMonthId, cp.level1Bps, cp.level2Bps, cp.level3Bps);
    }
    
    function getRatesForMonth(uint24 monthId) external view returns (uint16 level1Bps, uint16 level2Bps, uint16 level3Bps) {
        return _ratesForMonth(monthId);
    }
    
    // --- Public query functions for min volume checkpoints ---
    function getMinVolumeCheckpointCount() external view returns (uint256) {
        return minVolumeCheckpoints.length;
    }
    
    function getMinVolumeCheckpoint(uint256 index) external view returns (uint24 effectiveMonthId, uint256 minL2, uint256 minL3) {
        require(index < minVolumeCheckpoints.length, "checkpoint index out of bounds");
        MinVolumeCheckpoint memory cp = minVolumeCheckpoints[index];
        return (cp.effectiveMonthId, cp.minL2, cp.minL3);
    }
    
    function getMinVolForMonth(uint24 monthId) external view returns (uint256 minL2, uint256 minL3) {
        return _minVolForMonth(monthId);
    }

    modifier onlyDoppiClaim() {
        require(msg.sender == doppiClaim, "only doppiClaim");
        _;
    }
}
