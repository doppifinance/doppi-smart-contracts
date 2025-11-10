// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./DoppiCore.sol";
import "../Interface/AutomationCompatibleInterface.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
// import "forge-std/console.sol";

contract DoppiOpportunity is Ownable, Pausable, AutomationCompatibleInterface {
    DoppiCore public immutable doppiCore;
    IDoppiLiquidity public immutable doppiLP;
    DoppiConfig public doppiConfig;
    address public s_forwarderAddress;
    uint256 public UPKEEPS_PER_CHECK = 5; // Process 5 upkeeps per check

    event OppPerformed(bool isBuy, address indexed trader, uint256 price, uint256 amount, uint256 amountOut);
    event OppUnwindPerformed(bool isBuy, address indexed trader, uint256 price, uint256 swappedAmount, uint256 amountOut, uint256 profit, address profitToken);
    
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
        
        if(paused()) return (false, bytes(""));

        uint256 price = doppiLP.getPrice();
        DualAssetPosition[] memory buys = doppiCore.get_positions_buy();
        DualAssetPosition[] memory sells = doppiCore.get_positions_sell();
        
        (uint256 buyCount, uint256[] memory buyIndexes) = _checkOpportunity(price, buys, true);
        (uint256 sellCount, uint256[] memory sellIndexes) = _checkOpportunity(price, sells, false);
        
        upkeepNeeded = (buyCount > 0 || sellCount > 0);
        
        if (upkeepNeeded) {
            performData = abi.encode(price, buyIndexes, sellIndexes);
        } else {
            performData = bytes("");
        }
        
        return (upkeepNeeded, performData);
    }

    function performUpkeep(bytes calldata performData) external override onlyForwarder {
        
        if(paused()) return;
        
        (uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) =
            abi.decode(performData, (uint256, uint256[], uint256[]));

        uint256 currentPrice = doppiLP.getPrice();
        uint256 priceChance = price * 10000 / currentPrice;
        if (priceChance > 10000 + doppiConfig.tolerance() || priceChance < 10000 - doppiConfig.tolerance()) {
            return;
        }        
        _opportunity_bot(price, buyIndexes, sellIndexes);
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }

    function setUpkeeps_per_check(uint24 _percheck) external onlyOwner {
        UPKEEPS_PER_CHECK = _percheck;
    }

    function _opportunity_bot(uint256 price, uint256[] memory buyIndexes, uint256[] memory sellIndexes) internal {
        if (buyIndexes.length > 0) {
            DualAssetPosition[] memory buys = doppiCore.get_positions_buy();
            _performOpportunity(price, buyIndexes, buys, true);
        }
        
        if (sellIndexes.length > 0) {
            DualAssetPosition[] memory sells = doppiCore.get_positions_sell();
            _performOpportunity(price, sellIndexes, sells, false);
        }
    }

    function _checkOpportunity(uint256 price, DualAssetPosition[] memory _orders, bool _isBuy)
        internal
        view
        returns (uint256 count, uint256[] memory indexes)
    {
        if(_orders.length == 0) return (count, indexes);

        indexes = new uint256[](UPKEEPS_PER_CHECK);
        count = 0;

        uint256 oneDayMove = doppiCore.doppiOffer().getOneDayBuffer(price, _isBuy);
        for (uint256 i = 0; i < _orders.length && count < UPKEEPS_PER_CHECK; ) {
            uint256 buffer = _orders[i].strikePrice * oneDayMove / 10000;
            
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
        // If we found fewer than max, trim the array
        if (count < UPKEEPS_PER_CHECK) {
            uint256[] memory trimmed = new uint256[](count);
            for (uint256 j = 0; j < count; j++) {
                trimmed[j] = indexes[j];
            }
            return (count, trimmed);
        }
        
        return (count, indexes);
    }

    function _performOpportunity(
        uint256 price,
        uint256[] memory _indexes,
        DualAssetPosition[] memory _orders,
        bool _isBuy
    ) internal {
        
        uint256 oneDayMove = doppiCore.doppiOffer().getOneDayBuffer(price, _isBuy);
                
        for (uint256 j = 0; j < _indexes.length; ) {
            uint256 i = _indexes[j];
            if (i < _orders.length) {
                uint256 bufferUnwind = _orders[i].strikePrice * doppiConfig.tolerance() / 10000;
                uint256 buffer = _orders[i].strikePrice * oneDayMove / 10000;
                if (_isNotTradedTriggered(_isBuy, _orders[i], price, buffer)) {
                    (uint256 amountOut, ) = doppiCore.opportunitySwap(_orders[i].owner, _orders[i].amount, price, i, _isBuy);
                    emit OppPerformed(_isBuy, _orders[i].owner, price, _orders[i].amount, amountOut);
                } else if (_isTradedTriggered(_isBuy, _orders[i], price, bufferUnwind)) {
                    (uint256 amountOut, uint256 profit) = doppiCore.opportunityUnwind(_orders[i].owner, _orders[i].swappedAmount, price, i, !_isBuy);
                    emit OppUnwindPerformed(_isBuy, _orders[i].owner, price, _orders[i].swappedAmount, amountOut, profit, _isBuy ? address(doppiCore.assetA()): address(doppiCore.assetB()));
                }
            }
            unchecked { ++j; }
        }
    }

    function _isNotTradedTriggered(
        bool _isBuy,
        DualAssetPosition memory _order,
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
        DualAssetPosition memory _order,
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

    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "invalid forwarder");
        _;
    }
}