// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {DoppiLiquidity} from "../DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../DoppiLiquidityRouter.sol";
import {IDoppiLiquidity} from "../../Interface/IDoppiLiquidity.sol";
import {ConfigParam} from "../DoppiLiquidityTypes.sol";

interface IOwnable {
    function transferOwnership(address newOwner) external;
}

interface IInitializeLiquidity {
    function initialize(
        string memory _name,
        string memory _symbol,
        address _assetA,
        address _assetB,
        address initialOwner
    ) external;
}

/// @notice Deploys only the private LP + router pair.
/// @dev Split out from the main deployer so factory bytecode stays small.
contract PrivateLiquidityDeployer {
    using Strings for uint256;

    error OnlyFactory();

    IERC20  public immutable assetA;
    IERC20  public immutable assetB;
    address public immutable liquidityImplementation;
    address public immutable factory;

    constructor(IERC20 _assetA, IERC20 _assetB) {
        assetA = _assetA;
        assetB = _assetB;
        liquidityImplementation = address(new DoppiLiquidity("", "", address(0), address(0)));
        factory = msg.sender;
    }

    function deploy(ConfigParam calldata config, uint32 botId)
        external
        returns (address liquidity, address router)
    {
        if (msg.sender != factory) revert OnlyFactory();

        string memory idStr = uint256(botId).toString();

        DoppiLiquidity privateLiquidity = DoppiLiquidity(Clones.clone(liquidityImplementation));
        IInitializeLiquidity(address(privateLiquidity)).initialize(
            string(abi.encodePacked("Doppi Private LP #", idStr)),
            string(abi.encodePacked("DPLP-", idStr)),
            address(assetA),
            address(assetB),
            address(this)
        );
        DoppiLiquidityRouter privateRouter = new DoppiLiquidityRouter(
            assetA,
            assetB,
            IDoppiLiquidity(address(privateLiquidity))
        );

        privateLiquidity.setConfig(config);
        privateLiquidity.setDoppiLiquidityRouter(address(privateRouter));
        privateLiquidity.setForwarderAddress(factory);

        IOwnable(address(privateLiquidity)).transferOwnership(factory);
        IOwnable(address(privateRouter)).transferOwnership(factory);

        liquidity = address(privateLiquidity);
        router = address(privateRouter);
    }
}