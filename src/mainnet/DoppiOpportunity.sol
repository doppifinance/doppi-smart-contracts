// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./DoppiCore.sol";
import "../Interface/AutomationCompatibleInterface.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "forge-std/console.sol";

contract DoppiOpportunity is Ownable, AutomationCompatibleInterface {
    using Math for uint256;

    DoppiCore public doppiCore;
    IDoppiLiquidity public doppiLP;
    uint256 public profitAssetA;
    uint256 public profitAssetB;
    uint32 public tolerance = 100;

    constructor(address _doppiCore, address _doppiLP) Ownable(msg.sender) {
        doppiCore = DoppiCore(_doppiCore);
        doppiLP = IDoppiLiquidity(_doppiLP);
    }

    // Configuration functions
    function setTolerance(uint32 _tolerance) external onlyOwner {
        tolerance = _tolerance;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256 price = doppiLP.getPrice();
        DoppiCore.DualAssetPosition[] memory buys = doppiCore.get_positions_buy();
        DoppiCore.DualAssetPosition[] memory sells = doppiCore.get_positions_sell();
        (uint256 buyCount, uint256[] memory buyIndexes) = _checkOpportunity(price, buys, true);
        (uint256 sellCount, uint256[] memory sellIndexes) = _checkOpportunity(price, sells, false);
        upkeepNeeded = (buyCount > 0 || sellCount > 0);

        uint256[] memory buyIndexesTrimmed = new uint256[](buyCount);
        uint256[] memory sellIndexesTrimmed = new uint256[](sellCount);
        for (uint256 i = 0; i < buyCount; i++) {
            buyIndexesTrimmed[i] = buyIndexes[i];
        }
        for (uint256 i = 0; i < sellCount; i++) {
            sellIndexesTrimmed[i] = sellIndexes[i];
        }
        performData = abi.encode(price, buyIndexesTrimmed, sellIndexesTrimmed);
        return (upkeepNeeded, performData);
    }

    function performUpkeep(bytes calldata performData) external override {
        (uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) =
            abi.decode(performData, (uint256, uint256[], uint256[]));

        uint256 currentPrice = doppiLP.getPrice();
        uint256 priceChance = price.mulDiv(10000, currentPrice);
        if (priceChance > 10000 + tolerance || priceChance < 10000 - tolerance) {
            return; // price change outside tolerance
        }
        _opportunity_bot(price, buyIndexes, sellIndexes);
    }

    // internal function
    function _opportunity_bot(uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) internal {
        DoppiCore.DualAssetPosition[] memory buys = doppiCore.get_positions_buy();
        DoppiCore.DualAssetPosition[] memory sells = doppiCore.get_positions_sell();

        if(buyIndexes.length > 0) _performOpportunity(price, buyIndexes, buys, true);
        if(sellIndexes.length > 0) _performOpportunity(price, sellIndexes, sells, false);
    }

    function _checkOpportunity(uint256 price, DoppiCore.DualAssetPosition[] memory _orders, bool _isBuy)
        internal
        view
        returns (uint256, uint256[] memory indexes)
    {
        indexes = new uint256[](_orders.length);
        uint256 count = 0;

        for (uint256 i = 0; i < _orders.length; i++) {
            uint256 buffer = _orders[i].strikePrice.mulDiv(tolerance, 10000);
            uint256 triggerPrice = _isBuy ? _orders[i].strikePrice - buffer : _orders[i].strikePrice + buffer;

            if(_isBuy){
                if ((!_orders[i].isTraded && price <= triggerPrice) || (_orders[i].isTraded && price >= _orders[i].strikePrice)) {
                    indexes[count] = i;
                    count++;
                }
            }else{
                if ((!_orders[i].isTraded && price >= triggerPrice) || (_orders[i].isTraded && price <= _orders[i].strikePrice)) {
                    indexes[count] = i;
                    count++;
                }
            }
        }
        return (count, indexes);
    }

    function _performOpportunity(
        uint256 price,
        uint256[] memory _indexes,
        DoppiCore.DualAssetPosition[] memory _orders,
        bool _isBuy
    ) internal {
            
        for (uint256 j = 0; j < _indexes.length; j++) {
            uint256 i = _indexes[j];
            if (i >= _orders.length) continue;

            uint256 buffer = _orders[i].strikePrice.mulDiv(tolerance, 10000);
            // take opportunity
            if (_isNotTradedTriggered(_isBuy, _orders[i], price, buffer)) {
                doppiCore.adminSwap(_orders[i].owner, _orders[i].amount, price, i, _isBuy);
            }else if (_isTradedTriggered(_isBuy, _orders[i], price, buffer)) { // unwinding take profit

                (, uint256 profit) = doppiCore.adminUnwind(_orders[i].owner, _orders[i].swappedAmount, price, i, !_isBuy);
                if (_isBuy) {
                    profitAssetA += profit;
                } else {
                    profitAssetB += profit;
                }
            }
        }
    }

    function _isNotTradedTriggered(
        bool _isBuy,
        DoppiCore.DualAssetPosition memory _order,
        uint256 _price,
        uint256 _buffer
    ) internal pure returns (bool) {
        uint256 triggerPrice = 0;
        if (_isBuy) {
            triggerPrice = _order.strikePrice + _buffer;
            return !_order.isTraded && _price <= triggerPrice;                   
        } else {
            triggerPrice = _order.strikePrice - _buffer;
            return !_order.isTraded && _price >= triggerPrice;
        }
    }

    function _isTradedTriggered(bool _isBuy, DoppiCore.DualAssetPosition memory _order, uint256 _price, uint256 _buffer)
        internal
        pure
        returns (bool)
    {
        uint256 triggerPrice = 0;
        if (_isBuy) {
            triggerPrice = _order.strikePrice + _buffer;
            return _order.isTraded && _price >= triggerPrice;
        } else {
            return _order.isTraded && _price <= _order.strikePrice;
        }
    }
}
