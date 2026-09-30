// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Interface/IDoppiCorePositionLens.sol";
import "./DoppiCoreTypes.sol";

interface IDoppiCorePositionReader {
    function getSupportDaysLength() external view returns (uint256);
    function supportDays(uint256 index) external view returns (uint8);
    function nextProcessId(uint8 day) external view returns (uint64);
    function nextPositionId(uint8 day) external view returns (uint64);
    function getBuyPositionCount(address owner) external view returns (uint256);
    function getSellPositionCount(address owner) external view returns (uint256);
    function positions_buy(uint32 day, uint64 positionId) external view returns (uint256, uint256, uint256, uint32, uint32, address, uint256, uint256);
    function positions_sell(uint32 day, uint64 positionId) external view returns (uint256, uint256, uint256, uint32, uint32, address, uint256, uint256);
}

contract DoppiCorePositionLens is IDoppiCorePositionLens {
    IDoppiCorePositionReader public immutable doppiCore;

    constructor(address _doppiCore) {
        doppiCore = IDoppiCorePositionReader(_doppiCore);
    }

    function getPositionsBuy(address owner) external view returns (DualAssetPosition[] memory result) {
        result = new DualAssetPosition[](doppiCore.getBuyPositionCount(owner));
        _fillPositions(owner, true, result);
    }

    function getPositionsSell(address owner) external view returns (DualAssetPosition[] memory result) {
        result = new DualAssetPosition[](doppiCore.getSellPositionCount(owner));
        _fillPositions(owner, false, result);
    }

    function _fillPositions(address owner, bool isBuy, DualAssetPosition[] memory result) internal view {
        uint256 resultIndex;
        uint256 dayCount = doppiCore.getSupportDaysLength();

        for (uint256 dayIndex = 0; dayIndex < dayCount; ) {
            uint8 day = doppiCore.supportDays(dayIndex);
            uint64 start = doppiCore.nextProcessId(day);
            uint64 end = doppiCore.nextPositionId(day);

            for (uint64 positionId = start; positionId < end; ) {
                DualAssetPosition memory position = _getPosition(day, positionId, isBuy);
                if (position.owner == owner) {
                    result[resultIndex] = position;
                    unchecked { ++resultIndex; }
                }
                unchecked { ++positionId; }
            }
            unchecked { ++dayIndex; }
        }
    }

    function _getPosition(uint8 day, uint64 positionId, bool isBuy)
        internal
        view
        returns (DualAssetPosition memory position)
    {
        if (isBuy) {
            (
                position.amount,
                position.price,
                position.strikePrice,
                position.expiryTimestamp,
                position.apr,
                position.owner,
                position.interest,
                position.payout
            ) = doppiCore.positions_buy(day, positionId);
        } else {
            (
                position.amount,
                position.price,
                position.strikePrice,
                position.expiryTimestamp,
                position.apr,
                position.owner,
                position.interest,
                position.payout
            ) = doppiCore.positions_sell(day, positionId);
        }
    }
}