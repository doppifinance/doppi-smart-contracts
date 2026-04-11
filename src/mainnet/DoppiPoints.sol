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
    IDoppiTraderFactory public doppiTraderFactory;
    IDoppiReferral public doppiReferral;
    mapping(address => bool) public doppiCore;
    uint256 public totalVolume;

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
    
    uint32 public constant startTimestamp = 1735689600; // Jan 1, 2025

    event TradeRecorded(address indexed trader, uint256 volume);
    event PointsReset(address indexed trader, uint256 points);
    event ReferralChainUpdated(address indexed trader, address l1, address l2, address l3);

    constructor()
        Ownable(msg.sender)
    {    }

    function recordTrade(address trader, uint256 volumeInUSDT) external onlyDoppiCore {
        
        if (paused()) return;
        
        require(volumeInUSDT > 0, "volume must be > 0");

        // Determine the actual trader (handle trader bots internally)
        address actualTrader = _getActualTrader(trader);
        uint24 monthId = _currentMonthId();

        monthlyVolume[monthId][actualTrader] += volumeInUSDT;
        totalVolume += volumeInUSDT;
        _ensureMonthId(monthId);

        // cache referral volume per level from the current active referral chain
        if (address(doppiReferral) != address(0)) {
            (address l1, address l2, address l3) = doppiReferral.getUplineChain(actualTrader);
            if (l1 != address(0)) {
                monthlyReferralVolume[monthId][l1].level1Volume += volumeInUSDT;
            }
            if (l2 != address(0)) {
                monthlyReferralVolume[monthId][l2].level2Volume += volumeInUSDT;
            }
            if (l3 != address(0)) {
                monthlyReferralVolume[monthId][l3].level3Volume += volumeInUSDT;
            }
            emit ReferralChainUpdated(actualTrader, l1, l2, l3);
        }
        emit TradeRecorded(actualTrader, volumeInUSDT);
    }

    function resetPoint(address trader) external onlyDoppiClaim {

        ClaimedPoint storage ref = claimedPoint[trader];
        (,uint256 readyPoint, ) = _getAllPointData(trader); 

        uint24 currentMonthId = _currentMonthId();
        // Only reset if we're in a new month
        if (currentMonthId > ref.claimedMonthId + 1) {               
            ref.totalPointClaimed += readyPoint;
            ref.claimedMonthId = currentMonthId - 1; // Claim up to previous month
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

    function setDoppiClaim(address _doppiClaim) external onlyOwner {
        require(_doppiClaim != address(0), "Zero address");
        doppiClaim = _doppiClaim;
    }

    function setDoppiReferral(address _doppiReferral) external onlyOwner {
        require(_doppiReferral != address(0), "Zero address");
        doppiReferral = IDoppiReferral(_doppiReferral);
    }

     function setDoppiTraderFactory(address _traderFactory) external onlyOwner {
        require(_traderFactory != address(0), "Zero address");
        doppiTraderFactory = IDoppiTraderFactory(_traderFactory);
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
        totalClaimedPoint = claimed.totalPointClaimed;
    }

    function _getActualTrader(address positionOwner) internal view returns (address owner) {
        
        if (
            address(doppiTraderFactory) != address(0) &&
            doppiTraderFactory.isTraderBot(positionOwner)
        ) {
            owner = IDoppiTrader(positionOwner).validTrader();
        }else{
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
}
