// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// import "forge-std/Test.sol";
// import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
// import {DoppiTrader} from "../../src/mainnet/DoppiTrader.sol";
// import {DoppiCore} from "../../src/mainnet/DoppiCore.sol";
// import {DoppiLiquidity} from "../../src/mainnet/DoppiLiquidity.sol";
// import {DoppiLiquidityRouter} from "../../src/mainnet/DoppiLiquidityRouter.sol";
// import {BlackScholes} from "../../src/mainnet/BlackScholes.sol";
// import {DoppiOffer} from "../../src/mainnet/DoppiOffer.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {MockToken} from "../../src/test/MockToken.sol";
// import {MockOracle} from "../../src/test/MockOracle.sol";
// import {MockRegistryConsumer} from "../../src/test/MockRegistryConsumer.sol";
// import {DoppiOpportunity} from "../../src/mainnet/DoppiOpportunity.sol";
// import {DoppiPoints} from "../../src/mainnet/DoppiPoints.sol";
// import {Swapper} from "../../src/test/Swapper.sol";
// import {DoppiUpkeepManager, DoppiUpkeepPayment} from "../../src/mainnet/DoppiUpkeepManager.sol";
// import "../../src/Interface/LinkTokenInterface.sol";
// import "../../src/Interface/IAutomationRegistrar.sol";
// import "../../src/Interface/IAutomationRegistryConsumer.sol";
// import {TestParamLib} from "../../src/Library/TestParamLib.sol";
// import "../../src/mainnet/DoppiLiquidityTypes.sol";

// contract DoppiUpkeepManagerTest is Test {
//     DoppiTraderFactory doppiFactory;
//     DoppiCore doppiCore;
//     DoppiLiquidity doppiLP;
//     DoppiLiquidityRouter doppiRouter;
//     DoppiOffer impliedVol;
//     IERC20 usdt;
//     IERC20 btc;
//     LinkTokenInterface link;
//     MockOracle oracle;
//     DoppiOpportunity doppiOpportunity;
//     Swapper public swapper;
//     DoppiPoints doppiPoints;
//     DoppiUpkeepManager doppiUpkeepManager;
//     IAutomationRegistrar public registrar;
//     IAutomationRegistryConsumer public registryConsumer;
//     MockRegistryConsumer public mockRegistryConsumer;
//     ConfigParam configLP;

//     // Mainnet addresses for forking
//     // address constant LINKTOKEN = address(0x404460C6A5EdE2D891e8297795264fDe62ADBB75)
//     address constant LINK = address(0x404460C6A5EdE2D891e8297795264fDe62ADBB75);
//     address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
//     address constant BTCB = address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
//     address constant CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
//     address constant PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
//     address constant PCSWAP_V3_QUOTER = address(0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997);

//     address owner = makeAddr("owner");
//     address treasury = makeAddr("treasury");
//     address admin = makeAddr("admin");
//     address forwarder = makeAddr("forwarder");
//     address trader = makeAddr("trader");
//     address trader2 = makeAddr("trader2");
//     address liquidityProvider = makeAddr("liquidityProvider");
    
//     uint24[] defaultWeights = [2000, 2000, 2000, 2000, 2000]; // Equal weights

//     function setUp() public {
        
//         // Fork Mainnet at a specific block
//         uint256 mainnetFork = vm.createFork("mainnet", 60905002); // Do not change the block number for the unit test
//         vm.selectFork(mainnetFork);
        
//         // Start prank as owner
//         vm.startPrank(owner);
//         oracle = new MockOracle(int256(100_000 * 1e8), 8);

//         usdt = IERC20(USDT);
//         btc = IERC20(BTCB);
//         link = LinkTokenInterface(LINK);
        
