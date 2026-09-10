// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiOpportunity} from "../Interface/IDoppiOpportunity.sol";
import "./DoppiCoreTypes.sol";
// import "forge-std/console.sol";

abstract contract DoppiCoreView {
    error OpportunityViewFailed();

    struct EmergencyCursor {
        uint256 epoch;
        uint256 dayIndex;
        uint64 positionId;
    }
    
    uint256 public totalBuyDeposits;
    uint256 public totalSellDeposits;
    uint256 public totalInterestLiabilityA; 
    uint256 public totalInterestLiabilityB;
    uint8[] public supportDays; 
    mapping(uint8 => uint64) public nextProcessId;
    mapping(uint8 => uint64) public nextPositionId;
    
    IDoppiLiquidity public doppiLP;
    
    mapping(uint32 => mapping(uint64 => DualAssetPosition)) public positions_buy;
    mapping(uint32 => mapping(uint64 => DualAssetPosition)) public positions_sell;
    mapping(address => uint256) internal activeBuyCount;
    mapping(address => uint256) internal activeSellCount;
    mapping(address => uint256) internal activeBuyPrincipal;
    mapping(address => uint256) internal activeSellPrincipal;
    uint256 internal emergencyEpoch;
    mapping(address => EmergencyCursor) internal emergencyCursors;
    uint256 internal nextPendingSettlementId = 1;
    mapping(uint256 => PendingSettlement) internal pendingSettlements;
    mapping(address => uint256[]) internal pendingSettlementIdsByOwner;

    /// @notice Reference to external DoppiOpportunity storage
    IDoppiOpportunity public doppiOpportunity;
    
    // View functions for positions    
    function get_positions_buy(address _owner) external view returns (DualAssetPosition[] memory) {
        
        uint256 totalCount = _getBuyPositionCount(_owner);
        DualAssetPosition[] memory result = new DualAssetPosition[](totalCount);
        
        // Second pass: Fill the final array
        uint256 resultIndex = 0;
        for (uint256 x = 0; x < supportDays.length; ) {
            uint8 day = supportDays[x];            
            for (uint64 i = nextProcessId[day]; i < nextPositionId[day]; ) {
                if (positions_buy[day][i].owner == _owner) {
                    result[resultIndex] = positions_buy[day][i];
                    resultIndex++;
                }
                unchecked { ++i; }
            }
            unchecked { ++x; }
        }
        
        return result;
    }

    function get_positions_sell(address _owner) external view returns (DualAssetPosition[] memory) {
        
        uint256 totalCount = _getSellPositionCount(_owner);
        DualAssetPosition[] memory result = new DualAssetPosition[](totalCount);
        
        uint256 resultIndex = 0;
        for (uint256 x = 0; x < supportDays.length; ) {
            uint8 day = supportDays[x];
            for (uint64 i = nextProcessId[day]; i < nextPositionId[day]; ) {
                if (positions_sell[day][i].owner == _owner) {
                    result[resultIndex] = positions_sell[day][i];
                    resultIndex++;
                }
                unchecked { ++i; }
            }
            unchecked { ++x; }
        }
        
        return result;
    }

    function getBuyPositionCount(address _owner) external view returns (uint256 count) {
        count = activeBuyCount[_owner];
    }

    function getSellPositionCount(address _owner) external view returns (uint256 count) {
        count = activeSellCount[_owner];
    }

    function getOwnerPositionPrincipals(address _owner) external view returns (uint256 buyPrincipal, uint256 sellPrincipal) {
        return (activeBuyPrincipal[_owner], activeSellPrincipal[_owner]);
    }

    function getCurrentDeposits(bool isBuy) public view returns (uint256 currentDeposits) {

        if(isBuy) {
            currentDeposits = totalBuyDeposits + totalInterestLiabilityA;
        }else{
            currentDeposits = totalSellDeposits + totalInterestLiabilityB;
        }
    }

    function canAcceptDeposit(bool isBuy, uint256 depositAmount) public view returns (bool) {
        uint256 maxDeposit = doppiLP.getMaxDepositAmount(isBuy);
        uint256 currentDeposits = getCurrentDeposits(isBuy); 
        return (currentDeposits + depositAmount) <= maxDeposit;
    }

    function acceptedDeposit(bool isBuy) public view returns (uint256 acceptedAmount) {
        uint256 maxDeposit = doppiLP.getMaxDepositAmount(isBuy);
        if(maxDeposit == 0) return 0;
        uint256 currentDeposits = getCurrentDeposits(isBuy); 
        acceptedAmount = maxDeposit > currentDeposits ? maxDeposit - currentDeposits : 0;
    }

    function getInterestLiabilities() external view returns (uint256, uint256) {
        return (totalInterestLiabilityA, totalInterestLiabilityB);
    }

    function getOpportunityOrders(bool isBuy, uint256 strikePrice) external view returns (OpportunityOrders memory) {
        if (address(doppiOpportunity) == address(0)) revert OpportunityViewFailed();
        return doppiOpportunity.getOpportunityOrders(isBuy, strikePrice);
    }

    function getPendingSettlementIds(address owner) external view returns (uint256[] memory) {
        return pendingSettlementIdsByOwner[owner];
    }

    function getPendingSettlement(uint256 pendingId) external view returns (PendingSettlement memory) {
        return pendingSettlements[pendingId];
    }

    function _getBuyPositionCount(address _owner) internal view returns (uint256 count) {
        return activeBuyCount[_owner];
    }

    function _getSellPositionCount(address _owner) internal view returns (uint256 count) {
        return activeSellCount[_owner];
    }

    function _addOwnerPosition(address owner, uint256 amount, bool isBuy) internal {
        if (isBuy) {
            activeBuyCount[owner] += 1;
            activeBuyPrincipal[owner] += amount;
        } else {
            activeSellCount[owner] += 1;
            activeSellPrincipal[owner] += amount;
        }
    }

    function _removeOwnerPosition(address owner, uint256 amount, bool isBuy) internal {
        if (isBuy) {
            activeBuyCount[owner] -= 1;
            activeBuyPrincipal[owner] -= amount;
        } else {
            activeSellCount[owner] -= 1;
            activeSellPrincipal[owner] -= amount;
        }
    }
}
