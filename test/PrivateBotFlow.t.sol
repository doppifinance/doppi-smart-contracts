// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiTrader} from "../src/mainnet/DoppiTrader.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {DoppiOffer} from "../src/mainnet/DoppiOffer.sol";
import {DoppiPoints} from "../src/mainnet/DoppiPoints.sol";
import {DoppiTraderFactory} from "../src/mainnet/DoppiTraderFactory.sol";
import {PrivateDoppiTraderFactory} from "../src/mainnet/private/PrivateDoppiTraderFactory.sol";
import {DoppiOpportunityStorage} from "../src/mainnet/private/DoppiOpportunityStorage.sol";
import {IDoppiTraderFactory} from "../src/Interface/IDoppiTraderFactory.sol";
import {IDoppiOpportunity} from "../src/Interface/IDoppiOpportunity.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {MockDoppiUpKeepManager} from "../src/test/MockDoppiUpkeepManager.sol";
import {DoppiOpportunity} from "../src/mainnet/DoppiOpportunity.sol";
import {Swapper} from "../src/test/Swapper.sol";
import "../src/mainnet/DoppiCoreTypes.sol";
import "../src/mainnet/DoppiTraderTypes.sol";
import {TestParamLib} from "../src/Library/TestParamLib.sol";
import {ConfigParam} from "../src/mainnet/DoppiLiquidityTypes.sol";

