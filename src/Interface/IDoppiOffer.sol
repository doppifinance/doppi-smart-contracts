// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "../mainnet/DoppiCoreTypes.sol";

interface IDoppiOffer {
    function getOneDayBuffer(
        uint256 _price,
        bool isBuy
    ) external view returns (uint256 onedayVol);
    function getOffer(
        bool _isBuy,
        uint8 _numDays,
        uint8 _strikeZone
    ) external view returns (DualAssetOffer memory offer);

    function getBuyOffers(
        uint8 _numDays
    ) external view returns (DualAssetOffer[] memory buyoffers);

    function getSellOffers(
        uint8 _numDays
    ) external view returns (DualAssetOffer[] memory selloffers);

    function getAllOffers(
        uint8 _numDays
    )
        external
        view
        returns (
            DualAssetOffer[] memory buyoffers,
            DualAssetOffer[] memory selloffers
        );

    function setRegression(
        uint256 _daysInTimestamp,
        int256 _buya,
        int256 _buyb,
        int256 _buyc,
        int256 _sella,
        int256 _sellb,
        int256 _sellc
    ) external;
    function getImpliedVol(
        uint256 _daysInTimestamp,
        uint256 _price,
        bool _isBuy
    ) external view returns (uint256 markIV, uint256 lastUpdated);
    function getBuyAPR(
        uint256 timeToExpiry,
        uint256 _spot,
        uint256 _strikeBuy
    ) external view returns (uint32 buyapr, uint256 delta);
    function getSellAPR(
        uint256 timeToExpiry,
        uint256 _spot,
        uint256 _strikeSell
    ) external view returns (uint32 sellapr, uint256 delta);

    function getSingleOffer(
        bool _isBuy,
        uint8 _numDays,
        uint8 _strikeZone,
        uint256 _price
    ) external view returns (DualAssetOffer memory offer);
    function verifyOffer(bool _isBuy, uint8 _numDays, uint8 _strikeZone, uint256 _price, uint256 maxRawAPR)
        external
        view
        returns (DualAssetOffer memory offer);
    function getPriceGapPerOffer() external view returns (uint256);
    function TOTAL_OFFER() external view returns (uint256);
}