//         configLP = TestParamLib.get_configLP();
//         impliedVol = _setupIV();
//         doppiPoints = _deployDoppiPoints();
//         doppiLP = _setupLP(address(usdt), address(btc));
//         doppiCore = new DoppiCore(address(usdt), address(btc), doppiLP, impliedVol, address(doppiPoints));
//         doppiOpportunity = new DoppiOpportunity(address(doppiCore), address(doppiLP));
//         doppiRouter = new DoppiLiquidityRouter(IERC20(usdt), IERC20(btc), doppiLP);
//         doppiFactory = new DoppiTraderFactory(IERC20(usdt), IERC20(btc), address(doppiCore), address(doppiLP), address(doppiRouter), address(impliedVol), address(doppiPoints));

//         doppiOpportunity.setForwarderAddress(forwarder);
//         doppiCore.setForwarderAddress(forwarder);
//         doppiCore.setTreasury(treasury, 1000);
//         doppiPoints.setDoppiCore(address(doppiCore), true);
//         doppiCore.setOpportunityBot(address(doppiOpportunity), true);
//         doppiLP.setForwarderAddress(forwarder);
//         doppiLP.setDoppiCore(address(doppiCore));
//         doppiLP.setEntryPoint(address(doppiRouter.entryPointA()), true);
//         doppiLP.setEntryPoint(address(doppiRouter.entryPointB()), true);
//         doppiLP.setDoppiTraderFactory(address(doppiFactory));
//         doppiCore.setDoppiTraderFactory(doppiFactory);

//         address chainLinkFeed = address(0xca236E327F629f9Fc2c30A4E95775EbF0B89fac8);
//         registrar = IAutomationRegistrar(address(0xf671F60bCC964B309D22424886FF202807381B32));
//         registryConsumer = IAutomationRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C));
//         mockRegistryConsumer = new MockRegistryConsumer();
//         deal(LINK, address(mockRegistryConsumer), 100000 ether);
//         doppiUpkeepManager = new DoppiUpkeepManager(
//             address(mockRegistryConsumer), 
//             address(registrar), 
//             chainLinkFeed, 
//             address(address(PCSWAP_V3_ROUTER)),
//             address(0x1FCc3B22955e76Ca48bF025f1A6993685975Bb9e),
//             address(usdt), 
//             LINK, // erc677 link
//             address(0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD), //bnb link
//             address(doppiFactory),
//             treasury
//         );
//         doppiUpkeepManager.setForwarderAddress(forwarder);
//         doppiFactory.setDoppiUpKeepManager(address(doppiUpkeepManager));
//         vm.warp(vm.getBlockTimestamp() - 2592483);
//         vm.stopPrank();
//     }

//     function test_getUpkeep() public {
        
//         // set to mainnet contract for testing
//         vm.prank(owner);
//         doppiUpkeepManager.setRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C)); 
//         vm.stopPrank();

//         uint256 Id = 75337200939400900360603264278047073108837566842861562262682542704207173235601;
//         // IAutomationRegistryConsumer.UpkeepInfo memory result = doppiUpkeepManager.getUpkeep(Id);
//         assertEq(doppiUpkeepManager.getForwarder(Id), address(0xe4f96d68Be9614A17067B8072E9fFb6659184a8c));

//     }

//     function test_mainnet_registry_addfund() public {
        
//         // set to mainnet contract for testing
//         vm.prank(owner);
//         doppiUpkeepManager.setRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C)); 
//         vm.stopPrank();

//         uint96 amount = 5 ether;
//         address existingOwner = address(0xB0FA270BB88450D6d6012E9D8FA0bbFD468bB738);
//         uint256 Id = 75337200939400900360603264278047073108837566842861562262682542704207173235601;
//         deal(LINK, existingOwner, 10 ether);
        
//         vm.startPrank(existingOwner);
        
//         IAutomationRegistryConsumer.UpkeepInfo memory resultstart =  doppiUpkeepManager.getUpkeep(Id);

//         link.approve(address(registryConsumer), amount);
//         registryConsumer.addFunds(Id, amount);
        
//         IAutomationRegistryConsumer.UpkeepInfo memory resultend = doppiUpkeepManager.getUpkeep(Id);
//         assertGt(resultend.balance, resultstart.balance);
//         vm.stopPrank();

