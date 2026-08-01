// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Library/SignedSafeDecimalMath.sol";
import "../Library/SafeDecimalMath.sol";
import "../Interface/IDoppiOffer.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import {IBlackScholes} from "../Interface/IBlackScholes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// import "forge-std/console.sol";

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
    uint32 public MAX_OFFER_APR = 100000; // 1000% APR in basis points
    uint256 public PRICE_GAP_PEROFFER;
    uint256 public priceGapWithDecimals;
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
        priceGapWithDecimals = _gapOffer * uint256(priceDecimal);
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

    function setPriceGapPerOffer(uint256 _priceGap) external onlyOwner {
        PRICE_GAP_PEROFFER = _priceGap;
        priceGapWithDecimals = _priceGap * uint256(priceDecimal);
    }

    function setMaxOfferAPR(uint32 _maxOfferAPR) external onlyOwner {
        require(_maxOfferAPR > 0, "max apr must be > 0");
        MAX_OFFER_APR = _maxOfferAPR;
    }

    function setOracle(address _newOracle) external onlyOwner {
        chainLinkFeed = AggregatorV3Interface(_newOracle);
    }

    function setPriceDecimal(int256 _decimal) external onlyOwner {
        priceDecimal = _decimal;
        priceGapWithDecimals = PRICE_GAP_PEROFFER * uint256(priceDecimal);
    }

    function setBuffer(uint256 _min, uint256 _max) external onlyOwner {
        require(_min < _max, "min must be less than max");
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

    function getPriceGapPerOffer() external view returns (uint256) {
        return PRICE_GAP_PEROFFER;
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
        return _getSellAPR(timeToExpiry, _spot, _strikeSell);
    }

    function getBuyAPR(uint256 timeToExpiry, uint256 _spot, uint256 _strikeBuy)
        external
        view
        returns (uint32 buyapr, uint256 delta)
    {
        return _getBuyAPR(timeToExpiry, _spot, _strikeBuy);
    }

    function getSingleOffer(bool _isBuy, uint8 _numDays, uint8 _strikeZone, uint256 _price)
        external
        view
        returns (DualAssetOffer memory offer)
    {
        return _getOffer(_isBuy, _numDays, _strikeZone, _price);
    }

    function verifyOffer(bool _isBuy, uint8 _numDays, uint8 _strikeZone, uint256 _price, uint256 maxRawAPR)
        external
        view
        returns (DualAssetOffer memory offer)
    {
        if(maxRawAPR == 0) return _getOffer(_isBuy, _numDays, _strikeZone, _price);
        uint256 roundedPrice = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _getOfferWithMaxRawAPR(_isBuy, _numDays * SECONDS_PER_DAY, _strikeZone, _price, roundedPrice, maxRawAPR);
    }

    function getOffer(bool _isBuy, uint8 _numDays, uint8 _strikeZone)
        external
        view
        returns (DualAssetOffer memory offer)
    {
        uint256 price = DALiquidityLib.getPriceWithFallback(chainLinkFeed, pancakeV3Pool, twapDuration, maxDelay);
        return _getOffer(_isBuy, _numDays, _strikeZone, price);
    }

    function getBuyOffers(uint8 _numDays) 
        external 
        view 
        returns (DualAssetOffer[] memory buyoffers) 
    {
        return _getBuyOffers(_numDays);
    }

    function getSellOffers(uint8 _numDays) 
        external 
        view 
        returns (DualAssetOffer[] memory selloffers) 
    {
        return _getSellOffers(_numDays);
    }

    function getAllOffers(uint8 _numDays)
        external
        view
        returns (DualAssetOffer[] memory buyoffers, DualAssetOffer[] memory selloffers)
    {
        buyoffers = _getBuyOffers(_numDays);
        selloffers = _getSellOffers(_numDays);
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

    function _getSellOffers(uint8 _numDays) 
        internal 
        view 
        returns (DualAssetOffer[] memory selloffers) 
    {
        uint256 price = DALiquidityLib.getPriceWithFallback(chainLinkFeed, pancakeV3Pool, twapDuration, maxDelay);
        uint256 duration = SECONDS_PER_DAY * _numDays;
        uint256 roundedPrice = (price / priceGapWithDecimals) * priceGapWithDecimals;
        uint256 strikePriceZone0 = roundedPrice + priceGapWithDecimals;

        (uint256 maxRawAPR, uint256 delta0) = _getSellAPRRaw(duration, price, strikePriceZone0);
        selloffers = new DualAssetOffer[](TOTAL_OFFER);
        selloffers[0] = _packOffer(price, strikePriceZone0, maxRawAPR, delta0, duration, maxRawAPR);

        for (uint8 i = 1; i < TOTAL_OFFER; ) {
            selloffers[i] = _getOfferWithMaxRawAPR(false, duration, i, price, roundedPrice, maxRawAPR);
            unchecked { ++i; }
        }
        return selloffers;
    }

    function _getBuyOffers(uint8 _numDays) 
        internal 
        view 
        returns (DualAssetOffer[] memory buyoffers) 
    {
        uint256 price = DALiquidityLib.getPriceWithFallback(chainLinkFeed, pancakeV3Pool, twapDuration, maxDelay);
        uint256 duration = SECONDS_PER_DAY * _numDays;
        uint256 roundedPrice = (price / priceGapWithDecimals) * priceGapWithDecimals;
        uint256 strikePriceZone0 = roundedPrice;

        (uint256 maxRawAPR, uint256 delta0) = _getBuyAPRRaw(duration, price, strikePriceZone0);
        buyoffers = new DualAssetOffer[](TOTAL_OFFER);
        buyoffers[0] = _packOffer(price, strikePriceZone0, maxRawAPR, delta0, duration, maxRawAPR);

        for (uint8 i = 1; i < TOTAL_OFFER; ) {
            buyoffers[i] = _getOfferWithMaxRawAPR(true, duration, i, price, roundedPrice, maxRawAPR);
            unchecked { ++i; }
        }
        return buyoffers;
    }

    function _getBuyAPR(uint256 timeToExpiry, uint256 _spot, uint256 _strikeBuy)
        internal
        view
        returns (uint32 buyapr, uint256 delta)
    {
        (uint256 rawAPR, uint256 _delta) = _getBuyAPRRaw(timeToExpiry, _spot, _strikeBuy);
        buyapr = _clampAPR(rawAPR);
        delta = _delta;
    }

    function _getBuyAPRRaw(uint256 timeToExpiry, uint256 _spot, uint256 _strikeBuy)
        internal
        view
        returns (uint256 buyapr, uint256 delta)
    {
        (uint256 vbuy, uint256 lastUpdated) = _getImpliedVol(timeToExpiry, _strikeBuy, true);
        if(vbuy == 0) return (0, 0);
        if(lastUpdated < block.timestamp - SECONDS_PER_DAY) return (0, 0);
        IBlackScholes.PricesDeltaStdVega memory data =
            blackScholes.pricesDeltaStdVega(timeToExpiry, vbuy, _spot, _strikeBuy, 0);

        delta = blackScholes.abs(data.putDelta / 1e14); // format it to 1e5
        uint256 hedgeCost = _getHedgeAdjust(vbuy, _spot, _strikeBuy, delta, timeToExpiry);
        buyapr = (data.putPrice - hedgeCost) * 10000 * SECONDS_PER_YEAR / timeToExpiry / _spot;
    }

    function _getSellAPR(uint256 timeToExpiry, uint256 _spot, uint256 _strikeSell)
        internal
        view
        returns (uint32 sellapr, uint256 delta)
    {
        (uint256 rawAPR, uint256 _delta) = _getSellAPRRaw(timeToExpiry, _spot, _strikeSell);
        sellapr = _clampAPR(rawAPR);
        delta = _delta;
    }

    function _getSellAPRRaw(uint256 timeToExpiry, uint256 _spot, uint256 _strikeSell)
        internal
        view
        returns (uint256 sellapr, uint256 delta)
    {
        (uint256 vsell, uint256 lastUpdated) = _getImpliedVol(timeToExpiry, _strikeSell, false);
        if(vsell == 0) return (0, 0);
        if(lastUpdated < block.timestamp - SECONDS_PER_DAY) return (0, 0);
        IBlackScholes.PricesDeltaStdVega memory data =
            blackScholes.pricesDeltaStdVega(timeToExpiry, vsell, _spot, _strikeSell, 0);
        delta = blackScholes.abs(data.callDelta / 1e14);
        uint256 hedgeCost = _getHedgeAdjust(vsell, _spot, _strikeSell, delta, timeToExpiry);
        sellapr = (data.callPrice - hedgeCost) * 10000 * SECONDS_PER_YEAR / timeToExpiry / _spot;
    }

    function _getOffer(bool _isBuy, uint8 _numDays, uint8 _strikeZone, uint256 _price)
        internal view returns (DualAssetOffer memory offer)
    {
        require(_strikeZone < TOTAL_OFFER, "zone out of range");
        uint256 duration = SECONDS_PER_DAY * _numDays;
        uint256 roundedPrice = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        uint256 strikePrice = _isBuy
            ? roundedPrice - (priceGapWithDecimals * _strikeZone)
            : roundedPrice + (priceGapWithDecimals * (_strikeZone + 1));

        (uint256 rawAPR, uint256 delta) = _isBuy
            ? _getBuyAPRRaw(duration, _price, strikePrice)
            : _getSellAPRRaw(duration, _price, strikePrice);

        uint256 maxRawAPR = rawAPR;
        if (_strikeZone != 0) {
            uint256 strikePriceZone0 = _isBuy ? roundedPrice : roundedPrice + priceGapWithDecimals;
            (maxRawAPR, ) = _isBuy
                ? _getBuyAPRRaw(duration, _price, strikePriceZone0)
                : _getSellAPRRaw(duration, _price, strikePriceZone0);
        }

        return _packOffer(_price, strikePrice, rawAPR, delta, duration, maxRawAPR);
    }

    function _getOfferWithMaxRawAPR(
        bool _isBuy,
        uint256 _duration,
        uint8 _strikeZone,
        uint256 _price,
        uint256 _roundedPrice,
        uint256 _maxRawAPR
    ) internal view returns (DualAssetOffer memory offer) {
        uint256 strikePrice = _isBuy
            ? _roundedPrice - (priceGapWithDecimals * _strikeZone)
            : _roundedPrice + (priceGapWithDecimals * (_strikeZone + 1));

        (uint256 rawAPR, uint256 delta) = _isBuy
            ? _getBuyAPRRaw(_duration, _price, strikePrice)
            : _getSellAPRRaw(_duration, _price, strikePrice);

        return _packOffer(_price, strikePrice, rawAPR, delta, _duration, _maxRawAPR);
    }

    function _packOffer(
        uint256 _price,
        uint256 _strikePrice,
        uint256 _rawAPR,
        uint256 _delta,
        uint256 _duration,
        uint256 _maxRawAPR
    ) internal view returns (DualAssetOffer memory offer) {
        uint256 maxOfferAPR = MAX_OFFER_APR;
        uint256 scaledAPR = _rawAPR;
        if (_maxRawAPR > maxOfferAPR && _rawAPR > 0) {
            scaledAPR = Math.mulDiv(_rawAPR, maxOfferAPR, _maxRawAPR);
        }

        uint32 apr = scaledAPR > maxOfferAPR ? uint32(maxOfferAPR) : uint32(scaledAPR);
        offer = DualAssetOffer(_price, _strikePrice, apr, _delta, uint32(block.timestamp + _duration));
    }

    function _getImpliedVol(uint256 _daysInTimestamp, uint256 _price, bool _isBuy)
        internal
        view
        returns (uint256 markIV, uint256 lastUpdated)
    {
        int256 price = int256(_price);
        RegressionVar memory regr = _isBuy ? buyRegression[_daysInTimestamp] : sellRegression[_daysInTimestamp];
        int256 rawIV = (((((regr.a * price) / priceDecimal) * price) / priceDecimal)
                    + ((regr.b * price) / priceDecimal)
                    + regr.c);
        if (rawIV <= 0) return (0, regr.lastUpdated);  // callers already handle zero IV
        markIV = uint256(rawIV) / 1e11;
        lastUpdated = regr.lastUpdated;
    }

    function _getHedgeAdjust(uint256 _iv, uint256 _price, uint256 _strikeprice, uint256 _delta, uint256 _timeToExpiry)
        internal
        view
        returns (uint256 hedgeCost)
    {
        uint256 onedaybuffer = _price * _iv * blackScholes.sqrt(_timeToExpiry * 1e7 / SECONDS_PER_YEAR * 1e7) / 1e25; // format to 1e18
        if (onedaybuffer >= _strikeprice) {
            return 0;
        }
        uint256 downsideMove = _strikeprice - onedaybuffer;
        if(downsideMove > _strikeprice) return 0;
        hedgeCost = (_strikeprice - downsideMove) * _delta / 10000 / HEDGE_ADJUST;
    }

    function _getStrikePrice(uint256 _price, uint8 _strikeZone, bool _isBuy) internal view returns (uint256) {
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * (_strikeZone - 1)) : _price + (priceGapWithDecimals * _strikeZone);
    }

    function _clampAPR(uint256 _apr) internal view returns (uint32) {
        return _apr > MAX_OFFER_APR ? MAX_OFFER_APR : uint32(_apr);
    }

    modifier onlyAdmin() {
        require(admins[msg.sender], "only admin");
        _;
    }
}
