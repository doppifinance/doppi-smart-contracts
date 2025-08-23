// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IImpliedVol {
    function setRegression(
        uint256 _daysInTimestamp,
        int256 _buya,
        int256 _buyb,
        int256 _buyc,
        int256 _sella,
        int256 _sellb,
        int256 _sellc
    ) external;
    function getImpliedVol(uint256 _daysInTimestamp, uint256 _price, bool _isBuy)
        external
        view
        returns (uint256 markIV);
    function getBuyAPR(uint256 timeToExpiry, uint256 _spot, uint256 _strikeBuy)
        external
        view
        returns (uint32 buyapr, uint256 delta);
    function getSellAPR(uint256 timeToExpiry, uint256 _spot, uint256 _strikeSell)
        external
        view
        returns (uint32 sellapr, uint256 delta);
}
