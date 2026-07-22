// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ISetForwarder {
    function setForwarderAddress(address forwarderAddress) external;
}

interface ISetTraderFactory {
    function setDoppiTraderFactory(address _traderFactory) external;
}

interface IPrivateBot {
    function validTrader() external view returns (address);
    function setForwarderAddress(address forwarderAddress) external;
}

interface ISetPrivateAutomationHub {
    function setPrivateAutomationHub(address privateHub) external;
}

interface IPrivateFeePoolAdmin {
    function setAuthorizedCore(address core, bool allowed) external;
}