//     }

//     function test_mainnet_registry_cancel() public {
        
//         // set to mainnet contract for testing
//         vm.prank(owner);
//         doppiUpkeepManager.setRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C)); 
//         vm.stopPrank();

//         address existingOwner = address(0xB0FA270BB88450D6d6012E9D8FA0bbFD468bB738);
//         uint256 Id = 75337200939400900360603264278047073108837566842861562262682542704207173235601;
        
//         vm.startPrank(existingOwner);
//         registryConsumer.cancelUpkeep(Id);
//         IAutomationRegistryConsumer.UpkeepInfo memory result2 = doppiUpkeepManager.getUpkeep(Id);
//         assertEq(result2.maxValidBlocknumber, block.number + 50);
//         vm.stopPrank();
//     }

//     function test_mainnet_registry_setMaxGas() public {
        
//         // set to mainnet contract for testing
//         vm.prank(owner);
//         doppiUpkeepManager.setRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C)); 
//         vm.stopPrank();

//         address existingOwner = address(0xB0FA270BB88450D6d6012E9D8FA0bbFD468bB738);
//         uint256 Id = 75337200939400900360603264278047073108837566842861562262682542704207173235601;
        
//         vm.startPrank(existingOwner);
//         registryConsumer.setUpkeepGasLimit(Id, 2000000);
//         IAutomationRegistryConsumer.UpkeepInfo memory result2 = doppiUpkeepManager.getUpkeep(Id);
//         assertEq(result2.executeGas, 2000000);
//         vm.stopPrank();
//     }

//     function test_mainnet_registry_getMinBalance() public {
        
//         // set to mainnet contract for testing
//         vm.prank(owner);
//         doppiUpkeepManager.setRegistryConsumer(address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C)); 
//         vm.stopPrank();

//         address existingOwner = address(0xB0FA270BB88450D6d6012E9D8FA0bbFD468bB738);
//         uint256 Id = 75337200939400900360603264278047073108837566842861562262682542704207173235601;
        
//         vm.startPrank(existingOwner);
//         uint96 minBalance = registryConsumer.getMinBalance(Id);
//         // IAutomationRegistryConsumer.UpkeepInfo memory result2 = doppiUpkeepManager.getUpkeep(Id);
//         console.log(minBalance);
//         // assertEq(result2.maxValidBlocknumber, block.number);
//         vm.stopPrank();
//     }

//     function test_mainnet_stopWithdraw_no_pending_fee() public {
        
//         DoppiTrader traderBot = _deployBot(trader);
        
//         uint256 upKeepid = doppiUpkeepManager.getUpkeepIdByBot(address(traderBot));
//         mockRegistryConsumer.updateAmountSpent(upKeepid, 4.1 ether);

//         vm.roll(block.number + 100); // Forward 100 blocks
//         // ensure trader bot update fee
//         (bool upkeepNeeded, bytes memory performData) = traderBot.checkUpkeep("");
//         if(upkeepNeeded){
//             vm.prank(traderBot.s_forwarderAddress());
//             traderBot.performUpkeep(performData);
//             vm.stopPrank();
//         }
        
//         DoppiUpkeepPayment memory p = doppiUpkeepManager.getPaymentStatus(upKeepid);
//         assertEq(p.lastPaidAmount, 4.1 ether);

//         uint256 initBal = usdt.balanceOf(trader);
//         uint256 upkeepBal = doppiUpkeepManager.getUpkeepBalance(upKeepid);
//         vm.prank(trader);
//         doppiUpkeepManager.cancelUpkeep(upKeepid);
//         vm.stopPrank();
        
//         vm.roll(block.number + 1000);
        
//         vm.prank(trader);
//         doppiUpkeepManager.stopWithdraw(upKeepid, true);
//         vm.stopPrank();
//         uint256 endBal = usdt.balanceOf(trader);
//         // console.log(endBal - initBal, "endBal - initBal");
//         assertEq(endBal - initBal, 300338326863900662573);
        
