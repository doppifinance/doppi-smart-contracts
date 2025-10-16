// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import "forge-std/console.sol";

contract DoppiPoints is Ownable, Pausable {
    address public doppiCore;
    address public doppiClaim;

    struct Trader {
        uint256 totalVolume; // total volume traded
        uint256 points;      // total points earned
    }

    uint256[] public monthIds;
    mapping(address => Trader) public traders;
    mapping(uint256 => mapping(address => uint256)) public monthlyVolume;

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

        Trader storage t = traders[trader];
        t.totalVolume += volumeInUSDT;
        t.points += volumeInUSDT; // 1:1 mapping

        uint256 monthId = _currentMonthId();
        monthlyVolume[monthId][trader] += volumeInUSDT;

        _ensureMonthId(monthId); // ensures uniqueness

        emit TradeRecorded(trader, volumeInUSDT, volumeInUSDT);
    }

    function resetPoint(address trader) external onlyDoppiClaim {

        Trader storage t = traders[trader];
        uint256 points = t.points;
        t.points = 0; 
        emit PointsReset(trader, points);
    }

    // Get total points for a trader
    function getPoints(address trader) external view returns (uint256 totalPoints, uint256 totalVolume) {
        
        totalPoints = traders[trader].points;
        totalVolume = traders[trader].totalVolume; 
    }

    /// @notice Get trader's volume for a specific monthId
    function getMonthlyVolume(address trader, uint256 monthId) external view returns (uint256) {
        return monthlyVolume[monthId][trader];
    }

    function getMonthIds() external view returns (uint256[] memory) {
        return monthIds;
    }

    function setDoppiCore(address _doppiCore) external onlyOwner {
        doppiCore = _doppiCore;
    }

    function setDoppiClaim(address _doppiClaim) external onlyOwner {
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
        uint256 len = monthIds.length;
        for (uint256 i = 0; i < len; ) {
            if (monthIds[i] == monthId) {
                return; // already exists
            }
            unchecked { ++i; }
        }
        monthIds.push(monthId);
    }

    function _currentMonthId() internal view returns (uint256) {
        // 30-day rolling months
        return block.timestamp / 30 days;
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
