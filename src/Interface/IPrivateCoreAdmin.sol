// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPrivateCoreAdmin {
    function setEmergencyMode(bool _emergency) external;
    function setPause() external;
    function setUnPause() external;
    function setUpkeeps_per_check(uint16 _percheck) external;
    function setMinOrder(uint256 _minOrderA, uint256 _minOrderB) external;
    function setMaxSwap(uint256 _maxSwap) external;
    function setAPRTolerance(uint16 _toleranceBP) external;
    function setTreasury(address _treasury, uint24 _treasury_fee) external;
    function setOpportunityBot(address _opportunityBot, bool _status) external;
    function setDoppiTraderFactory(address _traderFactory) external;
}
