// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

interface IDoppiPoints {

    function recordTrade(address trader, uint256 volumeInUSDT) external;
    function resetPoint(address trader) external;
    function getCurrentMonthId() external view returns (uint24);
    function getMonthlyVolume(address trader, uint24 monthId) external view returns (uint256);
    function claimedPoint(address trader) external view returns (uint24 claimedMonthId, uint256 totalPointClaimed);
    function getAllPointData(
        address trader
    )
        external
        view
        returns (
            uint256 totalClaimedPoint,
            uint256 readyPoint,
            uint256 currentMonthPoint
        );
    function deductPointsForFee(address trader, uint256 points) external;
    function setBotVolumeMultiplier(uint256 numerator, uint256 denominator) external;
    function setCoreRegistrar(address registrar, bool allowed) external;
    function registerCore(address core, address factory) external;
    function paused() external view returns (bool);
}
