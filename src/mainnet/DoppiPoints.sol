// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
// import "forge-std/console.sol";

contract DoppiPoints is Ownable, Pausable {
    address public doppiCore;
    address public doppiClaim;

    struct ClaimedPoint {
        uint256 claimedMonthId;
        uint256 totalPointClaimed; 
    }

    mapping(uint256 => bool) public monthExists;
    uint256[] public monthIds;
    mapping(uint256 => mapping(address => uint256)) public monthlyVolume;
    mapping(address => ClaimedPoint) public claimedPoint; 
    
    uint256 public constant startTimestamp = 1735689600; // Jan 1, 2025

    event TradeRecorded(address indexed trader, uint256 volume, uint256 points);
    event PointsReset(address indexed trader, uint256 points);

    constructor()
        Ownable(msg.sender)
    {
    }

    // Record a trade in USDT volume (1 USDT = 1 point)
    function recordTrade(address trader, uint256 volumeInUSDT) external onlyDoppiCore {
        
        if(paused()) return;

        require(volumeInUSDT > 0, "Volume must be > 0");

        uint256 monthId = _currentMonthId();
        monthlyVolume[monthId][trader] += volumeInUSDT;

        _ensureMonthId(monthId); // ensures uniqueness

        emit TradeRecorded(trader, volumeInUSDT, volumeInUSDT);
    }

    function resetPoint(address trader) external onlyDoppiClaim {

        ClaimedPoint storage ref = claimedPoint[trader];
        (,uint256 readyPoint, ) = this.getAllPointData(trader); 

        uint256 currentMonthId = _currentMonthId();
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
        uint256 currentMonthId = _currentMonthId();
        currentMonthPoint = monthlyVolume[currentMonthId][trader];
        
        // Calculate start month ID safely
        uint256 startMonthId = claimed.claimedMonthId + 1;
        uint256 endMonthId = currentMonthId;
        // Only proceed if there are months to process (avoid underflow in loop condition)
        if (startMonthId < endMonthId) {
            // Process from startMonthId to endMonthId - 1 (exclude current month)
            for (uint256 monthId = startMonthId; monthId < endMonthId; monthId++) {
                readyPoint += monthlyVolume[monthId][trader];
            }
        }
    }

    function getCurrentMonthId() external view returns (uint256) {
        return _currentMonthId();
    }

    /// @notice Get trader's volume for a specific monthId
    function getMonthlyVolume(address trader, uint256 monthId) external view returns (uint256) {
        return monthlyVolume[monthId][trader];
    }

    function getMonthIds() external view returns (uint256[] memory) {
        return monthIds;
    }

    function setDoppiCore(address _doppiCore) external onlyOwner {
        require(_doppiCore != address(0), "Zero address");
        doppiCore = _doppiCore;
    }

    function setDoppiClaim(address _doppiClaim) external onlyOwner {
        require(_doppiClaim != address(0), "Zero address");
        doppiClaim = _doppiClaim;
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }

    // internal function 
    function _ensureMonthId(uint256 monthId) internal {
        if (!monthExists[monthId]) {
            monthExists[monthId] = true;
            monthIds.push(monthId);
        }
    }

    function _currentMonthId() internal view returns (uint256) {
        // 30-day rolling months
        return (block.timestamp - startTimestamp) / 30 days;
    }

    modifier onlyDoppiCore() {
        require(msg.sender == doppiCore, "only doppicore");
        _;
    }

    modifier onlyDoppiClaim() {
        require(msg.sender == doppiClaim, "only doppiClaim");
        _;
    }
}
