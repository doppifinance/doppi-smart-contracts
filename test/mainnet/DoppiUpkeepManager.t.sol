// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
import {DoppiTrader} from "../../src/mainnet/DoppiTrader.sol";
import {DoppiCore} from "../../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../../src/mainnet/DoppiLiquidityRouter.sol";
import {BlackScholes} from "../../src/mainnet/BlackScholes.sol";
import {ImpliedVol} from "../../src/mainnet/ImpliedVol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "../../src/test/MockToken.sol";
import {MockOracle} from "../../src/test/MockOracle.sol";
import {MockRegistryConsumer} from "../../src/test/MockRegistryConsumer.sol";
import {DoppiOpportunity} from "../../src/mainnet/DoppiOpportunity.sol";
import {Swapper} from "../../src/test/Swapper.sol";
import {DoppiConfig} from "../../src/mainnet/DoppiConfig.sol";
import {DoppiUpkeepManager} from "../../src/mainnet/DoppiUpkeepManager.sol";
import "../../src/Interface/LinkTokenInterface.sol";
import "../../src/Interface/IAutomationRegistrar.sol";
import "../../src/Interface/IAutomationRegistryConsumer.sol";


contract DoppiUpkeepManagerTest is Test {
    DoppiTraderFactory doppiFactory;
    DoppiCore doppiCore;
    DoppiLiquidity doppiLP;
    DoppiLiquidityRouter doppiRouter;
    ImpliedVol impliedVol;
    IERC20 usdt;
    IERC20 btc;
    LinkTokenInterface link;
    MockOracle oracle;
    DoppiOpportunity doppiOpportunity;
    Swapper public swapper;
    DoppiConfig doppiConfig;
    DoppiUpkeepManager doppiUpkeepManager;
    IAutomationRegistrar public registrar;
    IAutomationRegistryConsumer public registryConsumer;
    MockRegistryConsumer public mockRegistryConsumer;
    
    // Mainnet addresses for forking
    // address constant LINKTOKEN = address(0x404460C6A5EdE2D891e8297795264fDe62ADBB75)
    address constant LINK = address(0x404460C6A5EdE2D891e8297795264fDe62ADBB75);
    address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
    address constant BTCB = address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    address constant CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
    address constant PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    address constant PCSWAP_V3_QUOTER = address(0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997);

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address admin = makeAddr("admin");
    address forwarder = makeAddr("forwarder");
    address trader = makeAddr("trader");
    address trader2 = makeAddr("trader2");
    address liquidityProvider = makeAddr("liquidityProvider");
    
    uint24[] defaultWeights = [2000, 2000, 2000, 2000, 2000]; // Equal weights

    function setUp() public {
        
        // Fork Mainnet at a specific block
        uint256 mainnetFork = vm.createFork("mainnet", 60905002); // Do not change the block number for the unit test
        vm.selectFork(mainnetFork);
        
        // Start prank as owner
        vm.startPrank(owner);
        oracle = new MockOracle(int256(100_000 * 1e8), 8);

        usdt = IERC20(USDT);
        btc = IERC20(BTCB);
        link = LinkTokenInterface(LINK);
        doppiConfig = new DoppiConfig();
        doppiConfig.setRouter(PCSWAP_V3_ROUTER);
        doppiConfig.setQuoter(PCSWAP_V3_QUOTER);
        doppiConfig.setTreasury(treasury);
        doppiConfig.setPancakeV3Pool(PCSWAP_V3_ROUTER); 
        doppiConfig.setOracle(CHAINLINK_BTC_USD);
        doppiConfig.setSlippage(500);
        
        impliedVol = _setupIV();
        doppiLP = _setupLP(address(usdt), address(btc));

        doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol);
        doppiOpportunity = new DoppiOpportunity(address(doppiCore), address(doppiLP));
        doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
        doppiFactory = new DoppiTraderFactory(IERC20(usdt), IERC20(btc), doppiCore, doppiLP, doppiRouter);

        doppiOpportunity.setForwarderAddress(forwarder);
        doppiOpportunity.setDoppiConfig(doppiConfig);
        doppiCore.setForwarderAddress(forwarder);
        doppiCore.setAdmin(address(doppiOpportunity), true);
        doppiLP.setForwarderAddress(forwarder);
        doppiLP.setDoppiCore(address(doppiCore));
        doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
        doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(doppiRouter.entryPointB()), address(btc));
        doppiLP.setDoppiTraderFactory(address(doppiFactory));
        doppiCore.setDoppiTraderFactory(doppiFactory);

        address chainLinkFeed = address(0xca236E327F629f9Fc2c30A4E95775EbF0B89fac8);
        registrar = IAutomationRegistrar(address(0xf671F60bCC964B309D22424886FF202807381B32));
        registryConsumer = IAutomationRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C));
        mockRegistryConsumer = new MockRegistryConsumer();
        deal(LINK, address(mockRegistryConsumer), 100000 ether);
        doppiUpkeepManager = new DoppiUpkeepManager(
            address(mockRegistryConsumer), 
            address(registrar), 
            chainLinkFeed, 
            address(address(PCSWAP_V3_ROUTER)),
            address(0x1FCc3B22955e76Ca48bF025f1A6993685975Bb9e),
            address(usdt), 
            LINK, // erc677 link
            address(0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD), //bnb link
            address(doppiFactory),
            treasury
        );
        doppiUpkeepManager.setForwarderAddress(forwarder);
        
        vm.stopPrank();
    }

    function test_setupAutomation() public {
        
        vm.startPrank(trader);
        deal(USDT, address(trader), 1000 ether);
        deal(LINK, address(trader), 1000 ether);

        // Deploy bot
        uint256 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = doppiFactory.traderBots(traderId);
        // console.log(traderBot.s_forwarderAddress(), "s_forwarderAddress");
        usdt.approve(address(doppiUpkeepManager), 10000 ether);
        doppiUpkeepManager.setupAutomation(address(traderBot));
        vm.stopPrank();
        
        // vm.startPrank(owner);
        // address forwarderaddr = doppiUpkeepManager.getForwarder(upKeepId);
        // traderBot.owner();
        // doppiFactory.setTraderBotForwarderAddress(forwarderaddr, address(traderBot));
        // vm.stopPrank();
        
    }

    function test_getUpkeep() public {
        
        // set to mainnet contract for testing
        vm.prank(owner);
        doppiUpkeepManager.setRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C)); 
        vm.stopPrank();

        uint256 Id = 75337200939400900360603264278047073108837566842861562262682542704207173235601;
        // IAutomationRegistryConsumer.UpkeepInfo memory result = doppiUpkeepManager.getUpkeep(Id);
        assertEq(doppiUpkeepManager.getForwarder(Id), address(0xe4f96d68Be9614A17067B8072E9fFb6659184a8c));

    }

    function test_mainnet_registry_addfund() public {
        
        // set to mainnet contract for testing
        vm.prank(owner);
        doppiUpkeepManager.setRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C)); 
        vm.stopPrank();

        uint96 amount = 5 ether;
        address existingOwner = address(0xB0FA270BB88450D6d6012E9D8FA0bbFD468bB738);
        uint256 Id = 75337200939400900360603264278047073108837566842861562262682542704207173235601;
        deal(LINK, existingOwner, 10 ether);
        
        vm.startPrank(existingOwner);
        
        IAutomationRegistryConsumer.UpkeepInfo memory resultstart =  doppiUpkeepManager.getUpkeep(Id);

        link.approve(address(registryConsumer), amount);
        registryConsumer.addFunds(Id, amount);
        
        IAutomationRegistryConsumer.UpkeepInfo memory resultend = doppiUpkeepManager.getUpkeep(Id);
        assertGt(resultend.balance, resultstart.balance);
        vm.stopPrank();

    }

    function test_mainnet_registry_cancel() public {
        
        // set to mainnet contract for testing
        vm.prank(owner);
        doppiUpkeepManager.setRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C)); 
        vm.stopPrank();

        address existingOwner = address(0xB0FA270BB88450D6d6012E9D8FA0bbFD468bB738);
        uint256 Id = 75337200939400900360603264278047073108837566842861562262682542704207173235601;
        
        vm.startPrank(existingOwner);
        registryConsumer.cancelUpkeep(Id);
        IAutomationRegistryConsumer.UpkeepInfo memory result2 = doppiUpkeepManager.getUpkeep(Id);
        assertEq(result2.maxValidBlocknumber, block.number + 50);
        vm.stopPrank();
    }

    function test_mainnet_registry_getMinBalance() public {
        
        // set to mainnet contract for testing
        vm.prank(owner);
        doppiUpkeepManager.setRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C)); 
        vm.stopPrank();

        address existingOwner = address(0xB0FA270BB88450D6d6012E9D8FA0bbFD468bB738);
        uint256 Id = 75337200939400900360603264278047073108837566842861562262682542704207173235601;
        
        vm.startPrank(existingOwner);
        uint96 minBalance = registryConsumer.getMinBalance(Id);
        // IAutomationRegistryConsumer.UpkeepInfo memory result2 = doppiUpkeepManager.getUpkeep(Id);
        console.log(minBalance);
        // assertEq(result2.maxValidBlocknumber, block.number);
        vm.stopPrank();
    }

    function test_mainnet_checkUpkeep() public {
        
        test_setupAutomation();
        test_setupAutomation();

        uint256 keepId = 10126513187475120052854210204634476291137427371787226750303145633439909703611;
        mockRegistryConsumer.updateAmountSpent(keepId, 0.1 ether);
        
        vm.roll(block.number + 100); // Forward 100 blocks
        (bool upkeepNeeded, ) = doppiUpkeepManager.checkUpkeep("");
        assertTrue(upkeepNeeded);

    }

    function test_mainnet_performUpkeep_noTopUp() public {
        
        test_setupAutomation();
        test_setupAutomation();

        uint256 keepId = 10126513187475120052854210204634476291137427371787226750303145633439909703611;
        mockRegistryConsumer.updateAmountSpent(keepId, 1e17);
        
        vm.roll(block.number + 100); // Forward 100 blocks
        (bool upkeepNeeded, bytes memory performData) = doppiUpkeepManager.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(forwarder);
        doppiUpkeepManager.performUpkeep(performData);  
        vm.stopPrank();

        DoppiUpkeepManager.DoppiUpkeepPayment memory p = doppiUpkeepManager.getPaymentStatus(keepId);
        // console.log(p.lastPaidAmount, p.lastBlockCharged, p.trader);
        assertEq(p.lastPaidAmount, 100000000000000000);

        uint256 balstart = usdt.balanceOf(treasury);

        vm.roll(block.number + 200); // Forward 100 blocks
        uint256 keepId2 = 85572568362417814516910336273473322297533253932261901153407809393837727925278;
        
        mockRegistryConsumer.updateAmountSpent(keepId, 1e18);
        mockRegistryConsumer.updateAmountSpent(keepId2, 1e18);
        (upkeepNeeded, performData) = doppiUpkeepManager.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(forwarder);
        doppiUpkeepManager.performUpkeep(performData);  
        vm.stopPrank();

        p = doppiUpkeepManager.getPaymentStatus(keepId);
        assertEq(p.lastPaidAmount, 1100000000000000000);
        p = doppiUpkeepManager.getPaymentStatus(keepId2);
        assertEq(p.lastPaidAmount, 1000000000000000000);
        uint256 balend = usdt.balanceOf(treasury);
        assertGt(balend, balstart);

    }

    function test_mainnet_performUpkeep_TopUp() public {
        
        test_setupAutomation();
        test_setupAutomation();

        uint256 keepId = 10126513187475120052854210204634476291137427371787226750303145633439909703611;
        mockRegistryConsumer.updateAmountSpent(keepId, 4.1 ether);
        
        vm.roll(block.number + 100); // Forward 100 blocks
        (bool upkeepNeeded, bytes memory performData) = doppiUpkeepManager.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(forwarder);
        doppiUpkeepManager.performUpkeep(performData);  
        vm.stopPrank();
        
        DoppiUpkeepManager.DoppiUpkeepPayment memory p = doppiUpkeepManager.getPaymentStatus(keepId);
        assertEq(p.lastPaidAmount, 4.1 ether);
    }

    function test_mainnet_performUpkeep_TopUp_Pagination() public {
        
        vm.prank(owner);
        doppiUpkeepManager.setUpkeeps_per_check(1);
        vm.stopPrank();

        test_setupAutomation();
        test_setupAutomation();

        uint256 keepId = 10126513187475120052854210204634476291137427371787226750303145633439909703611;
        mockRegistryConsumer.updateAmountSpent(keepId, 1e17);
        
        uint256 keepId2 = 85572568362417814516910336273473322297533253932261901153407809393837727925278;
        mockRegistryConsumer.updateAmountSpent(keepId2, 1e18);

        vm.roll(block.number + 100); // Forward 100 blocks
        (bool upkeepNeeded, bytes memory performData) = doppiUpkeepManager.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(forwarder);
        doppiUpkeepManager.performUpkeep(performData);  
        vm.stopPrank();

        // Only 1 is processed
        DoppiUpkeepManager.DoppiUpkeepPayment memory p = doppiUpkeepManager.getPaymentStatus(keepId);
        assertEq(p.lastPaidAmount, 0);
        p = doppiUpkeepManager.getPaymentStatus(keepId2);
        assertEq(p.lastPaidAmount, 1000000000000000000);       

        // next checkUpkeep process the other 1
        vm.roll(block.number + 1);
        (upkeepNeeded, performData) = doppiUpkeepManager.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(forwarder);
        doppiUpkeepManager.performUpkeep(performData);   
        vm.stopPrank();

        // the other 1 was processed
        p = doppiUpkeepManager.getPaymentStatus(keepId);
        assertEq(p.lastPaidAmount, 100000000000000000);       
        p = doppiUpkeepManager.getPaymentStatus(keepId2);
        assertEq(p.lastPaidAmount, 1000000000000000000);       

    }

    function test_mainnet_performUpkeep_TopUp_No_Allowance() public {
        
        vm.startPrank(trader);
        deal(USDT, address(trader), 1000 ether);
        deal(LINK, address(trader), 1000 ether);

        // Deploy bot
        uint256 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = doppiFactory.traderBots(traderId);
        usdt.approve(address(doppiUpkeepManager), 300 ether);
        uint256 upKeepId = doppiUpkeepManager.setupAutomation(address(traderBot));
        console.log(upKeepId, traderBot.validTrader());
        
        // address forwarderaddr = doppiUpkeepManager.getForwarder(upKeepId);
        // doppiFactory.setTraderBotForwarderAddress(forwarderaddr, address(traderBot));
        vm.stopPrank();


        uint256 keepId = 85572568362417814516910336273473322297533253932261901153407809393837727925278;
        mockRegistryConsumer.updateAmountSpent(keepId, 4.1 ether);
        
        vm.roll(block.number + 100); // Forward 100 blocks
        (bool upkeepNeeded, ) = doppiUpkeepManager.checkUpkeep("");
        assertFalse(upkeepNeeded); // no performUpkeep as no allowance detected
        
    }

    function test_mainnet_stopWithdraw_no_pending_fee() public {
        
        test_setupAutomation();

        uint256 keepId = 85572568362417814516910336273473322297533253932261901153407809393837727925278;
        mockRegistryConsumer.updateAmountSpent(keepId, 4.1 ether);
        
        vm.roll(block.number + 100); // Forward 100 blocks
        (bool upkeepNeeded, bytes memory performData) = doppiUpkeepManager.checkUpkeep("");
        assertTrue(upkeepNeeded);
        
        vm.prank(forwarder);
        doppiUpkeepManager.performUpkeep(performData);  
        vm.stopPrank();

        DoppiUpkeepManager.DoppiUpkeepPayment memory p = doppiUpkeepManager.getPaymentStatus(keepId);
        assertEq(p.lastPaidAmount, 4.1 ether);

        uint256 initBal = link.balanceOf(trader);
        uint256 upkeepBal = doppiUpkeepManager.getUpkeepBalance(keepId);
        // console.log(upkeepBal, "upkeepBal");
        vm.prank(trader);
        doppiUpkeepManager.stopWithdraw(keepId);
        vm.stopPrank();
        uint256 endBal = link.balanceOf(trader);
        assertEq(endBal - initBal, upkeepBal);
        // console.log(initBal, );
        
    }

    function test_mainnet_stopWithdraw_pending_fee() public {
        
        // Deploy bot
        vm.startPrank(trader);
        deal(USDT, address(trader), 1000 ether);
        uint256 traderId = doppiFactory.deployTraderBot(defaultWeights);
        DoppiTrader traderBot = doppiFactory.traderBots(traderId);
        usdt.approve(address(doppiUpkeepManager), 300 ether);
        doppiUpkeepManager.setupAutomation(address(traderBot));

        // vm.startPrank(owner);
        // address forwarderaddr = doppiUpkeepManager.getForwarder(upKeepId);
        // traderBot.owner();
        // doppiFactory.setTraderBotForwarderAddress(forwarderaddr, address(traderBot));
        // vm.stopPrank();

        uint256 keepId = 85572568362417814516910336273473322297533253932261901153407809393837727925278;
        mockRegistryConsumer.updateAmountSpent(keepId, 4.1 ether);
        
        vm.roll(block.number + 100); // Forward 100 blocks
        (bool upkeepNeeded, ) = doppiUpkeepManager.checkUpkeep("");
        assertFalse(upkeepNeeded);

        uint256 initBal = link.balanceOf(trader);
        uint256 upkeepBal = doppiUpkeepManager.getUpkeepBalance(keepId);
        doppiUpkeepManager.stopWithdraw(keepId);
        uint256 endBal = link.balanceOf(trader);
        assertEq(endBal - initBal, upkeepBal);
        
        vm.stopPrank();
        
    }


    function _setupLP(address _assetA, address _assetB) internal returns (DoppiLiquidity _doppiLP) {
        _doppiLP =
            new DoppiLiquidity("Doppi BTC-USDT LP", "BTCB-USDT", IERC20(_assetA), IERC20(_assetB));
        _doppiLP.setDoppiConfig(doppiConfig); 
        _doppiLP.approveRouter();
    }
    

    function _setupIV() internal returns (ImpliedVol _impliedVol) {
        
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;
        BlackScholes blackScholes = new BlackScholes();
        _impliedVol = new ImpliedVol(blackScholes);
        _impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
    }

    
}
