// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ConfigParam} from "../mainnet/DoppiLiquidityTypes.sol";

interface IPrivateLiquidityAdmin {
    function setDoppiCore(address _doppiCore) external;
    function setDoppiTraderFactory(address _traderFactory) external;
    function setEntryPoint(address entryPoint, bool isValid) external;
    function setUnPause() external;
    function setPause() external;
    function setConfig(ConfigParam memory _config) external;
}