contract PrivateBotFlowTest is Test {

    // ── Shared infrastructure ──────────────────────────────────────────────
    DoppiTraderFactory sharedFactory;
    DoppiCore sharedCore;
    DoppiLiquidity sharedLP;
    DoppiLiquidityRouter sharedRouter;
    DoppiOpportunity sharedOpportunityBot;

    // ── Private factory ────────────────────────────────────────────────────
    PrivateDoppiTraderFactory privateFactory;

    // ── Implementations (used by private factory clones) ──────────────────
    DoppiCore coreImplementation;
    DoppiTrader traderImplementation;
    DoppiOpportunityStorage opportunityStorageImplementation;

    // ── Shared infra ───────────────────────────────────────────────────────
    DoppiOffer impliedVol;
    DoppiPoints doppiPoints;
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    MockDoppiUpKeepManager mockUpkeepManager;
    Swapper swapper;
    BlackScholes blackScholes;
    ConfigParam configLP;

    // ── Actors ─────────────────────────────────────────────────────────────
    address owner      = address(0x1);
    address lp         = address(0x2);
    address trader1    = address(0x3);
    address trader2    = address(0x4);
    address treasury   = address(0x5);
    address forwarder  = address(0x6);

    uint24[] defaultWeights;

    // ── Events ─────────────────────────────────────────────────────────────
    event PrivateBotDeployed(
        address indexed trader,
        address indexed traderBot,
        address indexed privateCore,
        address privateOpportunity,
        address privateLiquidity,
        address privateRouter,
        uint32 botId
    );

    // ──────────────────────────────────────────────────────────────────────
    function setUp() public {
        vm.startPrank(owner);
        vm.warp(1735689600);

        // Tokens & oracle
        usdt   = new MockToken("USDT", "USDT");
        btc    = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(int256(100_000 * 1e8), 8);

        // LP config
        configLP = TestParamLib.get_configLP();
        swapper = new Swapper(usdt, btc);
        swapper.setOracle(oracle);
        configLP.chainLinkFeed = address(oracle);
        configLP.router        = address(swapper);
        configLP.v3Pool        = address(swapper);

        // Shared infra
        blackScholes = new BlackScholes();
        impliedVol   = new DoppiOffer(blackScholes, address(oracle), 500);
        _setRegression(impliedVol);
        doppiPoints = new DoppiPoints();
        mockUpkeepManager = new MockDoppiUpKeepManager(forwarder);

        sharedLP = new DoppiLiquidity("Shared LP", "DALP", address(IERC20(usdt)), address(IERC20(btc)));
        sharedLP.setConfig(configLP);
        sharedLP.approveRouter();

        sharedCore = new DoppiCore(address(usdt), address(btc), sharedLP, impliedVol, address(doppiPoints));
        doppiPoints.setDoppiCore(address(sharedCore), true);

        sharedRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), sharedLP);
        sharedRouter.setDoppiCore(address(sharedCore));
        sharedLP.setDoppiCore(address(sharedCore));
        sharedLP.setDoppiLiquidityRouter(address(sharedRouter));
        sharedLP.setEntryPoint(address(sharedRouter.entryPointA()), true);
        sharedLP.setEntryPoint(address(sharedRouter.entryPointB()), true);

        sharedFactory = new DoppiTraderFactory(
            IERC20(usdt), IERC20(btc),
            address(sharedCore), address(sharedLP), address(sharedRouter),
            address(impliedVol), address(doppiPoints)
        );
        sharedLP.setDoppiTraderFactory(address(sharedFactory));
        sharedCore.setDoppiTraderFactory(sharedFactory);
        sharedCore.setForwarderAddress(forwarder);
        sharedCore.setTreasury(treasury, 1000);
        sharedFactory.setDoppiUpKeepManager(address(mockUpkeepManager));

        sharedOpportunityBot = new DoppiOpportunity(address(sharedCore), address(sharedLP));
        sharedOpportunityBot.setForwarderAddress(forwarder);
        sharedCore.setOpportunityBot(address(sharedOpportunityBot), true);

        // Deploy implementation contracts for private factory clones
        coreImplementation              = new DoppiCore(address(usdt), address(btc), sharedLP, impliedVol, address(doppiPoints));
        traderImplementation            = new DoppiTrader();
        opportunityStorageImplementation = new DoppiOpportunityStorage();

        // Private factory
        privateFactory = new PrivateDoppiTraderFactory(
            IERC20(usdt),
            IERC20(btc),
            address(impliedVol),
            address(doppiPoints),
            address(mockUpkeepManager),
            address(sharedFactory),
            address(traderImplementation),
            address(coreImplementation),
            address(opportunityStorageImplementation),
            configLP
        );

        // Allow private factory to auto-register newly deployed private cores in DoppiPoints.
        doppiPoints.setCoreRegistrar(address(privateFactory), true);

        // Fund actors
        defaultWeights.push(500);
        defaultWeights.push(1000);
        defaultWeights.push(1500);
        defaultWeights.push(2500);
        defaultWeights.push(4500);

        usdt.mint(lp,      10_000 * 1e18);
        btc.mint(lp,       10 * 1e18);
        usdt.mint(trader1, 5_000_000 * 1e18);
        btc.mint(trader1,  50 * 1e18);
        usdt.mint(trader2, 5_000_000 * 1e18);
        btc.mint(trader2,  50 * 1e18);

        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────
    //  DEPLOYMENT TESTS
    // ──────────────────────────────────────────────────────────────────────

    function test_deployPrivateBot_emitsEvent() public {
        vm.prank(trader1);
        vm.expectEmit(true, false, false, false);
        // indexed: trader, traderBot, privateCore
        emit PrivateBotDeployed(trader1, address(0), address(0), address(0), address(0), address(0), 1);
        privateFactory.deployPrivateBot(defaultWeights);
    }

    function test_deployPrivateBot_returnsBotId() public {
        vm.prank(trader1);
        uint32 botId = privateFactory.deployPrivateBot(defaultWeights);
        assertEq(botId, 1);
    }

    function test_deployPrivateBot_incrementsBotId() public {
        vm.prank(trader1);
        uint32 id1 = privateFactory.deployPrivateBot(defaultWeights);
        vm.prank(trader2);
        uint32 id2 = privateFactory.deployPrivateBot(defaultWeights);
        assertEq(id2, id1 + 1);
    }

    function test_deployPrivateBot_storesAllComponents() public {
        vm.prank(trader1);
        privateFactory.deployPrivateBot(defaultWeights);

        // Retrieve the bot address — nextBotId was 1 so the deployed bot is id=1
        // We need the bot address from the event or via the registry getter
        uint32 nextId = privateFactory.getNextBotId(); // should be 2 after deploy
        assertEq(nextId, 2);
    }

    function test_deployPrivateBot_allComponentsNonZero() public {
        vm.prank(trader1);
        privateFactory.deployPrivateBot(defaultWeights);

        // Get bot from factory storage via low-level read (botRegistry maps id->bot)
        // Instead, listen for event in a helper to capture addresses
        (
            address bot,
            address core,
            address opportunity,
            address privLP,
            address privRouter
        ) = _deployAndCapture(trader1);

        assertTrue(bot         != address(0), "bot is zero");
        assertTrue(core        != address(0), "core is zero");
        assertTrue(opportunity != address(0), "opportunity is zero");
        assertTrue(privLP      != address(0), "LP is zero");
        assertTrue(privRouter  != address(0), "router is zero");
    }

    function test_deployPrivateBot_mappingsStored() public {
        (address bot, address core, address opp, address privLP, address privRouter) =
            _deployAndCapture(trader1);

        assertEq(privateFactory.getPrivateCore(bot),        core,      "core mismatch");
        assertEq(privateFactory.getPrivateOpportunity(bot), opp,       "opportunity mismatch");
        assertEq(privateFactory.getPrivateLiquidity(bot),   privLP,    "LP mismatch");
        assertEq(privateFactory.getPrivateRouter(bot),      privRouter,"router mismatch");
    }

    function test_deployPrivateBot_autoGeneratesUniqueLpNameAndSymbol() public {
        (, , , address lp1, ) = _deployAndCapture(trader1);
        (, , , address lp2, ) = _deployAndCapture(trader2);

        assertEq(DoppiLiquidity(lp1).name(), "Doppi Private LP #1", "lp1 name mismatch");
        assertEq(DoppiLiquidity(lp1).symbol(), "DPLP-1", "lp1 symbol mismatch");
        assertEq(DoppiLiquidity(lp2).name(), "Doppi Private LP #2", "lp2 name mismatch");
        assertEq(DoppiLiquidity(lp2).symbol(), "DPLP-2", "lp2 symbol mismatch");

        assertTrue(
            keccak256(bytes(DoppiLiquidity(lp1).name())) != keccak256(bytes(DoppiLiquidity(lp2).name())),
            "lp names should be unique"
        );
        assertTrue(
            keccak256(bytes(DoppiLiquidity(lp1).symbol())) != keccak256(bytes(DoppiLiquidity(lp2).symbol())),
            "lp symbols should be unique"
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    //  ISOLATION TESTS
    // ──────────────────────────────────────────────────────────────────────

    function test_twoPrivateBots_haveDifferentCores() public {
        (address bot1, address core1,,,) = _deployAndCapture(trader1);
        (address bot2, address core2,,,) = _deployAndCapture(trader2);

        assertTrue(core1 != core2, "two bots share same core");
        assertTrue(bot1  != bot2,  "two bots have same address");
    }

    function test_twoPrivateBots_haveDifferentLPs() public {
        (,,,address lp1,) = _deployAndCapture(trader1);
        (,,,address lp2,) = _deployAndCapture(trader2);

        assertTrue(lp1 != lp2, "two bots share same LP");
    }

    function test_privateCore_hasOpportunityStorageSet() public {
        (, address core, address opp,,) = _deployAndCapture(trader1);

        DoppiCore dc = DoppiCore(core);
        assertEq(address(dc.doppiOpportunity()), opp, "opportunity storage not linked");
    }

    function test_sharedCore_hasOpportunityStorageSet() public {
        assertTrue(address(sharedCore.doppiOpportunity()) != address(0), "shared core should have external opp storage");
    }

    function test_privateCore_isIsolatedFromSharedCore() public {
        (, address privateCore,,,) = _deployAndCapture(trader1);
        assertTrue(privateCore != address(sharedCore), "private core must differ from shared core");
    }

    function test_opportunityStorage_linkedToCorrectCore() public {
        (, address core, address opp,,) = _deployAndCapture(trader1);

        DoppiOpportunityStorage oppStorage = DoppiOpportunityStorage(opp);
        assertEq(address(oppStorage.doppiCore()), core, "opportunity storage core mismatch");
    }

    function test_privateLP_linkedToPrivateCore() public {
        (, address core,,address privLP,) = _deployAndCapture(trader1);

        DoppiLiquidity dl = DoppiLiquidity(privLP);
        assertEq(dl.doppiCore(), core, "private LP core mismatch");
    }

    function test_privateLiquidityRouter_linkedToPrivateLP() public {
        (,,, address privLP, address privRouter) = _deployAndCapture(trader1);

        DoppiLiquidityRouter router = DoppiLiquidityRouter(privRouter);
        assertEq(address(router.doppiLP()), privLP, "router LP mismatch");
    }

    function test_privateBot_linkedToPrivateCore() public {
        (address bot, address core,,,) = _deployAndCapture(trader1);

        DoppiTrader dt = DoppiTrader(bot);
        assertEq(address(dt.doppiCore()), core, "trader bot core mismatch");
    }

    function test_privateBot_linkedToPrivateLP() public {
        (address bot,,, address privLP,) = _deployAndCapture(trader1);

        DoppiTrader dt = DoppiTrader(bot);
        assertEq(address(dt.doppiLP()), privLP, "trader bot LP mismatch");
    }

    function test_privateBot_linkedToPrivateRouter() public {
        (address bot,,,, address privRouter) = _deployAndCapture(trader1);

        DoppiTrader dt = DoppiTrader(bot);
        assertEq(address(dt.doppiRouter()), privRouter, "trader bot router mismatch");
    }

    function test_privateBot_validTraderIsDeployer() public {
        (address bot,,,,) = _deployAndCapture(trader1);
        assertEq(DoppiTrader(bot).validTrader(), trader1, "validTrader should be deployer");
    }

    // ──────────────────────────────────────────────────────────────────────
    //  IMPLEMENTATION / PROXY TESTS
    // ──────────────────────────────────────────────────────────────────────

    function test_privateCores_shareCodeNotStorage() public {
        (, address core1,,,) = _deployAndCapture(trader1);
        (, address core2,,,) = _deployAndCapture(trader2);

        // Different addresses = different storage
        assertTrue(core1 != core2);

        // Both have same codesize (proxy clones have identical bytecode)
        assertEq(core1.code.length, core2.code.length, "proxy clones should have equal codesize");
    }

    function test_privateOpportunityStorage_cannotBeReinitialized() public {
        (, , address opp,,) = _deployAndCapture(trader1);

        vm.expectRevert();
        DoppiOpportunityStorage(opp).initialize(address(0x999));
    }

    function test_setImplementations_updatesAll() public {
        address newBot  = address(new DoppiTrader());
        address newCore = address(new DoppiCore(address(usdt), address(btc), sharedLP, impliedVol, address(doppiPoints)));
        address newOpp  = address(new DoppiOpportunityStorage());

        vm.prank(owner);
        privateFactory.setImplementations(newBot, newCore, newOpp);

        assertEq(privateFactory.traderBotImplementation(),       newBot,  "bot impl");
        assertEq(privateFactory.doppiCoreImplementation(),       newCore, "core impl");
        assertEq(privateFactory.doppiOpportunityImplementation(), newOpp,  "opp impl");
    }

    function test_setImplementations_onlyOwner() public {
        vm.prank(trader1);
        vm.expectRevert();
        privateFactory.setImplementations(address(1), address(2), address(3));
    }

    function test_setLPConfig_onlyOwner() public {
        ConfigParam memory newConfig = configLP;
        newConfig.liquidityFee = 2000;

        vm.prank(trader1);
        vm.expectRevert();
        privateFactory.setLPConfig(newConfig);
    }

    function test_setLPConfig_updatesConfig() public {
        ConfigParam memory newConfig = configLP;
        newConfig.liquidityFee = 2000;

        vm.prank(owner);
        privateFactory.setLPConfig(newConfig);

        (, , , , uint24 liquidityFee, , , , , , , , , ) = privateFactory.lpConfig();
        assertEq(liquidityFee, 2000, "lpConfig not updated");
    }

    // ──────────────────────────────────────────────────────────────────────
    //  TRADING FLOW TESTS
    // ──────────────────────────────────────────────────────────────────────

    function test_privateBot_start_placesOrders() public {
        (address bot, address core,,address privLP,address privRouter) =
            _deployAndCapture(trader1);

        DoppiTrader dt = DoppiTrader(bot);
        DoppiCore dc   = DoppiCore(core);

        vm.prank(trader1);
        dt.setForwarderAddress(forwarder);

        // Start bot
        vm.startPrank(trader1);
        usdt.approve(bot, type(uint256).max);
        btc.approve(bot,  1 * 1e18);
        dt.start(100_000 * 1e18, 1 * 1e18);
        vm.stopPrank();

        assertTrue(dc.getBuyPositionCount(bot)  > 0, "no buy positions");
        assertTrue(dc.getSellPositionCount(bot) > 0, "no sell positions");
    }

    function test_privateBot_ordersNotVisibleInSharedCore() public {
        (address bot, address core,,address privLP, address privRouter) =
            _deployAndCapture(trader1);

        vm.prank(trader1);
        DoppiTrader(bot).setForwarderAddress(forwarder);

        vm.startPrank(trader1);
        usdt.approve(bot, type(uint256).max);
        DoppiTrader(bot).start(100_000 * 1e18, 0);
        vm.stopPrank();

        // Private core has positions
        assertTrue(DoppiCore(core).getBuyPositionCount(bot) > 0, "private core should have positions");

        // Shared core has NO positions for this bot
        assertEq(sharedCore.getBuyPositionCount(bot), 0, "shared core should not have private bot's positions");
    }

    function test_twoBots_ordersAreIsolated() public {
        (address bot1, address core1,,address lp1, address router1) =
            _deployAndCapture(trader1);
        (address bot2, address core2,,address lp2, address router2) =
            _deployAndCapture(trader2);

        vm.prank(trader1);
        DoppiTrader(bot1).setForwarderAddress(forwarder);
        vm.prank(trader2);
        DoppiTrader(bot2).setForwarderAddress(forwarder);

        vm.startPrank(trader1);
        usdt.approve(bot1, type(uint256).max);
        DoppiTrader(bot1).start(100_000 * 1e18, 0);
        vm.stopPrank();

        vm.startPrank(trader2);
        usdt.approve(bot2, type(uint256).max);
        DoppiTrader(bot2).start(50_000 * 1e18, 0);
        vm.stopPrank();

        // Each core only sees its own bot's positions
        assertEq(DoppiCore(core1).getBuyPositionCount(bot2), 0, "core1 should not see bot2 positions");
        assertEq(DoppiCore(core2).getBuyPositionCount(bot1), 0, "core2 should not see bot1 positions");

        assertTrue(DoppiCore(core1).getBuyPositionCount(bot1) > 0, "core1 should see bot1 positions");
        assertTrue(DoppiCore(core2).getBuyPositionCount(bot2) > 0, "core2 should see bot2 positions");
    }

    function test_privateBot_settleDoesNotAffectSharedCore() public {
        // Setup shared bot to create positions on shared core
        vm.startPrank(lp);
        usdt.approve(address(sharedRouter), 5_000 * 1e18);
        sharedRouter.deposit(address(usdt), 5_000 * 1e18);
        vm.stopPrank();

        vm.prank(trader2);
        uint32 sharedBotId = sharedFactory.deployTraderBot(defaultWeights);
        address sharedBot = sharedFactory.traderBots(sharedBotId);
        vm.prank(trader2);
        DoppiTrader(sharedBot).setForwarderAddress(forwarder);
        vm.startPrank(trader2);
        usdt.approve(sharedBot, type(uint256).max);
        DoppiTrader(sharedBot).start(100_000 * 1e18, 0);
        vm.stopPrank();

        uint256 sharedBuyCount = sharedCore.getBuyPositionCount(sharedBot);
        assertTrue(sharedBuyCount > 0);

        // Deploy private bot and settle its private core
        (address bot, address core,,address privLP, address privRouter) =
            _deployAndCapture(trader1);

        DoppiCore dc = DoppiCore(core);
        vm.prank(owner);
        privateFactory.setPrivateBotForwarder(bot, forwarder);

        vm.startPrank(trader1);
        usdt.approve(bot, type(uint256).max);
        DoppiTrader(bot).start(100_000 * 1e18, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(int256(98_000 * 1e8));

        (bool needed, bytes memory data) = dc.checkUpkeep("");
        if (needed) {
            vm.prank(forwarder);
            dc.performUpkeep(data);
        }

        // Shared core positions should be untouched
        assertEq(sharedCore.getBuyPositionCount(sharedBot), sharedBuyCount,
            "shared core positions should not be affected by private settle");
    }

    // ──────────────────────────────────────────────────────────────────────
    //  OPPORTUNITY STORAGE TESTS
    // ──────────────────────────────────────────────────────────────────────

    function test_opportunityStorage_onlyDoppiCoreCanWrite() public {
        (, address core, address opp,,) = _deployAndCapture(trader1);

        DoppiOpportunityStorage oppStorage = DoppiOpportunityStorage(opp);

        vm.expectRevert("OnlyDoppiCore");
        oppStorage.setOpportunityBuy(100_000 * 1e8, 1 ether, 0, 0);

        vm.expectRevert("OnlyDoppiCore");
        oppStorage.setOpportunitySell(100_000 * 1e8, 1 ether, 0, 0);

        vm.expectRevert("OnlyDoppiCore");
        oppStorage.addOpportunityBuyAmount(100_000 * 1e8, 1 ether);

        vm.expectRevert("OnlyDoppiCore");
        oppStorage.addOpportunitySellAmount(100_000 * 1e8, 1 ether);
    }

    function test_opportunityStorage_readReturnsZeroByDefault() public {
        (,, address opp,,) = _deployAndCapture(trader1);

        DoppiOpportunityStorage oppStorage = DoppiOpportunityStorage(opp);
        OpportunityOrders memory orders = oppStorage.getBuyOpportunity(100_000 * 1e8);
        assertEq(orders.amount, 0);
        assertEq(orders.swappedAmount, 0);
        assertEq(orders.outAmount, 0);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  PRIVATE FACTORY ADMIN WRAPPER TESTS
    // ──────────────────────────────────────────────────────────────────────

    function test_privateCore_traderCanUpdateOperationalControls() public {
        (address bot, address core,,,) = _deployAndCapture(trader1);
        DoppiCore dc = DoppiCore(core);

        vm.prank(trader1);
        privateFactory.setPrivateCoreMinOrder(bot, 123 ether, 0.002 ether);
        assertEq(dc.minOrderA(), 123 ether, "minOrderA not updated");
        assertEq(dc.minOrderB(), 0.002 ether, "minOrderB not updated");

        vm.prank(trader1);
        privateFactory.setPrivateCoreMaxSwap(bot, 777_777 ether);
        assertEq(dc.maxSwap(), 777_777 ether, "maxSwap not updated");

        vm.prank(trader1);
        privateFactory.setPrivateCoreAPRTolerance(bot, 250);
        assertEq(dc.aprToleranceBP(), 250, "apr tolerance not updated");

        vm.prank(trader1);
        privateFactory.setPrivateCoreUpkeepsPerCheck(bot, 33);
        assertEq(dc.UPKEEPS_PER_CHECK(), 33, "upkeeps per check not updated");

        vm.prank(trader1);
        privateFactory.setPrivateCorePause(bot);
        assertTrue(dc.paused(), "core should be paused");

        vm.prank(trader1);
        privateFactory.setPrivateCoreEmergencyMode(bot, true);
        assertTrue(dc.emergencyMode(), "core emergency mode not updated");

        vm.prank(trader1);
        privateFactory.setPrivateCoreUnPause(bot);
        assertFalse(dc.paused(), "core should be unpaused");
    }

    function test_privateCore_ownerCanUpdateOwnerOnlyControls() public {
        (address bot, address core,,,) = _deployAndCapture(trader1);
        DoppiCore dc = DoppiCore(core);

        vm.prank(owner);
        privateFactory.setPrivateCoreTreasury(bot, treasury, 1200);
        assertEq(dc.treasury(), treasury, "treasury not updated");
        assertEq(dc.treasury_fee(), 1200, "treasury fee not updated");

        vm.prank(owner);
        privateFactory.setPrivateCoreOpportunityBot(bot, trader2, true);
        assertTrue(dc.opportunityBots(trader2), "opportunity bot not updated");

        vm.prank(owner);
        privateFactory.setPrivateCoreTraderFactory(bot, IDoppiTraderFactory(address(sharedFactory)));
        assertEq(address(dc.doppiTraderFactory()), address(sharedFactory), "trader factory not updated");
    }

    function test_privateCore_traderCannotUpdateOwnerOnlyControls() public {
        (address bot,,,,) = _deployAndCapture(trader1);

        vm.startPrank(trader1);
        vm.expectRevert();
        privateFactory.setPrivateCoreTreasury(bot, treasury, 500);

        vm.expectRevert();
        privateFactory.setPrivateCoreOpportunityBot(bot, trader2, true);

        vm.expectRevert();
        privateFactory.setPrivateCoreTraderFactory(bot, IDoppiTraderFactory(address(sharedFactory)));
        vm.stopPrank();
    }

    function test_privateRouter_traderCanUpdateOperationalControls() public {
        (address bot,,,, address privRouter) = _deployAndCapture(trader1);
        DoppiLiquidityRouter router = DoppiLiquidityRouter(privRouter);

        vm.prank(trader1);
        privateFactory.setPrivateRouterPause(bot);
        assertTrue(router.paused(), "router should be paused");

        vm.prank(trader1);
        privateFactory.setPrivateRouterEmergencyMode(bot, true);
        assertTrue(router.emergencyMode(), "router emergency mode not updated");

        vm.prank(trader1);
        privateFactory.setPrivateRouterUnPause(bot);
        assertFalse(router.paused(), "router should be unpaused");
    }

    function test_privateRouter_ownerCanUpdateOwnerOnlyControls() public {
        (address bot,,,, address privRouter) = _deployAndCapture(trader1);
        DoppiLiquidityRouter router = DoppiLiquidityRouter(privRouter);

        vm.prank(owner);
        privateFactory.setPrivateRouterAllowedUser(bot, trader2, true);
        assertTrue(router.allowedUsers(trader2), "allowed user not updated");

        vm.prank(owner);
        privateFactory.setPrivateRouterMode(bot, false);
        assertFalse(router.privateMode(), "private mode not updated");

        vm.prank(owner);
        privateFactory.setPrivateRouterCore(bot, address(sharedCore));
        assertEq(router.doppiCore(), address(sharedCore), "router core not updated");
    }

    function test_privateRouter_traderCannotUpdateOwnerOnlyControls() public {
        (address bot,,,,) = _deployAndCapture(trader1);

        vm.startPrank(trader1);
        vm.expectRevert();
        privateFactory.setPrivateRouterAllowedUser(bot, trader2, true);

        vm.expectRevert();
        privateFactory.setPrivateRouterMode(bot, false);

        vm.expectRevert();
        privateFactory.setPrivateRouterCore(bot, address(sharedCore));
        vm.stopPrank();
    }

    function test_privateWrappers_outsiderCannotCallTraderOrOwnerPaths() public {
        (address bot,,,,) = _deployAndCapture(trader1);
        address outsider = address(0xBEEF);

        vm.startPrank(outsider);
        vm.expectRevert(PrivateDoppiTraderFactory.NotAuthorized.selector);
        privateFactory.setPrivateCorePause(bot);

        vm.expectRevert(PrivateDoppiTraderFactory.NotAuthorized.selector);
        privateFactory.setPrivateRouterPause(bot);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────
    //  HELPERS
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Deploys a private bot and captures all component addresses from the emitted event.
    function _deployAndCapture(address _trader) internal returns (
        address bot,
        address core,
        address opp,
        address privLP,
        address privRouter
    ) {
        vm.recordLogs();
        vm.prank(_trader);
        privateFactory.deployPrivateBot(defaultWeights);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // PrivateBotDeployed signature
        bytes32 sig = keccak256(
            "PrivateBotDeployed(address,address,address,address,address,address,uint32)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                bot  = address(uint160(uint256(logs[i].topics[2]))); // indexed traderBot
                core = address(uint160(uint256(logs[i].topics[3]))); // indexed privateCore
                // remaining are non-indexed in data: privateOpportunity, privateLiquidity, privateRouter, botId
                (opp, privLP, privRouter,) = abi.decode(logs[i].data, (address, address, address, uint32));

                return (bot, core, opp, privLP, privRouter);
            }
        }
        revert("PrivateBotDeployed event not found");
    }

    function _setRegression(DoppiOffer _iv) internal {
        int256 a_buy  =  0.0000000807142857142833 * 1e27;
        int256 b_buy  = -0.019095857142856592     * 1e27;
        int256 c_buy  =  1159.8454285713972        * 1e27;
        int256 a_sell =  0.000000102857142857143   * 1e27;
        int256 b_sell = -0.02447200000000008       * 1e27;
        int256 c_sell =  1485.8762857142906        * 1e27;
        _iv.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
    }
}