//     }

//     function test_mainnet_stopWithdraw_pending_fee() public {
        
//         DoppiTrader traderBot = _deployBot(trader);
        
//         uint256 upKeepid = doppiUpkeepManager.getUpkeepIdByBot(address(traderBot));
//         mockRegistryConsumer.updateAmountSpent(upKeepid, 4.1 ether);

//         vm.roll(block.number + 100); // Forward 100 blocks

//         (uint96 fee, ) = doppiUpkeepManager.getUnPaidDoppiFee(upKeepid);
//         DoppiUpkeepPayment memory payment = doppiUpkeepManager.getPaymentStatus(upKeepid);
//         assertGt(fee, 0); // before performUpkeep, fee accumulated
//         assertEq(payment.lastPaidAmount, 0); // before performUpkeep, not paid status
        
//         // ensure trader bot update fee
//         (bool upkeepNeeded, bytes memory performData) = traderBot.checkUpkeep("");
//         if(upkeepNeeded){
//             vm.prank(traderBot.s_forwarderAddress());
//             traderBot.performUpkeep(performData);
//             vm.stopPrank();
//         }
        
//         (fee, ) = doppiUpkeepManager.getUnPaidDoppiFee(upKeepid);
//         payment = doppiUpkeepManager.getPaymentStatus(upKeepid);
//         assertEq(fee, 0); // already paid fee after performUpkeep
//         assertEq(payment.lastPaidAmount, 4.1 ether); // after performUpkeep, paid amount spent
        
//         uint256 initBal = usdt.balanceOf(trader);
//         uint256 upkeepBal = doppiUpkeepManager.getUpkeepBalance(upKeepid);
//         // console.log(upkeepBal, "upkeepBal before stopwithdraw");
//         assertGt(upkeepBal, 0);

//         vm.prank(trader);
//         doppiUpkeepManager.cancelUpkeep(upKeepid);
//         vm.stopPrank();
        
//         vm.roll(block.number + 1000);
//         vm.prank(trader);
//         doppiUpkeepManager.stopWithdraw(upKeepid, true);
//         vm.stopPrank();

//         uint256 endBal = usdt.balanceOf(trader);
//         assertEq(endBal - initBal, 300338326863900662573);
        
//     }

//     function test_deploybot_autosetup_upkeep() public {
        
//         DoppiTrader traderBot = _deployBot(trader);
//         uint256 upKeepid = doppiUpkeepManager.getUpkeepIdByBot(address(traderBot));

//         mockRegistryConsumer.updateAmountSpent(upKeepid, 4.1 ether);
//         vm.roll(block.number + 100); // Forward 100 blocks
        
//         uint256 balbefore = doppiUpkeepManager.getUpkeepBalance(upKeepid);
//         (bool upkeepNeeded, bytes memory performData) = traderBot.checkUpkeep("");
//         vm.prank(traderBot.s_forwarderAddress());
//         traderBot.performUpkeep(performData);
//         vm.stopPrank();

//         uint256 balafter = doppiUpkeepManager.getUpkeepBalance(upKeepid);
//         assertGt(balafter, balbefore);

//         // settle orders after 1 day
//         vm.warp(block.timestamp + 1 days + 1);
//         (upkeepNeeded, performData) = doppiCore.checkUpkeep("");
//         if(upkeepNeeded){
//             vm.prank(doppiCore.s_forwarderAddress());
//             doppiCore.performUpkeep(performData);  
//             vm.stopPrank();
//         }

//         // ensure trader bot can place order
//         (upkeepNeeded, performData) = traderBot.checkUpkeep("");
//         if(upkeepNeeded){
//             vm.prank(traderBot.s_forwarderAddress());
//             traderBot.performUpkeep(performData);
//             vm.stopPrank();
//         }
        
//     }

//     function test_mainnet_checktopup_performtopup() public {
        
