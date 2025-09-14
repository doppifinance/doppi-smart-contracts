// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Library/SignedSafeDecimalMath.sol";
import "../Library/SafeDecimalMath.sol";
import "../Interface/IImpliedVol.sol";
import {IBlackScholes} from "../Interface/IBlackScholes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "forge-std/console.sol";

// Simple MarkIV Contract
contract ImpliedVol is IImpliedVol, Ownable {
    using SafeDecimalMath for uint256;
    using SignedSafeDecimalMath for int256;

    struct RegressionVar {
        int256 a;
        int256 b;
        int256 c;
    }

    uint256 private constant SECONDS_PER_YEAR = 31536000;
    int256 public priceDecimal = 1e8;
    IBlackScholes public blackScholes;
    mapping(address => bool) public admins;
    mapping(uint256 => RegressionVar) public buyRegression;
    mapping(uint256 => RegressionVar) public sellRegression;

    constructor(IBlackScholes _blackScholes) Ownable(msg.sender) {
        blackScholes = _blackScholes;
        admins[msg.sender] = true;
    }

    function setPriceDecimal(int256 _decimal) public onlyAdmin {
        priceDecimal = _decimal;
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
        sellRegression[_daysInTimestamp].a = _sella;
        sellRegression[_daysInTimestamp].b = _sellb;
        sellRegression[_daysInTimestamp].c = _sellc;
    }

    /// Format it to 1e16 ie. 30.66 * 1e16
    function getImpliedVol(uint256 _daysInTimestamp, uint256 _price, bool _isBuy)
        external
        view
        returns (uint256 markIV)
    {
        return _getImpliedVol(_daysInTimestamp, _price, _isBuy);
    }

    function getSellAPR(uint256 timeToExpiry, uint256 _spot, uint256 _strikeSell)
        external
        view
        returns (uint32 sellapr, uint256 delta)
    {
        uint256 vsell = _getImpliedVol(timeToExpiry, _strikeSell, false);
        if(vsell == 0) return (0, 0);
        IBlackScholes.PricesDeltaStdVega memory data =
            blackScholes.pricesDeltaStdVega(timeToExpiry, vsell, _spot, _strikeSell, 0);
        delta = blackScholes.abs(data.callDelta / 1e14);
        uint256 hedgeCost = _getHedgeAdjust(vsell, _spot, _strikeSell, delta, timeToExpiry);
        sellapr = SafeCast.toUint32((data.callPrice - hedgeCost) * 10000 * SECONDS_PER_YEAR / timeToExpiry / _spot);
    }

    function getBuyAPR(uint256 timeToExpiry, uint256 _spot, uint256 _strikeBuy)
        external
        view
        returns (uint32 buyapr, uint256 delta)
    {
        uint256 vbuy = _getImpliedVol(timeToExpiry, _strikeBuy, true);
        if(vbuy == 0) return (0, 0);
        IBlackScholes.PricesDeltaStdVega memory data =
            blackScholes.pricesDeltaStdVega(timeToExpiry, vbuy, _spot, _strikeBuy, 0);

        delta = blackScholes.abs(data.putDelta / 1e14); // format it to 1e5
        uint256 hedgeCost = _getHedgeAdjust(vbuy, _spot, _strikeBuy, delta, timeToExpiry);
        buyapr = SafeCast.toUint32((data.putPrice - hedgeCost) * 10000 * SECONDS_PER_YEAR / timeToExpiry / _spot);
    }

    function getRegression(uint256 _daysInTimestamp)
        external
        view
        returns (RegressionVar memory buy, RegressionVar memory sell)
    {
        buy = buyRegression[_daysInTimestamp];
        sell = sellRegression[_daysInTimestamp];
    }

    function setAdmin(address _admin, bool _status) public onlyAdmin {
        admins[_admin] = _status;
    }

    function _getImpliedVol(uint256 _daysInTimestamp, uint256 _price, bool _isBuy)
        internal
        view
        returns (uint256 markIV)
    {
        int256 price = int256(_price);
        RegressionVar memory regr = _isBuy ? buyRegression[_daysInTimestamp] : sellRegression[_daysInTimestamp];
        markIV = uint256((((((regr.a * price) / priceDecimal) * price) / priceDecimal) + ((regr.b * price) / priceDecimal) + regr.c)) / 1e11;
    }

    function _getHedgeAdjust(uint256 _iv, uint256 _price, uint256 _strikeprice, uint256 _delta, uint256 _timeToExpiry)
        internal
        view
        returns (uint256 hedgeCost)
    {
        uint256 onedaybuffer = _price * _iv * blackScholes.sqrt(_timeToExpiry * 1e7 / SECONDS_PER_YEAR * 1e7) / 1e25; // format to 1e18
        uint256 downsideMove = _strikeprice - onedaybuffer;
        hedgeCost = (_strikeprice - downsideMove) * _delta / 10000 / 10;
    }

    modifier onlyAdmin() {
        require(admins[msg.sender], "only admin");
        _;
    }
}
