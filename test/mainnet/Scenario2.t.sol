// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/Interface/IAutomationRegistrar.sol";
import "../../src/Interface/IAutomationRegistryConsumer.sol";
import {IBlackScholes} from "../../src/Interface/IBlackScholes.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
import {DoppiTrader} from "../../src/mainnet/DoppiTrader.sol";
import {DoppiCore} from "../../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../../src/mainnet/DoppiLiquidityRouter.sol";
import {BlackScholes} from "../../src/mainnet/BlackScholes.sol";
import {DoppiOffer} from "../../src/mainnet/DoppiOffer.sol";
import {DoppiPoints} from "../../src/mainnet/DoppiPoints.sol";
import {DoppiClaim} from "../../src/mainnet/DoppiClaim.sol";
import {DOPPI} from "../../src/test/Doppi.sol";
import {DoppiOpportunity} from "../../src/mainnet/DoppiOpportunity.sol";
import {DoppiUpkeepManager} from "../../src/mainnet/DoppiUpkeepManager.sol";
import {MockRegistryConsumer} from "../../src/test/MockRegistryConsumer.sol";
import {DoppiReferral} from "../../src/mainnet/DoppiReferral.sol";
import "../../src/mainnet/DoppiCoreTypes.sol";
import {MockOracle} from "../../src/test/MockOracle.sol";
import {TestParamLib} from "../../src/Library/TestParamLib.sol";
import "../../src/mainnet/DoppiLiquidityTypes.sol";


