// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPrivateRouterAdmin {
    function setDoppiCore(address _doppiCore) external;
    function setAllowedUser(address user, bool allowed) external;
    function setPause() external;
    function setUnPause() external;
    function setEmergencyMode(bool _emergency) external;
}

interface IPrivateRouterView {
    function entryPointA() external view returns (address);
    function entryPointB() external view returns (address);
}
