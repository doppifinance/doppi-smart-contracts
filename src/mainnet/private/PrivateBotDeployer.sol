// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {DoppiTrader} from "../DoppiTrader.sol";
import {IDoppiTraderFactory} from "../../Interface/IDoppiTraderFactory.sol";

interface IPrivateCoreInit {
    function initialize(address assetA, address assetB, address doppiLP, address doppiOffer, address doppiPoints, address owner, address doppiOpportunity) external;
}

interface IPrivateOpportunityInit {
    function initialize(address _doppiCore) external;
}

interface IOwnable {
    function transferOwnership(address newOwner) external;
}

/// @notice Stateless deployer that builds a full private bot stack.
/// @dev Called only by PrivateDoppiTraderFactory. Holds the heavy core/opportunity/bot
///      deployment bytecode so the factory runtime stays small.
contract PrivateBotDeployer {
    error OnlyFactory();

    IERC20  public immutable assetA;
    IERC20  public immutable assetB;
    address public immutable sharedDoppiOffer;
    address public immutable sharedDoppiPoints;
    address public immutable doppiUpKeepManager;
    /// @dev The factory that created this deployer; only it may call deploy().
    address public immutable factory;

    constructor(
        IERC20  _assetA,
        IERC20  _assetB,
        address _sharedDoppiOffer,
        address _sharedDoppiPoints,
        address _doppiUpKeepManager
    ) {
        assetA             = _assetA;
        assetB             = _assetB;
        sharedDoppiOffer   = _sharedDoppiOffer;
        sharedDoppiPoints  = _sharedDoppiPoints;
        doppiUpKeepManager = _doppiUpKeepManager;
        factory            = msg.sender; // set to factory during factory construction
    }

    function deploy(address traderBotImpl, address coreImpl, address opportunityImpl, address trader, address liquidity, address router, uint24[] calldata weights)
        external
        returns (address bot, address core, address opportunity)
    {
        if (msg.sender != factory) revert OnlyFactory();

        // 1. Clone and wire core + opportunity storage
        opportunity = Clones.clone(opportunityImpl);
        core        = Clones.clone(coreImpl);

        IPrivateOpportunityInit(opportunity).initialize(core);

        IPrivateCoreInit(core).initialize(
            address(assetA),
            address(assetB),
            liquidity,
            sharedDoppiOffer,
            sharedDoppiPoints,
            factory,          // factory owns core
            opportunity
        );

        // 2. Clone trader bot
        bot = Clones.clone(traderBotImpl);

        // 3. Initialize trader bot
        DoppiTrader(bot).initialize(
            trader,
            assetA,
            assetB,
            liquidity,
            router,
            core,
            doppiUpKeepManager,
            weights
        );

        // Keep previous behavior: factory owns the bot so it can perform owner/upkeep admin calls.
        IOwnable(bot).transferOwnership(factory);
    }
}
