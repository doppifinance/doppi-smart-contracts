// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import "./DoppiCoreTypes.sol";
// import "forge-std/console.sol";

abstract contract DoppiCoreView {
    
    uint256 public totalBuyDeposits;
    uint256 public totalSellDeposits;
    uint256 public totalInterestLiabilityA; 
    uint256 public totalInterestLiabilityB;

    IDoppiLiquidity public immutable doppiLP; // Made immutable
    
    KeyPosition[] public buyPositionKeys;
    KeyPosition[] public sellPositionKeys;
    mapping(address => mapping(uint64 => DualAssetPosition)) public positions_buy; 
    mapping(address => mapping(uint64 => DualAssetPosition)) public positions_sell; 
    
    
    // View functions for positions
    function get_positions_buy(address _owner) external view returns (DualAssetPosition[] memory) {
        uint256 count = 0;
        uint256 length = buyPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (buyPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        
        DualAssetPosition[] memory result = new DualAssetPosition[](count);
        count = 0;
        for (uint256 i = 0; i < length; ) {
            if (buyPositionKeys[i].owner == _owner) {
                result[count] = positions_buy[buyPositionKeys[i].owner][buyPositionKeys[i].positionId];
                count++;
            }
            unchecked { ++i; }
        }
        return result;
    }

    function get_positions_sell(address _owner) external view returns (DualAssetPosition[] memory) {
        uint256 count = 0;
        uint256 length = sellPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (sellPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        
        DualAssetPosition[] memory result = new DualAssetPosition[](count);
        count = 0;
        for (uint256 i = 0; i < length; ) {
            if (sellPositionKeys[i].owner == _owner) {
                result[count] = positions_sell[sellPositionKeys[i].owner][sellPositionKeys[i].positionId];
                count++;
            }
            unchecked { ++i; }
        }
        return result;
    }

    function get_positions_buy() external view returns (DualAssetPosition[] memory) {
        uint256 length = buyPositionKeys.length;
        DualAssetPosition[] memory result = new DualAssetPosition[](length);
        for (uint256 i = 0; i < length; ) {
            result[i] = positions_buy[buyPositionKeys[i].owner][buyPositionKeys[i].positionId];
            unchecked { ++i; }
        }
        return result;
    }

    function get_positions_sell() external view returns (DualAssetPosition[] memory) {
        uint256 length = sellPositionKeys.length;
        DualAssetPosition[] memory result = new DualAssetPosition[](length);
        for (uint256 i = 0; i < length; ) {
            result[i] = positions_sell[sellPositionKeys[i].owner][sellPositionKeys[i].positionId];
            unchecked { ++i; }
        }
        return result;
    }

    function get_buy(address _owner, uint32 _positionId) external view returns (DualAssetPosition memory) {
        return positions_buy[_owner][_positionId];
    }

    function get_sell(address _owner, uint32 _positionId) external view returns (DualAssetPosition memory) {
        return positions_sell[_owner][_positionId];
    }

    function getBuyPositionCount(address _owner) external view returns (uint256) {
        uint256 count = 0;
        uint256 length = buyPositionKeys.length;
        if(_owner == address(0)) return length;

        for (uint256 i = 0; i < length; ) {
            if (buyPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        return count;
    }

    function getSellPositionCount(address _owner) external view returns (uint256) {
        uint256 count = 0;
        uint256 length = sellPositionKeys.length;
        if(_owner == address(0)) return length;
        
        for (uint256 i = 0; i < length; ) {
            if (sellPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        return count;
    }

    function getReadyBuyPositions() public view returns (uint256[] memory) {
        uint256 count = 0;
        uint256 length = buyPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (positions_buy[buyPositionKeys[i].owner][buyPositionKeys[i].positionId].expiryTimestamp <= block.timestamp) {
                count++;
            }
            unchecked { ++i; }
        }
        
        uint256[] memory readyIndexes = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            if (positions_buy[buyPositionKeys[index].owner][buyPositionKeys[index].positionId].expiryTimestamp <= block.timestamp) {
                readyIndexes[idx] = index;
                idx++;
            }
            unchecked { --i; }
        }
        return readyIndexes;
    }

    function getReadySellPositions() public view returns (uint256[] memory) {
        uint256 count = 0;
        uint256 length = sellPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (positions_sell[sellPositionKeys[i].owner][sellPositionKeys[i].positionId].expiryTimestamp <= block.timestamp) {
                count++;
            }
            unchecked { ++i; }
        }
        
        uint256[] memory readyIndexes = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            if (positions_sell[sellPositionKeys[index].owner][sellPositionKeys[index].positionId].expiryTimestamp <= block.timestamp) {
                readyIndexes[idx] = index;
                idx++;
            }
            unchecked { --i; }
        }
        return readyIndexes;
    }

    function getCurrentDeposits(bool isBuy) public view returns (uint256) {
        return isBuy ? totalBuyDeposits : totalSellDeposits;
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
        acceptedAmount = maxDeposit - currentDeposits;
    }

    function getInterestLiabilities() external view returns (uint256, uint256) {
        return (totalInterestLiabilityA, totalInterestLiabilityB);
    }
}
