// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {Swapper} from "../src/test/Swapper.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {DoppiOffer} from "../src/mainnet/DoppiOffer.sol";
import {DoppiPoints} from "../src/mainnet/DoppiPoints.sol";
import {DoppiCore} from "../src/mainnet/DoppiCore.sol";
import {DoppiTraderFactory} from "../src/mainnet/DoppiTraderFactory.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiFeePool} from "../src/mainnet/DoppiFeePool.sol";
import {ConfigParam} from "../src/mainnet/DoppiLiquidityTypes.sol";
import {PrivateDoppiGridTraderFactory} from "../src/mainnet/private/PrivateDoppiGridTraderFactory.sol";
import {DoppiGridTrader} from "../src/mainnet/private/DoppiGridTrader.sol";
import {DoppiOpportunity} from "../src/mainnet/DoppiOpportunity.sol";
import {IPrivateAutomationHub} from "../src/Interface/IPrivateAutomationHub.sol";
import {
    RegisterPrivateBotParams,
    PrivateBotJobIds,
    PrivateAutomationModule,
    PrivateJobConfig,
    PrivateJobView
} from "../src/mainnet/private/PrivateAutomationHubTypes.sol";
import {TestParamLib} from "../src/Library/TestParamLib.sol";

contract MockPrivateAutomationHubForGrid is IPrivateAutomationHub {
    uint256 public sharedRegisterCount;
    address public lastTrader;
    address public lastBot;
    uint32 public lastBotId;
    bool public shouldRevert;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function registerPrivateBotJobs(RegisterPrivateBotParams calldata)
        external
        pure
        returns (PrivateBotJobIds memory jobIds)
    {
        return jobIds;
    }

    function registerSharedBotJob(address trader, address bot, uint32 botId) external returns (uint256 jobId) {
        if (shouldRevert) revert("mock hub revert");
        sharedRegisterCount += 1;
        lastTrader = trader;
        lastBot = bot;
        lastBotId = botId;
        return sharedRegisterCount;
    }

    function disablePrivateBotJobs(address) external pure {}

    function getJobId(address, PrivateAutomationModule) external pure returns (uint256 jobId) {
        return 0;
    }

    function getJobIdsByBot(address) external pure returns (PrivateBotJobIds memory jobIds) {
        return jobIds;
    }

    function getJob(uint256) external pure returns (PrivateJobView memory job) {
        return job;
    }

    function setJobConfig(uint256, PrivateJobConfig calldata) external pure {}

    function setJobActive(uint256, bool) external pure {}

    function checkUpkeep(bytes calldata) external pure returns (bool upkeepNeeded, bytes memory performData) {
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata) external pure {}
}

