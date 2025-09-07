// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./DoppiCore.sol";
import "../Interface/AutomationCompatibleInterface.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DoppiOpportunity is Ownable, AutomationCompatibleInterface {
    DoppiCore public immutable doppiCore;
    IDoppiLiquidity public immutable doppiLP;
    DoppiConfig public doppiConfig;
    uint256 public profitAssetA;
    uint256 public profitAssetB;
    address public s_forwarderAddress;

    constructor(address _doppiCore, address _doppiLP) Ownable(msg.sender) {
        doppiCore = DoppiCore(_doppiCore);
        doppiLP = IDoppiLiquidity(_doppiLP);
    }

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        s_forwarderAddress = forwarderAddress;
    }

    function setDoppiConfig(DoppiConfig _doppiConfig) external onlyOwner {
        doppiConfig = _doppiConfig;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256 price = doppiLP.getPrice();
        DoppiCore.DualAssetPosition[] memory buys = doppiCore.get_positions_buy();
        DoppiCore.DualAssetPosition[] memory sells = doppiCore.get_positions_sell();
        
        (uint256 buyCount, uint256[] memory buyIndexes) = _checkOpportunity(price, buys, true);
        (uint256 sellCount, uint256[] memory sellIndexes) = _checkOpportunity(price, sells, false);
        
        upkeepNeeded = (buyCount > 0 || sellCount > 0);
        
        if (upkeepNeeded) {
            performData = abi.encode(price, _trimArray(buyIndexes, buyCount), _trimArray(sellIndexes, sellCount));
        } else {
            performData = "";
        }
        
        return (upkeepNeeded, performData);
    }

    function performUpkeep(bytes calldata performData) external override onlyForwarder {
        (uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) =
            abi.decode(performData, (uint256, uint256[], uint256[]));

        uint256 currentPrice = doppiLP.getPrice();
        uint256 priceChance = price * 10000 / currentPrice;
        
        if (priceChance > 10000 + doppiConfig.tolerance() || priceChance < 10000 - doppiConfig.tolerance()) {
            return;
        }
        
        _opportunity_bot(price, buyIndexes, sellIndexes);
    }

    function _opportunity_bot(uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) internal {
        if (buyIndexes.length > 0) {
            DoppiCore.DualAssetPosition[] memory buys = doppiCore.get_positions_buy();
            _performOpportunity(price, buyIndexes, buys, true);
        }
        
        if (sellIndexes.length > 0) {
            DoppiCore.DualAssetPosition[] memory sells = doppiCore.get_positions_sell();
            _performOpportunity(price, sellIndexes, sells, false);
        }
    }

    function _checkOpportunity(uint256 price, DoppiCore.DualAssetPosition[] memory _orders, bool _isBuy)
        internal
        view
        returns (uint256 count, uint256[] memory indexes)
    {
        indexes = new uint256[](_orders.length);
        count = 0;

        for (uint256 i = 0; i < _orders.length; ) {
            uint256 buffer = _orders[i].strikePrice * doppiConfig.tolerance() / 10000;
            
            if (_isBuy) {
                uint256 triggerPrice = _orders[i].strikePrice - buffer;
                if ((!_orders[i].isTraded && price <= triggerPrice) || (_orders[i].isTraded && price >= _orders[i].strikePrice)) {
                    indexes[count] = i;
                    count++;
                }
            } else {
                uint256 triggerPrice = _orders[i].strikePrice + buffer;
                if ((!_orders[i].isTraded && price >= triggerPrice) || (_orders[i].isTraded && price <= _orders[i].strikePrice)) {
                    indexes[count] = i;
                    count++;
                }
            }
            unchecked { ++i; }
        }
        return (count, indexes);
    }

    function _performOpportunity(
        uint256 price,
        uint256[] memory _indexes,
        DoppiCore.DualAssetPosition[] memory _orders,
        bool _isBuy
    ) internal {
        for (uint256 j = 0; j < _indexes.length; ) {
            uint256 i = _indexes[j];
            if (i < _orders.length) {
                uint256 buffer = _orders[i].strikePrice * doppiConfig.tolerance() / 10000;
                
                if (_isNotTradedTriggered(_isBuy, _orders[i], price, buffer)) {
                    doppiCore.opportunitySwap(_orders[i].owner, _orders[i].amount, price, i, _isBuy);
                } else if (_isTradedTriggered(_isBuy, _orders[i], price, buffer)) {
                    (, uint256 profit) = doppiCore.opportunityUnwind(_orders[i].owner, _orders[i].swappedAmount, price, i, !_isBuy);
                    if (_isBuy) {
                        profitAssetA += profit;
                    } else {
                        profitAssetB += profit;
                    }
                }
            }
            unchecked { ++j; }
        }
    }

    function _isNotTradedTriggered(
        bool _isBuy,
        DoppiCore.DualAssetPosition memory _order,
        uint256 _price,
        uint256 _buffer
    ) internal pure returns (bool) {
        if (_isBuy) {
            uint256 triggerPrice = _order.strikePrice + _buffer;
            return !_order.isTraded && _price <= triggerPrice;
        } else {
            uint256 triggerPrice = _order.strikePrice - _buffer;
            return !_order.isTraded && _price >= triggerPrice;
        }
    }

    function _isTradedTriggered(
        bool _isBuy,
        DoppiCore.DualAssetPosition memory _order,
        uint256 _price,
        uint256 _buffer
    ) internal pure returns (bool) {
        if (_isBuy) {
            uint256 triggerPrice = _order.strikePrice + _buffer;
            return _order.isTraded && _price >= triggerPrice;
        } else {
            return _order.isTraded && _price <= _order.strikePrice;
        }
    }

    function _trimArray(uint256[] memory arr, uint256 count) internal pure returns (uint256[] memory) {
        if (count == arr.length) return arr;
        
        uint256[] memory trimmed = new uint256[](count);
        for (uint256 i = 0; i < count; ) {
            trimmed[i] = arr[i];
            unchecked { ++i; }
        }
        return trimmed;
    }

    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "invalid forwarder");
        _;
    }
}