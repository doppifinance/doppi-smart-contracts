// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DoppiTraderFactory} from "./DoppiTraderFactory.sol";
import "./DoppiCoreTypes.sol";

//       DualAsset Admin Module (Owner / Keeper Ops)
abstract contract DoppiCoreView {
    
    KeyPosition[] public buyPositionKeys;
    KeyPosition[] public sellPositionKeys;
    mapping(address => mapping(uint32 => DualAssetPosition)) public positions_buy; // Changed to uint32
    mapping(address => mapping(uint32 => DualAssetPosition)) public positions_sell; // Changed to uint32
    
    
    function get_buy_positions_id(address _owner) external view returns (KeyPosition[] memory) {
        uint256 count = 0;
        uint256 length = buyPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (buyPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        
        KeyPosition[] memory result = new KeyPosition[](count);
        count = 0;
        for (uint256 i = 0; i < length; ) {
            if (buyPositionKeys[i].owner == _owner) {
                result[count] = buyPositionKeys[i];
                count++;
            }
            unchecked { ++i; }
        }
        return result;
    }

    function get_sell_positions_id(address _owner) external view returns (KeyPosition[] memory) {
        uint256 count = 0;
        uint256 length = sellPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (sellPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        
        KeyPosition[] memory result = new KeyPosition[](count);
        count = 0;
        for (uint256 i = 0; i < length; ) {
            if (sellPositionKeys[i].owner == _owner) {
                result[count] = sellPositionKeys[i];
                count++;
            }
            unchecked { ++i; }
        }
        return result;
    }

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
        for (uint256 i = 0; i < length; ) {
            if (buyPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        return count;
    }

    function getBuyPositionCount() external view returns (uint256) {
        return buyPositionKeys.length;
    }

    function getSellPositionCount(address _owner) external view returns (uint256) {
        uint256 count = 0;
        uint256 length = sellPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (sellPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        return count;
    }

    function getSellPositionCount() external view returns (uint256) {
        return sellPositionKeys.length;
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

}
