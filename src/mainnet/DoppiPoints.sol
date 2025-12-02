// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";
import {IDoppiTrader} from "../Interface/IDoppiTrader.sol";
// import "forge-std/console.sol";

contract DoppiPoints is Ownable, Pausable {
    
    address public doppiClaim;
    IDoppiTraderFactory public doppiTraderFactory;
    mapping(address => bool) public doppiCore;
    uint256 public totalVolume;

    struct ClaimedPoint {
        uint24 claimedMonthId;
        uint256 totalPointClaimed; 
    }

    mapping(uint24 => bool) public monthExists;
    uint24[] public monthIds;
    mapping(uint24 => mapping(address => uint256)) public monthlyVolume;
    mapping(address => ClaimedPoint) public claimedPoint; 
    
    uint32 public constant startTimestamp = 1735689600; // Jan 1, 2025

    event TradeRecorded(address indexed trader, uint256 volume);
    event PointsReset(address indexed trader, uint256 points);

    constructor()
        Ownable(msg.sender)
    {
    }

    // Record a trade in USDT volume (1 USDT = 1 point)
    function recordTrade(address trader, uint256 volumeInUSDT) external onlyDoppiCore {
        
        if(paused()) return;

        require(volumeInUSDT > 0, "Volume must be > 0");

        // Determine the actual trader (handle trader bots internally)
        address actualTrader = _getActualTrader(trader);
        
        uint24 monthId = _currentMonthId();
        monthlyVolume[monthId][actualTrader] += volumeInUSDT;
        totalVolume += volumeInUSDT;

        _ensureMonthId(monthId); // ensures uniqueness

        emit TradeRecorded(actualTrader, volumeInUSDT);
    }

    function resetPoint(address trader) external onlyDoppiClaim {

        ClaimedPoint storage ref = claimedPoint[trader];
        (,uint256 readyPoint, ) = this.getAllPointData(trader); 

        uint24 currentMonthId = _currentMonthId();
        // Only reset if we're in a new month
        if (currentMonthId > ref.claimedMonthId + 1) {               
            ref.totalPointClaimed += readyPoint;
            ref.claimedMonthId = currentMonthId - 1; // Claim up to previous month
        }
        emit PointsReset(trader, readyPoint);
    }

    function getAllPointData(address trader)
        external
        view
        returns (uint256 totalClaimedPoint, uint256 readyPoint, uint256 currentMonthPoint)
    {
        ClaimedPoint memory claimed = claimedPoint[trader];
        totalClaimedPoint = claimed.totalPointClaimed;
        uint24 currentMonthId = _currentMonthId();
        currentMonthPoint = monthlyVolume[currentMonthId][trader];
        
        // Calculate start month ID safely
        uint24 startMonthId = claimed.claimedMonthId + 1;
        uint256 endMonthId = currentMonthId;
        // Only proceed if there are months to process (avoid underflow in loop condition)
        if (startMonthId < endMonthId) {
            // Process from startMonthId to endMonthId - 1 (exclude current month)
            for (uint24 monthId = startMonthId; monthId < endMonthId; monthId++) {
                readyPoint += monthlyVolume[monthId][trader];
            }
        }
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
    function _getActualTrader(address positionOwner) internal view returns (address owner) {
        
        if (
            address(doppiTraderFactory) != address(0) &&
            doppiTraderFactory.isTraderBot(positionOwner)
        ) {
            owner = IDoppiTrader(positionOwner).get_validTrader();
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