contract PrivateDoppiGridTraderTest is Test {
    MockToken usdt;
    MockToken btc;
    MockOracle oracle;
    Swapper swapper;
    BlackScholes blackScholes;
    DoppiOffer impliedVol;
    DoppiPoints doppiPoints;

    DoppiLiquidity sharedLP;
    DoppiFeePool feePoolContract;
    DoppiCore sharedCore;
    DoppiTraderFactory sharedFactory;
    DoppiOpportunity sharedOpportunity;
    ConfigParam configLP;

    DoppiCore coreImplementation;
    DoppiGridTrader traderImplementation;
    DoppiOpportunity opportunityImplementation;
    PrivateDoppiGridTraderFactory privateFactory;
    MockPrivateAutomationHubForGrid mockHub;

    address owner = address(0x1);
    address trader = address(0x2);
    address forwarder = address(0x3);
    address feePoolReceiver = address(0x4);

    uint24[] weights;

    struct EpochZoneInfo {
        uint8 zone;
        uint256 buyStrike;
        uint256 sellStrike;
        uint256 originalBuyAmount;
        uint256 originalSellAmount;
        uint256 remainingBuyOpportunity;
        uint256 remainingSellOpportunity;
        uint256 pendingBuyUnwind;
        uint256 pendingSellUnwind;
    }

    function setUp() public {
        vm.startPrank(owner);
        vm.warp(1735689600);

        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        oracle = new MockOracle(int256(100_000 * 1e8), 8);

        swapper = new Swapper(usdt, btc);
        swapper.setOracle(oracle);

        blackScholes = new BlackScholes();
        impliedVol = new DoppiOffer(blackScholes, address(oracle), 500);
        _setRegression(impliedVol);
        doppiPoints = new DoppiPoints();

        configLP = TestParamLib.get_configLP();
        configLP.chainLinkFeed = address(oracle);
        configLP.router = address(swapper);
        configLP.v3Pool = address(swapper);

        sharedLP = new DoppiLiquidity("Shared LP", "DALP", address(IERC20(usdt)), address(IERC20(btc)));
        sharedLP.setConfig(configLP);
        sharedLP.approveRouter();
        feePoolContract = new DoppiFeePool(address(sharedLP), feePoolReceiver, 3000);

        sharedCore = new DoppiCore(address(usdt), address(btc), sharedLP, impliedVol, address(doppiPoints));
        doppiPoints.setDoppiCore(address(sharedCore), true);

        sharedFactory = new DoppiTraderFactory(
            IERC20(usdt),
            IERC20(btc),
            address(sharedCore),
            address(sharedLP),
            address(0),
            address(impliedVol),
            address(doppiPoints)
        );
        sharedLP.setDoppiTraderFactory(address(sharedFactory));
        sharedCore.setDoppiTraderFactory(sharedFactory);

        sharedOpportunity = new DoppiOpportunity(address(sharedCore), address(sharedLP));
        sharedCore.setOpportunityBot(address(sharedOpportunity), true);

        coreImplementation = new DoppiCore(address(usdt), address(btc), sharedLP, impliedVol, address(doppiPoints));
        traderImplementation = new DoppiGridTrader();
        opportunityImplementation = new DoppiOpportunity(address(0), address(0));

        privateFactory = new PrivateDoppiGridTraderFactory(
            IERC20(usdt),
            IERC20(btc),
            address(sharedLP),
            address(impliedVol),
            address(traderImplementation)
        );
        privateFactory.setDefaultPrivateTreasury(feePoolReceiver, 2000);

        mockHub = new MockPrivateAutomationHubForGrid();
        sharedLP.setTraderFactoryAllowed(address(privateFactory), true);

        for (uint256 i = 0; i < 5; ) {
            weights.push(2000);
            unchecked {
                ++i;
            }
        }

        usdt.mint(trader, 10_000_000 ether);
        btc.mint(trader, 100 ether);
        vm.stopPrank();
    }

    function test_startPlacesExpectedBuyAndSellLadders() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);
        uint256 p = 1e8;

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        usdt.approve(address(bot), type(uint256).max);
        btc.approve(address(bot), type(uint256).max);
        oracle.setPrice(int256(99_600 * 1e8));
        bot.start(100_000 ether, 1 ether);
        vm.stopPrank();

        // Buy: 99,500 / 99,000 / 98,500 / 98,000 / 97,500 with 4,000 USDT each.
        assertEq(bot.getOpportunityInfo(true, 99_500 * p), 4_000 ether);
        assertEq(bot.getOpportunityInfo(true, 99_000 * p), 4_000 ether);
        assertEq(bot.getOpportunityInfo(true, 98_500 * p), 4_000 ether);
        assertEq(bot.getOpportunityInfo(true, 98_000 * p), 4_000 ether);
        assertEq(bot.getOpportunityInfo(true, 97_500 * p), 4_000 ether);

        // Sell: 100,000 / 100,500 / 101,000 / 101,500 / 102,000 with 0.04 BTC each.
        assertEq(bot.getOpportunityInfo(false, 100_000 * p), 0.04 ether);
        assertEq(bot.getOpportunityInfo(false, 100_500 * p), 0.04 ether);
        assertEq(bot.getOpportunityInfo(false, 101_000 * p), 0.04 ether);
        assertEq(bot.getOpportunityInfo(false, 101_500 * p), 0.04 ether);
        assertEq(bot.getOpportunityInfo(false, 102_000 * p), 0.04 ether);
    }

    function test_performUpkeepMovesOpportunityToUnwind() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);
        uint256 p = 1e8;

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0); // force zero effective buffer for deterministic trigger tests
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        // Trigger buy zone0 strike 100,000.
        vm.prank(owner);
        oracle.setPrice(int256(99_900 * 1e8));

        vm.prank(forwarder);
        bot.performUpkeep("");

        // Opportunity should move to unwind bucket near rounded+gap.
        assertEq(bot.getOpportunityInfo(true, 100_000 * p), 0);
        assertGt(bot.getUnwindInfo(true, 100_000 * p), 0);
    }

    function test_unwindPaysFeeInProfitToken() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);

        vm.startPrank(owner);
        feePoolContract.setAuthorizedCore(address(bot), true);
        privateFactory.setFeeConfig(address(bot), address(feePoolContract), 1000);
        vm.stopPrank();

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        // Buy trigger at lower price.
        vm.prank(owner);
        oracle.setPrice(int256(99_900 * 1e8));
        vm.prank(forwarder);
        bot.performUpkeep("");

        uint256 receiverBefore = usdt.balanceOf(feePoolReceiver);
        uint256 sharedLpBefore = usdt.balanceOf(address(sharedLP));

        // Unwind trigger at higher price (profit realized in assetA/usdt).
        vm.prank(owner);
        oracle.setPrice(int256(130_000 * 1e8));
        vm.prank(forwarder);
        bot.performUpkeep("");

        uint256 receiverAfter = usdt.balanceOf(feePoolReceiver);
        uint256 sharedLpAfter = usdt.balanceOf(address(sharedLP));
        assertGt(receiverAfter, receiverBefore);
        assertGt(sharedLpAfter, sharedLpBefore);
    }

    function test_epochResetAfter24HoursReanchorsOrders() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);
        uint256 p = 1e8;

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(0, 2000);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        (, uint64 expiryBefore, uint256 anchorBefore) = bot.getEpochInfo();
        assertEq(anchorBefore, 100_000 * p);

        vm.warp(uint256(expiryBefore) + 1);
        vm.prank(owner);
        oracle.setPrice(int256(98_200 * 1e8));

        vm.prank(forwarder);
        bot.performUpkeep("");

        (, uint64 expiryAfter, uint256 anchorAfter) = bot.getEpochInfo();
        assertGt(expiryAfter, expiryBefore);
        assertEq(anchorAfter, 98_000 * p);
        assertEq(bot.getOpportunityInfo(true, 98_000 * p), 4_000 ether);
    }

    function test_getEpochZoneInfoReturnsOriginalAndUnwindByZone() public {
        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);
        uint256 p = 1e8;

        vm.startPrank(trader);
        bot.setForwarderAddress(forwarder);
        bot.setOpportunityBufferParams(10000, 0);
        usdt.approve(address(bot), type(uint256).max);
        bot.start(100_000 ether, 0);
        vm.stopPrank();

        (bool okBefore, bytes memory dataBefore) = address(bot).call(abi.encodeWithSignature("getEpochZoneInfo()"));
        assertTrue(okBefore);
        EpochZoneInfo[] memory beforeExec = abi.decode(dataBefore, (EpochZoneInfo[]));

        assertEq(beforeExec.length, 5);
        assertEq(beforeExec[0].zone, 0);
        assertEq(beforeExec[0].buyStrike, 100_000 * p);
        assertEq(beforeExec[0].originalBuyAmount, 4_000 ether);
        assertEq(beforeExec[0].pendingBuyUnwind, 0);

        vm.prank(owner);
        oracle.setPrice(int256(99_900 * 1e8));
        vm.prank(forwarder);
        bot.performUpkeep("");

        (bool okAfter, bytes memory dataAfter) = address(bot).call(abi.encodeWithSignature("getEpochZoneInfo()"));
        assertTrue(okAfter);
        EpochZoneInfo[] memory afterExec = abi.decode(dataAfter, (EpochZoneInfo[]));

        assertEq(afterExec[0].remainingBuyOpportunity, 0);
        assertGt(afterExec[0].pendingBuyUnwind, 0);
    }

    function test_deployPrivateBot_registersHubAndSetsForwarder() public {
        vm.prank(owner);
        privateFactory.setPrivateAutomationHub(address(mockHub));

        (address botAddr,,,,) = _deployAndCapture(trader);
        DoppiGridTrader bot = DoppiGridTrader(botAddr);

        assertEq(mockHub.sharedRegisterCount(), 1);
        assertEq(mockHub.lastTrader(), trader);
        assertEq(mockHub.lastBot(), botAddr);
        assertEq(bot.s_forwarderAddress(), address(mockHub));
    }

    function _deployAndCapture(address _trader) internal returns (
        address bot,
        address core,
        address opp,
        address privLP,
        address privRouter
    ) {
        vm.recordLogs();
        vm.prank(_trader);
        privateFactory.deployPrivateBot(weights);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("GridBotDeployed(address,address,uint32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                bot = address(uint160(uint256(logs[i].topics[2])));
                core = address(0);
                opp = address(0);
                privLP = address(sharedLP);
                privRouter = address(0);
                return (bot, core, opp, privLP, privRouter);
            }
        }
        revert("GridBotDeployed event not found");
    }

    function _setRegression(DoppiOffer _iv) internal {
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;
        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;
        _iv.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
    }
}