//         DoppiTrader traderBot = _deployBot(trader);

//         uint256 upKeepid = doppiUpkeepManager.getUpkeepIdByBot(address(traderBot));
        
//         mockRegistryConsumer.updateAmountSpent(upKeepid, 4.1 ether);
        
//         // to perform topup
//         vm.roll(block.number + 100); // Forward 100 blocks
//         (bool upkeepNeeded, bytes memory performData) = traderBot.checkUpkeep("");
//         if(upkeepNeeded){
//             vm.prank(traderBot.s_forwarderAddress());
//             traderBot.performUpkeep(performData);
//             vm.stopPrank();
//         }

//         (uint96 fee, ) = doppiUpkeepManager.getUnPaidDoppiFee(upKeepid);
//         DoppiUpkeepPayment memory payment = doppiUpkeepManager.getPaymentStatus(upKeepid);
//         // console.log(fee, payment.lastPaidAmount, "fee");
//         assertEq(fee, 0);
//         assertEq(payment.lastPaidAmount, 4.1 ether); 
        
//     }

//     function test_setUpkeepGasLimit() public {
        
//         DoppiTrader traderBot = _deployBot(trader);
//         uint256 upKeepid = doppiUpkeepManager.getUpkeepIdByBot(address(traderBot));
        
//         uint32 newGasLimit = 3_000_000;
        
//         // Only trader can call setUpkeepGasLimit
//         vm.prank(trader);
//         vm.expectEmit(true, false, false, true);
//         emit DoppiUpkeepManager.UpkeepGasLimitSet(upKeepid, newGasLimit);
//         doppiUpkeepManager.setUpkeepGasLimit(upKeepid, newGasLimit);
//         vm.stopPrank();
//     }

//     function _setupLP(address _assetA, address _assetB) internal returns (DoppiLiquidity _doppiLP) {
//         _doppiLP =
//             new DoppiLiquidity("Doppi BTC-USDT LP", "BTCB-USDT", address(IERC20(_assetA)), address(IERC20(_assetB)));
//         _doppiLP.setConfig(configLP);
//         _doppiLP.approveRouter();
//     }
    
//     function _deployDoppiPoints() internal returns (DoppiPoints) {
//         DoppiPoints _doppiPoints = new DoppiPoints();
//         return _doppiPoints;
//     }

//     function _setupIV() internal returns (DoppiOffer _impliedVol) {
        
//         vm.warp(vm.getBlockTimestamp() + 30 days); 
//         int256 a_buy = 0.0000000807142857142833 * 1e27;
//         int256 b_buy = -0.019095857142856592 * 1e27;
//         int256 c_buy = 1159.8454285713972 * 1e27;

//         int256 a_sell = 0.000000102857142857143 * 1e27;
//         int256 b_sell = -0.02447200000000008 * 1e27;
//         int256 c_sell = 1485.8762857142906 * 1e27;
//         BlackScholes blackScholes = new BlackScholes();
//         _impliedVol = new DoppiOffer(blackScholes, configLP.chainLinkFeed, 500);
//         _impliedVol.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
//     }

//     function _deployBot(address _trader) internal returns (DoppiTrader traderBot) {
//         vm.startPrank(_trader);
//         deal(BTCB, address(_trader), 1 ether);
//         deal(USDT, address(_trader), 100000 ether);
//         deal(LINK, address(_trader), 100000 ether);

//         // Deploy bot
//         uint256 assetAAmount = 10000 ether + 50 ether;
//         uint32 traderId = doppiFactory.deployTraderBot(defaultWeights);
//         traderBot = DoppiTrader(doppiFactory.traderBots(traderId));
//         usdt.approve(address(traderBot), type(uint256).max);
//         btc.approve(address(traderBot), type(uint256).max);
//         traderBot.setForwarderAddress(forwarder);
//         traderBot.start(assetAAmount, 0.1 ether);
//         vm.stopPrank(); 
//     }
// }
