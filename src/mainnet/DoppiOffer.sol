// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Library/SignedSafeDecimalMath.sol";
import "../Library/SafeDecimalMath.sol";
import "../Interface/IDoppiOffer.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import {IBlackScholes} from "../Interface/IBlackScholes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "forge-std/console.sol";

// Simple MarkIV Contract
contract DoppiOffer is IDoppiOffer, Ownable {
    using SafeDecimalMath for uint256;
    using SignedSafeDecimalMath for int256;

    struct RegressionVar {
        int256 a;
        int256 b;
        int256 c;
        uint256 lastUpdated;
    }

    
    uint256 public MIN_BUFFER = 100;
    uint256 public MAX_BUFFER = 500;
    uint256 public HEDGE_ADJUST = 10;
    uint256 public TOTAL_OFFER = 5;
    uint256 public PRICE_GAP_PEROFFER;
    AggregatorV3Interface chainLinkFeed; 
    uint32 public twapDuration;
    uint32 public maxDelay = 2 minutes;
    address public pancakeV3Pool;
    uint256 private constant SECONDS_PER_YEAR = 31536000;
    uint256 private constant SECONDS_PER_DAY = 86400;
    int256 public priceDecimal = 1e8;
    IBlackScholes public blackScholes;
    mapping(address => bool) public admins;
    mapping(uint256 => RegressionVar) public buyRegression;
    mapping(uint256 => RegressionVar) public sellRegression;

    constructor(IBlackScholes _blackScholes, address _newOracle, uint256 _gapOffer) Ownable(msg.sender) {
        blackScholes = _blackScholes;
        chainLinkFeed = AggregatorV3Interface(_newOracle);
        PRICE_GAP_PEROFFER = _gapOffer;
        admins[msg.sender] = true;
    }

    function setMaxDelay(uint32 _maxDelay) external onlyOwner {
        maxDelay = _maxDelay;
    }

    function setTwapDuration(uint32 _twapDuration) external onlyOwner {
        twapDuration = _twapDuration;
    }

    function setPancakeV3Pool(address _pancakeV3Pool) external onlyOwner {
        pancakeV3Pool = _pancakeV3Pool;
    }

    function setHedgeAdjust(uint32 _adjust) external onlyOwner {
        HEDGE_ADJUST = _adjust;
    }

    function setTotalOffer(uint32 _total) external onlyOwner {
        TOTAL_OFFER = _total;
    }

    function setPriceGapPerOffer(uint32 _priceGap) external onlyOwner {
        PRICE_GAP_PEROFFER = _priceGap;
    }

    function setOracle(address _newOracle) external onlyOwner {
        chainLinkFeed = AggregatorV3Interface(_newOracle);
    }

    function setPriceDecimal(int256 _decimal) external onlyOwner {
        priceDecimal = _decimal;
    }

    function setBuffer(uint256 _min, uint256 _max) external onlyOwner {
        MIN_BUFFER = _min;
        MAX_BUFFER = _max;
    }

    // a,b,c must be * 1e27
    function setRegression(
        uint256 _daysInTimestamp,
        int256 _buya,
        int256 _buyb,
        int256 _buyc,
        int256 _sella,
        int256 _sellb,
        int256 _sellc
    ) external onlyAdmin {
        buyRegression[_daysInTimestamp].a = _buya;
        buyRegression[_daysInTimestamp].b = _buyb;
        buyRegression[_daysInTimestamp].c = _buyc;
        buyRegression[_daysInTimestamp].lastUpdated = block.timestamp;
        
        sellRegression[_daysInTimestamp].a = _sella;
        sellRegression[_daysInTimestamp].b = _sellb;
        sellRegression[_daysInTimestamp].c = _sellc;
        sellRegression[_daysInTimestamp].lastUpdated = block.timestamp;
    }

    /// Format it to 1e16 ie. 30.66 * 1e16
    function getImpliedVol(uint256 _daysInTimestamp, uint256 _price, bool _isBuy)
        external
        view
        returns (uint256 markIV, uint256 lastUpdated)
    {
        return _getImpliedVol(_daysInTimestamp, _price, _isBuy);
    }

    function getSellAPR(uint256 timeToExpiry, uint256 _spot, uint256 _strikeSell)
        external
        view
        returns (uint32 sellapr, uint256 delta)
    {
        (uint256 vsell, uint256 lastUpdated) = _getImpliedVol(timeToExpiry, _strikeSell, false);
        if(vsell == 0) return (0, 0);
        console.log(block.timestamp - SECONDS_PER_DAY, lastUpdated);
        if(lastUpdated < block.timestamp - SECONDS_PER_DAY) return (0, 0);
        IBlackScholes.PricesDeltaStdVega memory data =
            blackScholes.pricesDeltaStdVega(timeToExpiry, vsell, _spot, _strikeSell, 0);
        // console.log(data.callPrice, "data.callPrice");
        delta = blackScholes.abs(data.callDelta / 1e14);
        uint256 hedgeCost = _getHedgeAdjust(vsell, _spot, _strikeSell, delta, timeToExpiry);
        // console.log(hedgeCost, "hedgeCost");
        sellapr = SafeCast.toUint32((data.callPrice - hedgeCost) * 10000 * SECONDS_PER_YEAR / timeToExpiry / _spot);
    }

    function getBuyAPR(uint256 timeToExpiry, uint256 _spot, uint256 _strikeBuy)
        external
        view
        returns (uint32 buyapr, uint256 delta)
    {
        (uint256 vbuy, uint256 lastUpdated) = _getImpliedVol(timeToExpiry, _strikeBuy, true);
        if(vbuy == 0) return (0, 0);
        if(lastUpdated < block.timestamp - SECONDS_PER_DAY) return (0, 0);
        IBlackScholes.PricesDeltaStdVega memory data =
            blackScholes.pricesDeltaStdVega(timeToExpiry, vbuy, _spot, _strikeBuy, 0);

        delta = blackScholes.abs(data.putDelta / 1e14); // format it to 1e5
        uint256 hedgeCost = _getHedgeAdjust(vbuy, _spot, _strikeBuy, delta, timeToExpiry);
        buyapr = SafeCast.toUint32((data.putPrice - hedgeCost) * 10000 * SECONDS_PER_YEAR / timeToExpiry / _spot);
    }

    function getSingleOffer(bool _isBuy, uint32 _numDays, uint8 _strikeZone, uint256 _price)
        external
        view
        returns (DualAssetOffer memory offer)
    {
        return _getOffer(_isBuy, _numDays, _strikeZone, _price);
    }

    function getOffer(bool _isBuy, uint32 _numDays, uint8 _strikeZone)
        external
        view
        returns (DualAssetOffer memory offer)
    {
        uint256 price = DALiquidityLib.getPriceWithFallback(chainLinkFeed, pancakeV3Pool, twapDuration, maxDelay);
        return _getOffer(_isBuy, _numDays, _strikeZone, price);
    }

    function getBuyOffers(uint32 _numDays) 
        external 
        view 
        returns (DualAssetOffer[] memory buyoffers) 
    {
        uint256 price = DALiquidityLib.getPriceWithFallback(chainLinkFeed, pancakeV3Pool, twapDuration, maxDelay);
        buyoffers = new DualAssetOffer[](TOTAL_OFFER);
        for (uint8 i = 0; i < TOTAL_OFFER; ) {
            buyoffers[i] = _getOffer(true, _numDays, i, price);
            unchecked { ++i; }
        }
        return buyoffers;
    }

    function getSellOffers(uint32 _numDays) 
        external 
        view 
        returns (DualAssetOffer[] memory selloffers) 
    {
        uint256 price = DALiquidityLib.getPriceWithFallback(chainLinkFeed, pancakeV3Pool, twapDuration, maxDelay);
        selloffers = new DualAssetOffer[](TOTAL_OFFER);
        for (uint8 i = 0; i < TOTAL_OFFER; ) {
            selloffers[i] = _getOffer(false, _numDays, i, price);
            unchecked { ++i; }
        }
        return selloffers;
    }

    function getAllOffers(uint32 _numDays)
        external
        view
        returns (DualAssetOffer[] memory buyoffers, DualAssetOffer[] memory selloffers)
    {
        buyoffers = this.getBuyOffers(_numDays);
        selloffers = this.getSellOffers(_numDays);
    }

    function getRegression(uint256 _daysInTimestamp)
        external
        view
        returns (RegressionVar memory buy, RegressionVar memory sell)
    {
        buy = buyRegression[_daysInTimestamp];
        sell = sellRegression[_daysInTimestamp];
    }

    function getOneDayBuffer(uint256 _price, bool isBuy)
        external
        view
        returns (uint256 onedayVol)
    {
        (uint256 _iv, uint256 lastUpdated) = _getImpliedVol(SECONDS_PER_DAY, _price, isBuy);
        if(_iv == 0) return 0;
        if(lastUpdated < block.timestamp - SECONDS_PER_DAY) return 0;
        uint256 onedaybuffer = _price * _iv * blackScholes.sqrt(SECONDS_PER_DAY * 1e7 / SECONDS_PER_YEAR * 1e7) / 1e25; // format to 1e18
        onedaybuffer = onedaybuffer * uint256(priceDecimal) / _price / 10000; //return in bps
        onedayVol = onedaybuffer > MAX_BUFFER ? MAX_BUFFER : (onedaybuffer < MIN_BUFFER ? MIN_BUFFER: onedaybuffer);
    }

    function setAdmin(address _admin, bool _status) public onlyOwner {
        admins[_admin] = _status;
    }

    function _getOffer(bool _isBuy, uint32 _numDays, uint8 _strikeZone, uint256 _price)
        internal view returns (DualAssetOffer memory offer)
    {
        uint256 duration = SECONDS_PER_DAY * _numDays;
        uint256 strikePrice = _getStrikePrice(_price, _strikeZone + 1, _isBuy);
        (uint32 apr, uint256 delta) = _isBuy
            ? this.getBuyAPR(duration, _price, strikePrice)
            : this.getSellAPR(duration, _price, strikePrice);
        offer = DualAssetOffer(_price, strikePrice, apr, delta, uint32(block.timestamp + duration));
    }

    function _getImpliedVol(uint256 _daysInTimestamp, uint256 _price, bool _isBuy)
        internal
        view
        returns (uint256 markIV, uint256 lastUpdated)
    {
        int256 price = int256(_price);
        RegressionVar memory regr = _isBuy ? buyRegression[_daysInTimestamp] : sellRegression[_daysInTimestamp];
        markIV = uint256((((((regr.a * price) / priceDecimal) * price) / priceDecimal) + ((regr.b * price) / priceDecimal) + regr.c)) / 1e11;
        lastUpdated = regr.lastUpdated;
    }

    function _getHedgeAdjust(uint256 _iv, uint256 _price, uint256 _strikeprice, uint256 _delta, uint256 _timeToExpiry)
        internal
        view
        returns (uint256 hedgeCost)
    {
        uint256 onedaybuffer = _price * _iv * blackScholes.sqrt(_timeToExpiry * 1e7 / SECONDS_PER_YEAR * 1e7) / 1e25; // format to 1e18
        uint256 downsideMove = _strikeprice - onedaybuffer;
        if(downsideMove > _strikeprice) return 0;
        hedgeCost = (_strikeprice - downsideMove) * _delta / 10000 / HEDGE_ADJUST;
    }

    function _getStrikePrice(uint256 _price, uint8 _strikeZone, bool _isBuy) internal view returns (uint256) {
        uint256 priceGapWithDecimals = PRICE_GAP_PEROFFER * uint256(priceDecimal);
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * _strikeZone) : _price + (priceGapWithDecimals * _strikeZone);
    }

    modifier onlyAdmin() {
        require(admins[msg.sender], "only admin");
        _;
    }
}
