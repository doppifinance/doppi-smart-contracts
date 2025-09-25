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
import "forge-std/console.sol";

contract DoppiReferral is Ownable {
    using SafeERC20 for IERC20;

    struct ReferralInfo {
        // address referrer;
        uint256 claimedMonthId;
        uint256 claimedLevel1;
        uint256 claimedLevel2;
        uint256 claimedLevel3;
    }

    // --- Configurable ---
    DoppiPoints public immutable doppiPoints;
    address public doppiClaim;
    address public oracle;                // who can call recordTrade
    uint256 public LEVEL1_REWARD_BP = 150; // 1.5%
    uint256 public LEVEL2_REWARD_BP = 100; // 1.0%
    uint256 public LEVEL3_REWARD_BP = 50; // 0.5%
    uint256 public constant BP_DENOMINATOR = 10000;
    uint256 public MIN_VOLUME_FOR_L2 = 500_000 ether;
    uint256 public MIN_VOLUME_FOR_L3 = 1_000_000 ether;

    // --- Referral state ---
    mapping(address => ReferralInfo) public referrals; // trader => referrer
    mapping(address => uint256) public pendingRewards; // claimable rewards
    mapping(address => uint256) public referredCount;
    // referral code system
    mapping(bytes32 => address) public referralCodeToAddress; // code => referrer
    mapping(address => bytes32) public addressToReferralCode; // ensures unique codes
    mapping(address => address[]) public directReferees; // NEW: downline tracking

    // --- Events ---
    event ReferrerRegistered(address indexed user, address indexed referrer);
    event ReferrerCodeRegistered(address indexed user, bytes32 code);

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

        referrals[referrer] = ReferralInfo({
            claimedMonthId: 0,
            claimedLevel1: 0,
            claimedLevel2: 0,
            claimedLevel3: 0
        });

        referredCount[referrer] += 1;
        directReferees[referrer].push(msg.sender); 
        emit ReferrerRegistered(msg.sender, referrer);
    }

    /// @notice Get all pending rewards earned by `referrer` from their downline
    function getTotalReferralRewards(address trader)
        external
        view
        returns (uint256 totalL1, uint256 totalL2, uint256 totalL3)
    {
        return _getTotalReferralRewards(trader);
    }

    function resetClaims(address trader) external onlyDoppiClaim {

        uint256[] memory monthIds = doppiPoints.getMonthIds();
        if(monthIds.length == 0) return; 
        uint256 previousMonthId = monthIds.length > 2 ? monthIds[monthIds.length - 2] : monthIds[monthIds.length - 1];
        // console.log("resetClaims", previousMonthId, _currentMonthId());
        if(previousMonthId == _currentMonthId()) return;
        (uint256 level1Reward, uint256 level2Reward, uint256 level3Reward) 
        = _getTotalReferralRewards(trader);
        // console.log(level1Reward, level2Reward, level3Reward);
        referrals[trader].claimedMonthId = previousMonthId;
        referrals[trader].claimedLevel1 += level1Reward;
        referrals[trader].claimedLevel2 += level2Reward;
        referrals[trader].claimedLevel3 += level3Reward;
    }

    function getReferralInfo(address user) external view returns (ReferralInfo memory) {
        return referrals[user];
    }

    // internal function 
    function _getTotalReferralRewards(address referrer)
        internal
        view
        returns (uint256 totalL1, uint256 totalL2, uint256 totalL3)
    {
        ReferralInfo memory ref = referrals[referrer];
        
        uint256 currentMonthId = _currentMonthId();
        uint256[] memory monthIds = doppiPoints.getMonthIds();
        uint256 len = monthIds.length;
        
        // do not process the current active monthId
        for (uint256 i = 0; i < len; ) {
            uint256 monthId = monthIds[i];
            // console.log(monthId, ref.claimedMonthId, currentMonthId);
            if(monthId > ref.claimedMonthId && monthId < currentMonthId){
                // --- Level 1 ---
                address[] memory level1Refs = directReferees[referrer];
                for (uint256 j = 0; j < level1Refs.length; ) {
                    uint256 vol1 = doppiPoints.getMonthlyVolume(level1Refs[j], monthId);
                    if (vol1 > 0) {
                        totalL1 += (vol1 * LEVEL1_REWARD_BP) / BP_DENOMINATOR;
                    }

                    // --- Level 2 ---
                    address[] memory level2Refs = directReferees[level1Refs[j]];
                    for (uint256 k = 0; k < level2Refs.length; ) {
                        uint256 vol2 = doppiPoints.getMonthlyVolume(level2Refs[k], monthId);
                        if (vol2 >= MIN_VOLUME_FOR_L2) {
                            totalL2 += (vol2 * LEVEL2_REWARD_BP) / BP_DENOMINATOR;
                        }

                        // --- Level 3 ---
                        address[] memory level3Refs = directReferees[level2Refs[k]];
                        for (uint256 m = 0; m < level3Refs.length; ) {
                            // console.log(level3Refs[m], "level3Refs[m]");
                            uint256 vol3 = doppiPoints.getMonthlyVolume(level3Refs[m], monthId);
                            // console.log(vol3, "vol3");
                            if (vol3 >= MIN_VOLUME_FOR_L3) {
                                totalL3 += (vol3 * LEVEL3_REWARD_BP) / BP_DENOMINATOR;
                                // console.log(totalL3, "totalL3", MIN_VOLUME_FOR_L3);
                            }
                            unchecked { ++m; }
                        }
                        unchecked { ++k; }
                    }
                    unchecked { ++j; }
                }
            }
            unchecked { ++i; }
        }
    }

    // 30-day rolling months
    function _currentMonthId() internal view returns (uint256) {
        return block.timestamp / 30 days;
    }

    // -----------------------
    // Admin functions
    // -----------------------

    /// @notice Set level1 and level2 rates in basis points. Sum should not exceed 10000.
    function setRates(uint16 _level1Bps, uint16 _level2Bps, uint16 _level3Bps) external onlyOwner {
        require(uint256(_level1Bps) + uint256(_level2Bps) + uint256(_level3Bps) <= BP_DENOMINATOR, "bps sum too large");
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
