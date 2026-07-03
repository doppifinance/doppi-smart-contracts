// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPrivateLiquidityAdmin {
    function setDoppiCore(address _doppiCore) external;
    function setDoppiTraderFactory(address _traderFactory) external;
    function setEntryPoint(address entryPoint, bool isValid) external;
}