contract Scenario2Test is Test {
    DoppiTraderFactory doppiFactory;
    // DoppiTrader doppiTrader;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    BlackScholes blackScholes;
    DoppiOffer impliedVol;
    IERC20 usdt;
    IERC20 btc;
    IERC20 link;
    MockOracle oracle;
    // MockDoppiUpKeepManager mockDoppiUpKeepManager;
    DoppiOpportunity doppiOpportunity;
    // Swapper public swapper;
    DoppiPoints doppiPoints;
    DoppiUpkeepManager doppiUpkeepManager;
    DoppiReferral doppiReferral;
    DOPPI doppiToken;
    DoppiClaim doppiClaim;
    ConfigParam configLP;
    address mockRegistryConsumerAddr;
    
    // Mainnet addresses for forking
    address constant LINK = address(0x404460C6A5EdE2D891e8297795264fDe62ADBB75);
    address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
    address constant BTC = address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    address constant BNBLINK = address(0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD);
    address constant CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
    address constant CHAINLINK_LINK_USD = address(0xca236E327F629f9Fc2c30A4E95775EbF0B89fac8);
    address constant LINK_PEGGED_SWAP = address(0x1FCc3B22955e76Ca48bF025f1A6993685975Bb9e);
    address constant PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    address constant PCSWAP_V3_QUOTER = address(0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997);
    address constant PCSWAP_V3Pool = address(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);
    address constant CHAINLINK_RegistryConsumer = address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C);
    address constant CHAINLINK_Registrar = address(0xf671F60bCC964B309D22424886FF202807381B32);
    address constant treasury = address(0xaD8234bC07168d9f7E49c3780e4b5fefa6620f8A);
    address constant admin = address(0xaD8234bC07168d9f7E49c3780e4b5fefa6620f8A);
    address constant forwarder = address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
    
    address owner = makeAddr("owner");
    // address treasury = makeAddr("treasury");
    // address admin = makeAddr("admin");
    // address forwarder = makeAddr("forwarder");
    address trader = makeAddr("trader");
    address trader2 = makeAddr("trader2");
    address liquidityProvider = makeAddr("liquidityProvider");
    
    uint24[] defaultWeights = [2000, 2000, 2000, 2000, 2000]; // Equal weights

    function setUp() public {
        
        // Fork Mainnet at a specific block
        uint256 mainnetFork = vm.createFork("mainnet", 69703761); // Do not change the block number for the unit test
        vm.selectFork(mainnetFork);
        
        // Start prank as owner
        vm.startPrank(owner);
        
        usdt = IERC20(USDT);
        btc = IERC20(BTC);
        link = IERC20(LINK);
        oracle = new MockOracle(int256(100_000 * 1e8), 8);
        blackScholes = _deployBlackScholes();
        impliedVol = _deployDoppiOffer(address(blackScholes));
        doppiPoints = _deployDoppiPoints();
        doppiLP = _deployDoppiLiquidity();
        doppiCore = _deployDoppiCore(doppiLP, impliedVol, doppiPoints);
        doppiOpportunity = _deployDoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiReferral = _deployDoppiReferral(address(doppiPoints));
    
        doppiRouter = new DoppiLiquidityRouter(IERC20(USDT), IERC20(BTC), doppiLP);
        doppiRouter.setDoppiCore(address(doppiCore));
        doppiLP.setDoppiLiquidityRouter(address(doppiRouter));
        doppiFactory = new DoppiTraderFactory(IERC20(USDT), IERC20(BTC), address(doppiCore), address(doppiLP), address(doppiRouter), address(impliedVol), address(doppiPoints));
        doppiUpkeepManager = _deployDoppiUpkeepManager(address(doppiFactory));
        
        doppiToken = new DOPPI("Doppi Token", "DOPPI");
        doppiClaim = _deployDoppiClaim(doppiPoints, doppiReferral, doppiToken);
        
        _setDoppiLiquidityProperties(doppiLP, address(doppiCore), doppiRouter, address(doppiFactory));
        _setDoppiCoreProperties(doppiCore, doppiFactory, address(doppiOpportunity));

        doppiPoints.setCoreTraderFactory(address(doppiCore), address(doppiFactory));
        doppiOpportunity.setForwarderAddress(forwarder);
        
        _setupIV(impliedVol);        
        vm.stopPrank();
    }

    function test_Scenario_LP_WithdrawMaxAvailability() public {
        
        vm.startPrank(trader);
        deal(BTC, address(trader), 10 ether);
        deal(USDT, address(trader), 1_000_000 ether);
        deal(LINK, address(0x719474EC3C3587F47C81424c9c73F785aec3f1A0), 10_000 ether); //mockRegistryConsumer

        usdt.approve(address(doppiRouter), 200_000 ether);
        // btc.approve(address(doppiRouter), 1 ether);
        
        uint256 sharesA = doppiRouter.deposit(address(usdt), 100000 ether);
        // uint256 sharesB = doppiRouter.deposit(address(btc), 1 ether);

        usdt.approve(address(doppiCore), 100000 ether);
        
        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 0);
        doppiCore.deposit_buy(DepositParams({
            amount: 100000 ether,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            expiry: buyOffer.expiry
        }));
        
        vm.stopPrank();

        // Verify active
        assertTrue(doppiCore.getBuyPositionCount(address(trader)) > 0);

        (uint256 interestLiabilitiesA, uint256 interestLiabilitiesB) = doppiCore.getInterestLiabilities();
        assertGt(interestLiabilitiesA, 0);
        assertEq(interestLiabilitiesB, 0);

        uint256 avail = doppiRouter.getWithdrawableAmount(trader);
        assertLt(avail, 100000 ether);

        
        vm.startPrank(trader);
        doppiLP.approve(address(doppiRouter), sharesA);
        vm.expectRevert("exceeds available capacity");
        doppiRouter.redeem(sharesA);
        
        (uint256 assetsA, ) = doppiRouter.redeem(avail);
        assertGt(assetsA, 0);

        vm.stopPrank();
        
    }

    function test_Scenario_DoppiCore_DepositMax() public {
        
        uint256 depositAmount = 5000000 ether;
        vm.startPrank(trader);
        deal(BTC, address(trader), 10 ether);
        deal(USDT, address(trader), 10_000_000 ether);
        deal(LINK, mockRegistryConsumerAddr, 10_000 ether); //mockRegistryConsumer

        usdt.approve(address(doppiRouter), depositAmount);
        btc.approve(address(doppiRouter), 1 ether);
        
        uint256 sharesA = doppiRouter.deposit(address(usdt), 1000 ether);
        uint256 sharesB = doppiRouter.deposit(address(btc), 1 ether);

        uint256 maxDeposit = doppiCore.acceptedDeposit(true);
        
        usdt.approve(address(doppiCore), 500000 ether);
        btc.approve(address(doppiCore), 1 ether);
        
        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 1);
        doppiCore.deposit_buy(DepositParams({
            amount: maxDeposit / 2,
            strikeZone: 1,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            expiry: buyOffer.expiry
        }));

        vm.expectRevert("ExceedsPoolCap()");
        doppiCore.deposit_buy(DepositParams({
            amount: depositAmount,
            strikeZone: 1,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            expiry: buyOffer.expiry
        }));
        
        vm.stopPrank();

        // Verify active
        assertTrue(doppiCore.getBuyPositionCount(address(trader)) > 0);

        (uint256 interestLiabilitiesA, uint256 interestLiabilitiesB) = doppiCore.getInterestLiabilities();
        assertGt(interestLiabilitiesA, 0);
        assertEq(interestLiabilitiesB, 0);

        uint256 avail = doppiRouter.getWithdrawableAmount(trader);
        assertEq(avail, 91084405834040272619260);
        
        maxDeposit = doppiCore.acceptedDeposit(false);
        
        _depositBTC(maxDeposit);
        vm.startPrank(trader);
        avail = doppiRouter.getWithdrawableAmount(trader);
        uint256 bal = doppiLP.balanceOf(trader);
        doppiLP.approve(address(doppiRouter), bal);
        vm.expectRevert("exceeds available capacity");
        doppiRouter.redeem(sharesA + sharesB);
        
        (uint256 assetsA, uint256 assetsB) = doppiRouter.redeem(avail);
        assertGt(assetsA, 0);
        assertGt(assetsB, 0);

        vm.stopPrank();
        
    }

    function test_Scenario2_TraderBotLifecycle() public {
        
        
        deal(BTC, address(trader), 1 ether);
        deal(USDT, address(trader), 100_000 ether);
        deal(LINK, mockRegistryConsumerAddr, 10_000 ether); //mockRegistryConsumer
        
        // Deploy bot
        vm.startPrank(trader);
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        vm.stopPrank();

        // Fund and start
        vm.startPrank(trader);
        usdt.approve(address(traderBot), 10000 ether);
        btc.approve(address(traderBot), 0.2 ether);
        traderBot.start(10000 ether, 0.1 ether);
        vm.stopPrank();

        // Verify active and trading
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0);
        assertTrue(traderBot.totalUnits() > 0);

        // settle core
        vm.warp(block.timestamp + 1 days + 1);
         _doppiCoreCheckUpkeep_performUpkeep();

        // stop and withdraw fund 
        vm.startPrank(trader);
        traderBot.stop();
        vm.stopPrank();
        
        vm.startPrank(owner);
        _setupIV(impliedVol);
        vm.stopPrank();

        // Verify stopped - no units
        assertEq(traderBot.totalUnits(), 0);

        // Restart
        vm.startPrank(trader);
        traderBot.setForwarderAddress(forwarder);
        usdt.approve(address(traderBot), 10000 ether);
        btc.approve(address(traderBot), 0.2 ether);
        traderBot.start(10000 ether, 0.1 ether);
        vm.stopPrank();

        // Verify restarted successfully
        assertTrue(traderBot.totalUnits() > 0);
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0);

    }

    function test_Scenario_TraderBotLifecycle_Stop_Restart() public {
        
        
        deal(BTC, address(trader), 1 ether);
        deal(USDT, address(trader), 100_000 ether);
        deal(LINK, mockRegistryConsumerAddr, 10_000 ether); //mockRegistryConsumer
        
        // Deploy bot
        vm.startPrank(trader);
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        vm.stopPrank();

        // Fund and start
        vm.startPrank(trader);
        usdt.approve(address(traderBot), 10000 ether);
        btc.approve(address(traderBot), 0.2 ether);
        traderBot.start(10000 ether, 0.1 ether);
        vm.stopPrank();

        // Verify active
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0);
        uint256 initialUnits = traderBot.totalUnits();
        assertTrue(initialUnits > 0);
        
        // settle core
        vm.warp(block.timestamp + 1 days + 1);
         _doppiCoreCheckUpkeep_performUpkeep();

        // stop and withdraw fund 
        vm.startPrank(trader);
        traderBot.stop();
        vm.stopPrank();
        
        vm.startPrank(owner);
        _setupIV(impliedVol);
        vm.stopPrank();

        // Verify stopped
        assertEq(traderBot.totalUnits(), 0, "Units should be zero after stopping");

        // Restart
        vm.startPrank(trader);
        traderBot.setForwarderAddress(forwarder);
        usdt.approve(address(traderBot), 10000 ether);
        btc.approve(address(traderBot), 0.2 ether);
        traderBot.start(10000 ether, 0.1 ether);
        vm.stopPrank();

        // Verify restarted with new units
        uint256 newUnits = traderBot.totalUnits();
        assertTrue(newUnits > 0, "Units should be allocated after restarting");
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0, "Bot should have positions after restart");

    }

    function test_Scenario_TraderBot_MinOrder_Handling() public {
        
        vm.startPrank(trader);
        deal(BTC, address(trader), 1 ether);
        deal(USDT, address(trader), 100_000 ether);
        deal(LINK, mockRegistryConsumerAddr, 10_000 ether); //mockRegistryConsumer

        // Deploy bot
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        // Fund and start
        usdt.approve(address(traderBot), 1000 ether);
        btc.approve(address(traderBot), 0.01 ether);
        traderBot.start(1000 ether, 0.01 ether);

        // Verify active
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0);
        vm.stopPrank();

        // Price Down 2%
        uint256 currentPrice = doppiLP.getPrice();
        int256 newPrice = int256(currentPrice * 9900 / 10000);
        _manipulateRealChainlink(newPrice, address(oracle));

        // settle core
        vm.warp(block.timestamp + 1 days + 1);
        _doppiCoreCheckUpkeep_performUpkeep();

        vm.startPrank(owner);
        _setupIV(impliedVol);
        vm.stopPrank();

        uint256 usdtbal = usdt.balanceOf(address(traderBot));
        uint256 btcbal = btc.balanceOf(address(traderBot));
        
        // console.log(usdtbal, btcbal, "usdtbal, btcbal");

        assertGt(btcbal, 0.005 ether);
        assertLt(usdtbal, 500 ether);
        // place second round
        vm.startPrank(trader);
        traderBot.placeOrders();
        vm.stopPrank();
        // console.log(doppiCore.getBuyPositionCount(address(traderBot)), doppiCore.getSellPositionCount(address(traderBot)));

        // With current order budgeting, both sides can be placed when both balances still satisfy min order.
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0);
        assertTrue(doppiCore.getSellPositionCount(address(traderBot)) > 0);
    }

    function test_Scenario_TraderBot_MinOrder_PoolLimit_Handling() public {
        
        vm.startPrank(trader);
        deal(BTC, address(trader), 1 ether);
        deal(USDT, address(trader), 100_000 ether);
        deal(USDT, address(trader2), 100_000 ether);
        deal(LINK, mockRegistryConsumerAddr, 10_000 ether); //mockRegistryConsumer

        // Deploy bot
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        // Fund and start
        usdt.approve(address(traderBot), 1000 ether);
        btc.approve(address(traderBot), 0.01 ether);
        traderBot.start(1000 ether, 0.01 ether);

        // Verify active
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0);
        vm.stopPrank();

        // Price Down 2%
        uint256 currentPrice = doppiLP.getPrice();
        int256 newPrice = int256(currentPrice * 9900 / 10000);
        _manipulateRealChainlink(newPrice, address(oracle));

        // settle core
        vm.warp(block.timestamp + 1 days + 1);
        _doppiCoreCheckUpkeep_performUpkeep();

        vm.startPrank(owner);
        _setupIV(impliedVol);
        vm.stopPrank();

        uint256 usdtbal = usdt.balanceOf(address(traderBot));
        uint256 btcbal = btc.balanceOf(address(traderBot));
        
        // console.log(usdtbal, btcbal, "usdtbal, btcbal");

        assertGt(btcbal, 0.005 ether);
        assertLt(usdtbal, 500 ether);


        uint256 maxBuy = doppiCore.acceptedDeposit(true);
        uint256 maxSell = doppiCore.acceptedDeposit(false);
        assertEq(maxBuy, 1895574564912403796940);
        assertEq(maxSell, 20922447767849268);
        
        // trader 2 deposit and occupied pool liquidity before bot
        _depositUSDT(1600 ether, trader2);
        
        console.log(doppiLP.getPrice(), "PRICE");
        maxBuy = doppiCore.acceptedDeposit(true);
        maxSell = doppiCore.acceptedDeposit(false);
        (uint256 liabilityA, uint256 liabilityB) = doppiCore.getInterestLiabilities();
        console.log(liabilityA, liabilityB, "liabilityA, liabilityB");
        console.log(maxBuy, maxSell, "maxBuy, maxSell");
        
        liabilityB = liabilityA * 1e8 / doppiLP.getPrice();
        assertEq(maxBuy + liabilityA, 295574564912403796940); // confirm max sell already includes all liability
        assertEq(maxSell + liabilityB, 3262411044310628); // confirm max buy already includes all liability
        

        // place second round
        vm.startPrank(trader);
        traderBot.placeOrders();
        vm.stopPrank();
        
        assertTrue(doppiCore.getBuyPositionCount(address(traderBot)) > 0); // no new order
        assertTrue(doppiCore.getSellPositionCount(address(traderBot)) > 0); // with new orders
        assertEq(doppiCore.getSellPositionCount(address(traderBot)), 5); // only 3 sell orders
    }

    function test_Scenario_DepositUSDTBTC_Without_BTC_Liquidity() public {
        
        uint256 depositAmount = 10000 ether;
        uint256 depositBTCAmount = 0.10000 ether;
        vm.startPrank(trader);
        deal(BTC, address(trader), 10 ether);
        deal(USDT, address(trader), 10_000_000 ether);
        deal(LINK, mockRegistryConsumerAddr, 10_000 ether); //mockRegistryConsumer

        usdt.approve(address(doppiRouter), depositAmount);
        
        uint256 sharesA = doppiRouter.deposit(address(usdt), depositAmount);

        uint256 maxDeposit = doppiCore.acceptedDeposit(true);
        
        usdt.approve(address(doppiCore), depositAmount);
        btc.approve(address(doppiCore), depositBTCAmount);
        vm.stopPrank();

        int256 startPrice = int256(9142000000000);
        _manipulateRealChainlink(startPrice, address(oracle));

        DualAssetOffer memory sellOffer = impliedVol.getOffer(false, 1, 0);
        vm.startPrank(trader);
        doppiCore.deposit_sell(DepositParams({
            amount: depositBTCAmount,
            strikeZone: 0,
            strikePrice: sellOffer.strikePrice,
            numDays: 1,
            apr: sellOffer.apr,
            expiry: sellOffer.expiry
        }));
        
        vm.stopPrank();

        // Verify active
        // assertTrue(doppiCore.getBuyPositionCount(address(trader)) > 0);
        assertTrue(doppiCore.getSellPositionCount(address(trader)) > 0);

        int256 newPrice = int256(9152000000000);
        _manipulateRealChainlink(newPrice, address(oracle));

        // 1 day fast forward and settle
        vm.warp(block.timestamp + 1 days + 1);
        _doppiCoreCheckUpkeep_performUpkeep();
    }

    function test_Scenario2_TraderBotStart() public {
        
        
        deal(BTC, address(trader), 1 ether);
        deal(USDT, address(trader), 100_000 ether);
        deal(LINK, mockRegistryConsumerAddr, 10_000 ether); //mockRegistryConsumer


        vm.startPrank(doppiUpkeepManager.owner());
        doppiUpkeepManager.setDefault_Amount(50 ether);
        vm.stopPrank();
        
        // Deploy bot
        vm.startPrank(trader);
        uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
        traderBot.setForwarderAddress(forwarder);
        vm.stopPrank();

        // Fund and start
        vm.startPrank(trader);
        usdt.approve(address(traderBot), 10000 ether);
        btc.approve(address(traderBot), 0.2 ether);
        uint256 gasBefore = gasleft();
        traderBot.start(10000 ether, 0.1 ether);
        uint256 gasUsed = gasBefore - gasleft();
        console.log(gasUsed, "gasUsed in traderBot.start");
        vm.stopPrank();

            // settle core
        vm.warp(block.timestamp + 1 days + 1);
         _doppiCoreCheckUpkeep_performUpkeep();

        vm.startPrank(owner);
        _setupIV(impliedVol);
        vm.stopPrank();

        // place new round of orders
        _doppiTraderCheckUpkeep_performUpkeep(traderBot);

         

    }

    function _depositBTC(uint256 amount) internal returns (DualAssetOffer memory) {

        DualAssetOffer memory sellOffer = impliedVol.getOffer(false, 1, 0);
        DepositParams memory params = DepositParams({
            amount: amount,
            strikeZone: 0,
            strikePrice: sellOffer.strikePrice,
            numDays: 1,
            apr: sellOffer.apr,
            expiry: sellOffer.expiry
        });

        vm.startPrank(trader);
        btc.approve(address(doppiCore), params.amount);
        doppiCore.deposit_sell(params);
        vm.stopPrank();
        return sellOffer;
    }

    function _depositUSDT(uint256 amount, address user) internal returns (DualAssetOffer memory) {

        DualAssetOffer memory buyOffer = impliedVol.getOffer(true, 1, 0);
        DepositParams memory params = DepositParams({
            amount: amount,
            strikeZone: 0,
            strikePrice: buyOffer.strikePrice,
            numDays: 1,
            apr: buyOffer.apr,
            expiry: buyOffer.expiry
        });

        vm.startPrank(user);
        usdt.approve(address(doppiCore), params.amount);
        doppiCore.deposit_buy(params);
        vm.stopPrank();
        return buyOffer;
    }

    function _setDoppiCoreProperties(
        DoppiCore _doppiCore, 
        DoppiTraderFactory _doppiFactory,
        address _doppiOpportunity
        ) internal {
        
        _doppiCore.setForwarderAddress(forwarder);
        _doppiCore.setOpportunityBot(_doppiOpportunity, true);
        _doppiCore.setDoppiTraderFactory(_doppiFactory);
        _doppiCore.setAPRTolerance(300);
        _doppiCore.setTreasury(treasury, 1000);
    }

    function _setDoppiLiquidityProperties(
        DoppiLiquidity _doppiLP, 
        address _doppiCore, 
        DoppiLiquidityRouter _doppiRouter,
        address _doppiFactory
        ) internal {
        
        _doppiLP.setDoppiCore(_doppiCore);
        _doppiLP.setEntryPoint(address(_doppiRouter.entryPointA()), true);
        _doppiLP.setEntryPoint(address(_doppiRouter.entryPointB()), true);
        _doppiLP.setDoppiTraderFactory(_doppiFactory);
        _doppiLP.lockEntryPoints();
    }

    function _deployDoppiCore(DoppiLiquidity _doppiLP, DoppiOffer _impliedVol, DoppiPoints _doppiPoints) internal returns (DoppiCore) {
        
        DoppiCore _doppiCore = new DoppiCore(USDT, BTC, _doppiLP, _impliedVol, address(_doppiPoints));
        _doppiPoints.setDoppiCore(address(_doppiCore), true);
        _doppiCore.setTreasury(treasury, 1000);
        _doppiCore.setUpkeeps_per_check(100);
        return _doppiCore;
    }
        
    function _deployDoppiOpportunity(address _doppiCore, address _doppiLP) internal returns (DoppiOpportunity) {
    
        DoppiOpportunity _doppiOpportunity = new DoppiOpportunity(_doppiCore, _doppiLP);
        return _doppiOpportunity;
    }

    function _deployDoppiLiquidity() internal returns (DoppiLiquidity) {
        
        DoppiLiquidity _doppiLP = new DoppiLiquidity("Doppi BTC-USDT LP", "BTCB-USDT", address(IERC20(USDT)), address(IERC20(BTC)));
        configLP = _getConfigLP();
        _doppiLP.setConfig(configLP); 
        _doppiLP.approveRouter();
        _doppiLP.setForwarderAddress(forwarder);
        
        return _doppiLP;
    }

    function _deployBlackScholes() internal returns (BlackScholes) {
        
        BlackScholes _blackScholes = new BlackScholes();
        return _blackScholes;
    }

    function _deployDoppiClaim(DoppiPoints _doppiPoints, DoppiReferral _doppiReferral, DOPPI _doppiToken) internal returns (DoppiClaim) {
        DoppiClaim _doppiClaim = new DoppiClaim(
            address(_doppiToken),
            address(_doppiPoints),
            address(_doppiReferral),
            1 // 1 token per point
        );
        _doppiPoints.setDoppiClaim(address(_doppiClaim));
        _doppiReferral.setDoppiClaim(address(_doppiClaim));
        _doppiToken.addMinter(address(_doppiClaim));
        return _doppiClaim;
    }

    function _deployDoppiReferral(address _doppiPoints) internal returns (DoppiReferral) {
        DoppiReferral _doppiReferral = new DoppiReferral(_doppiPoints, 150, 100, 50);
        _doppiReferral.setMinVolumeForL2L3(1_000 ether, 2_000 ether);
        DoppiPoints(_doppiPoints).setDoppiReferral(address(_doppiReferral));
        return _doppiReferral;
    }

    function _deployDoppiOffer(address _blackScholes) internal returns (DoppiOffer) {
        
        DoppiOffer _impliedVol = new DoppiOffer(IBlackScholes(_blackScholes), CHAINLINK_BTC_USD, 500);
        _impliedVol.setTwapDuration(3600);
        _impliedVol.setPancakeV3Pool(PCSWAP_V3Pool);
        return _impliedVol;
    }

    function _deployDoppiPoints() internal returns (DoppiPoints) {
        DoppiPoints _doppiPoints = new DoppiPoints();
        return _doppiPoints;
    }

    function _deployDoppiUpkeepManager(address _doppiFactory) internal returns (DoppiUpkeepManager) {

        IAutomationRegistrar registrar = IAutomationRegistrar(CHAINLINK_Registrar);
        // IAutomationRegistryConsumer registryConsumer = IAutomationRegistryConsumer(CHAINLINK_RegistryConsumer);
        MockRegistryConsumer mockRegistryConsumer = new MockRegistryConsumer();
        mockRegistryConsumerAddr = address(mockRegistryConsumer);
        DoppiUpkeepManager _doppiUpkeepManager = new DoppiUpkeepManager(
            address(mockRegistryConsumer), 
            address(registrar), 
            CHAINLINK_LINK_USD, 
            address(PCSWAP_V3_ROUTER),
            LINK_PEGGED_SWAP,
            USDT, 
            LINK, // erc677 link
            BNBLINK, //bnb link
            _doppiFactory,
            treasury
        );        
        // console.log("mockRegistryConsumer deployed at:", address(mockRegistryConsumer));
        _doppiUpkeepManager.setMaxDelay(10 days);
        _doppiUpkeepManager.setDefault_Amount(0);
        _doppiUpkeepManager.setForwarderAddress(forwarder);
        doppiFactory.setDoppiUpKeepManager(address(_doppiUpkeepManager));

        return _doppiUpkeepManager;
    }  

    function _doppiCoreCheckUpkeep_performUpkeep() internal {

        uint256 gasBefore = gasleft();
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        uint256 gasUsed = gasBefore - gasleft();
        console.log(gasUsed, "gasUsed in doppiCore.checkUpkeep");
        
        if(upkeepNeeded){
            vm.prank(forwarder);
            gasBefore = gasleft();
            doppiCore.performUpkeep(performData);  
            gasUsed = gasBefore - gasleft();
            console.log(gasUsed, "gasUsed in doppiCore.performUpkeep");
            vm.stopPrank();
        }
    }

    function _setupIV(DoppiOffer _impliedVol) internal {
        
        // vm.warp(vm.getBlockTimestamp() + 30 days); 
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;
        _impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
        _impliedVol.setTwapDuration(3600);
        _impliedVol.setPancakeV3Pool(PCSWAP_V3Pool);
    }

    function _manipulateRealChainlink(int256 newPrice, address _oracle) internal {
        
        // Then override the feed address
        vm.prank(owner);
        MockOracle(_oracle).setPrice(newPrice);
        vm.stopPrank();
        configLP = _getConfigLP();
        configLP.chainLinkFeed = _oracle;
        vm.prank(doppiLP.owner());
        doppiLP.setConfig(configLP); 
        vm.stopPrank();
        vm.prank(impliedVol.owner());
        impliedVol.setOracle(_oracle);
        vm.stopPrank();

    }

    function _getConfigLP() internal returns (ConfigParam memory _configLP)  {

        _configLP = ConfigParam({
			chainLinkFeed : CHAINLINK_BTC_USD,
			router : PCSWAP_V3_ROUTER,
			poolFee: 500,  
			slippage: 2000,
			liquidityFee: 1000,
			priceDecimals: 8,
			decimals: 10 ** 8,
			v3Pool: PCSWAP_V3Pool,
			twapDuration: 3600,
			maxDepositPercentage: 20000,
			maxDelay: 2 minutes,
			maxSwap: 500000 ether,
            priceGap: 500,
            unwindGapMultiplier: 1
		});
    }

    function _generateRandomAmount(uint256 seed) internal pure returns (uint256) {
        // Generate amount between 1000 and 5000 tokens
        uint256 base = 1000 * 10**18;
        if(seed > 15){
            seed -= 5;
        }else if(seed > 25){
            seed -= 10;
        }  
        // uint256 variation = (uint256(keccak256(abi.encodePacked(seed))) % 4990) + 10;
        return base * (seed + 1);
    }

    function _getStrikePrice(uint256 _price, uint8 _strikeZone, bool _isBuy) internal view returns (uint256) {
        
        uint256 priceGapWithDecimals = 500 * 1e8;
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * (_strikeZone - 1)) : _price + (priceGapWithDecimals * _strikeZone);
    }

    function _doppiTraderCheckUpkeep_performUpkeep(DoppiTrader traderBot) internal {
        
        uint256 gasBefore = gasleft();
        (bool upkeepNeeded, bytes memory performData) = traderBot.checkUpkeep("");
        uint256 gasUsed = gasBefore - gasleft();
        console.log(upkeepNeeded, gasUsed, "gasUsed in traderBot.checkUpkeep");
        assertLt(gasUsed, 400_000, "Gas usage too high");

        if(upkeepNeeded){
            vm.prank(traderBot.s_forwarderAddress());
            gasBefore = gasleft();
            traderBot.performUpkeep(performData);
            gasUsed = gasBefore - gasleft();
            console.log(gasUsed, "gasUsed in traderBot.performUpkeep");
            assertLt(gasUsed, 4_500_000, "Gas usage too high");
            vm.stopPrank();
        }
        
    }
}
