// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";
import {IDoppiTrader} from "../Interface/IDoppiTrader.sol";
// import "forge-std/console.sol";

interface IDoppiReferral {
    function getUplineChain(address trader) external view returns (address l1, address l2, address l3);
}

contract DoppiPoints is Ownable, Pausable {
    
    address public doppiClaim;
    mapping(address => IDoppiTraderFactory) public coreToTraderFactory;
    mapping(address => bool) public coreRegistrars;
    IDoppiReferral public doppiReferral;
    mapping(address => bool) public doppiCore;
    uint256 public totalVolume;
    uint256 public botVolumeMultiplierNum = 1;
    uint256 public botVolumeMultiplierDen = 1;

    struct ClaimedPoint {
        uint24 claimedMonthId;
        uint256 totalPointClaimed; 
    }

    struct ReferralAggregates {
        uint256 level1Volume;
        uint256 level2Volume;
        uint256 level3Volume;
    }

    mapping(uint24 => bool) public monthExists;
    uint24[] public monthIds;
    mapping(uint24 => mapping(address => uint256)) public monthlyVolume;
    mapping(address => ClaimedPoint) public claimedPoint; 
    mapping(uint24 => mapping(address => ReferralAggregates)) public monthlyReferralVolume;
    mapping(address => uint256) public pointsUsedForFees;  // Track points deducted for fees since last claim
    mapping(address => bool) public authorizedPointsDeductors;  // e.g., PrivateAutomationHub
    
    uint32 public constant startTimestamp = 1735689600; // Jan 1, 2025

    event TradeRecorded(address indexed trader, uint256 volume);
    event PointsReset(address indexed trader, uint256 points);
    event ReferralChainUpdated(address indexed trader, address l1, address l2, address l3);
    event CoreTraderFactorySet(address indexed core, address indexed factory);
    event CoreRegistrarSet(address indexed registrar, bool allowed);
    event CoreRegistered(address indexed core, address indexed factory, address indexed registrar);
    event BotVolumeMultiplierUpdated(uint256 numerator, uint256 denominator);
    event PointsDeductedForFee(address indexed trader, uint256 points);
    event AuthorizedPointsDeductorSet(address indexed deductor, bool allowed);

    constructor()
        Ownable(msg.sender)
    {    }

    function recordTrade(address trader, uint256 volumeInUSDT) external onlyDoppiCore {
        
        if (paused()) return;
        
        require(volumeInUSDT > 0, "volume must be > 0");

        // Determine actual trader and whether position owner is a registered bot
        (address actualTrader, bool isTraderBot) = _resolveTrader(msg.sender, trader);
        uint256 effectiveVolume = volumeInUSDT;
        if (isTraderBot) {
            effectiveVolume = (volumeInUSDT * botVolumeMultiplierNum) / botVolumeMultiplierDen;
        }
        uint24 monthId = _currentMonthId();

        monthlyVolume[monthId][actualTrader] += effectiveVolume;
        totalVolume += effectiveVolume;
        _ensureMonthId(monthId);

        // cache referral volume per level from the current active referral chain
        if (address(doppiReferral) != address(0)) {
            (address l1, address l2, address l3) = doppiReferral.getUplineChain(actualTrader);
            if (l1 != address(0)) {
                monthlyReferralVolume[monthId][l1].level1Volume += effectiveVolume;
            }
            if (l2 != address(0)) {
                monthlyReferralVolume[monthId][l2].level2Volume += effectiveVolume;
            }
            if (l3 != address(0)) {
                monthlyReferralVolume[monthId][l3].level3Volume += effectiveVolume;
            }
            emit ReferralChainUpdated(actualTrader, l1, l2, l3);
        }
        emit TradeRecorded(actualTrader, effectiveVolume);
    }

    function resetPoint(address trader) external onlyDoppiClaim {

        ClaimedPoint storage ref = claimedPoint[trader];
        (,uint256 readyPoint, ) = _getAllPointData(trader); 

        uint24 currentMonthId = _currentMonthId();
        // Only reset if we're in a new month
        if (currentMonthId > ref.claimedMonthId + 1) {               
            ref.totalPointClaimed += readyPoint;
            ref.claimedMonthId = currentMonthId - 1; // Claim up to previous month
            // Clear used points tracker since we've now claimed and accounted for them
            pointsUsedForFees[trader] = 0;
        }
        emit PointsReset(trader, readyPoint);
    }

    function getReferralVolumeByMonth(address referrer, uint24 monthId)
        external view returns (uint256 l1, uint256 l2, uint256 l3)
    {
        ReferralAggregates memory agg = monthlyReferralVolume[monthId][referrer];
        l1 = agg.level1Volume;
        l2 = agg.level2Volume;
        l3 = agg.level3Volume;
    }

    function getAllPointData(address trader)
        external
        view
        returns (
            uint256 totalClaimedPoint,
            uint256 readyPoint,
            uint256 currentMonthPoint
        )
    {
        return _getAllPointData(trader);
    }

    function getCurrentMonthId() external view returns (uint24) {
        return _currentMonthId();
    }

    /// @notice Get trader's volume for a specific monthId
    function getMonthlyVolume(address trader, uint24 monthId) external view returns (uint256) {
        return monthlyVolume[monthId][trader];
    }

    function getMonthIds() external view returns (uint24[] memory) {
        return monthIds;
    }

    function setDoppiCore(address _doppiCore, bool _status) external onlyOwner {
        require(_doppiCore != address(0), "Zero address");
        doppiCore[_doppiCore] = _status;
    }

    function setCoreRegistrar(address registrar, bool allowed) external onlyOwner {
        require(registrar != address(0), "Zero address");
        coreRegistrars[registrar] = allowed;
        emit CoreRegistrarSet(registrar, allowed);
    }

    /// @notice Registers a new DoppiCore and links it to its trader factory.
    /// Callable by owner or a whitelisted registrar (e.g. private bot factory).
    function registerCore(address _core, address _factory) external onlyOwnerOrRegistrar {
        require(_core != address(0), "Zero address");
        require(_factory != address(0), "Zero address");
        doppiCore[_core] = true;
        coreToTraderFactory[_core] = IDoppiTraderFactory(_factory);
        emit CoreTraderFactorySet(_core, _factory);
        emit CoreRegistered(_core, _factory, msg.sender);
    }

    function setDoppiClaim(address _doppiClaim) external onlyOwner {
        require(_doppiClaim != address(0), "Zero address");
        doppiClaim = _doppiClaim;
    }

    function setDoppiReferral(address _doppiReferral) external onlyOwner {
        require(_doppiReferral != address(0), "Zero address");
        doppiReferral = IDoppiReferral(_doppiReferral);
    }

    function setCoreTraderFactory(address _core, address _factory) external onlyOwner {
        require(_core != address(0), "Zero address");
        require(_factory != address(0), "Zero address");
        coreToTraderFactory[_core] = IDoppiTraderFactory(_factory);
        emit CoreTraderFactorySet(_core, _factory);
    }

    function setBotVolumeMultiplier(uint256 numerator, uint256 denominator) external onlyOwner {
        require(denominator > 0, "Zero denominator");
        botVolumeMultiplierNum = numerator;
        botVolumeMultiplierDen = denominator;
        emit BotVolumeMultiplierUpdated(numerator, denominator);
    }

    function setAuthorizedPointsDeductor(address deductor, bool allowed) external onlyOwner {
        require(deductor != address(0), "Zero address");
        authorizedPointsDeductors[deductor] = allowed;
        emit AuthorizedPointsDeductorSet(deductor, allowed);
    }

    /// @notice Record points deducted for fees (e.g., by PrivateAutomationHub).
    /// These points will be subtracted from readyPoint to prevent double-counting.
    function deductPointsForFee(address trader, uint256 points) external onlyAuthorizedDeductor {
        require(trader != address(0), "Zero address");
        require(points > 0, "Points must be > 0");
        pointsUsedForFees[trader] += points;
        emit PointsDeductedForFee(trader, points);
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }

    // internal function 

    function _getAllPointData(address trader)
        internal
        view
        returns (
            uint256 totalClaimedPoint,
            uint256 readyPoint,
            uint256 currentMonthPoint
        )
    {
        ClaimedPoint memory claimed = claimedPoint[trader];
        uint24 currentMonthId = _currentMonthId();
        currentMonthPoint = monthlyVolume[currentMonthId][trader];

        uint24 startMonth = claimed.claimedMonthId + 1;
        if (startMonth < currentMonthId) {
            for (uint24 month = startMonth; month < currentMonthId; month++) {
                readyPoint += monthlyVolume[month][trader];
            }
        }
        
        // Subtract points used for fees to prevent double-counting
        uint256 used = pointsUsedForFees[trader];
        if (readyPoint > used) {
            readyPoint -= used;
        } else {
            readyPoint = 0;
        }
        
        totalClaimedPoint = claimed.totalPointClaimed;
    }

    function _resolveTrader(address core, address positionOwner) internal view returns (address owner, bool isTraderBot) {
        IDoppiTraderFactory factory = coreToTraderFactory[core];
        if (
            address(factory) != address(0) &&
            factory.isTraderBot(positionOwner)
        ) {
            owner = IDoppiTrader(positionOwner).validTrader();
            isTraderBot = true;
        } else {
            owner = positionOwner;
        }
    }
    function _ensureMonthId(uint24 monthId) internal {
        if (!monthExists[monthId]) {
            monthExists[monthId] = true;
            monthIds.push(monthId);
        }
    }

    function _currentMonthId() internal view returns (uint24) {
        // 30-day rolling months
        return uint24((block.timestamp - startTimestamp) / 30 days);
    }

    modifier onlyDoppiCore() {
        require(doppiCore[msg.sender], "only doppicore");
        _;
    }

    modifier onlyDoppiClaim() {
        require(msg.sender == doppiClaim, "only doppiClaim");
        _;
    }

    modifier onlyOwnerOrRegistrar() {
        require(msg.sender == owner() || coreRegistrars[msg.sender], "only owner or registrar");
        _;
    }

    modifier onlyAuthorizedDeductor() {
        require(authorizedPointsDeductors[msg.sender], "only authorized deductor");
        _;
    }
}
