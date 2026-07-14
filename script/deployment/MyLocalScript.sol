// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiOffer.sol";
import "../../src/mainnet/DoppiLiquidity.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiOpportunity.sol";
import "../../src/mainnet/DoppiUpkeepManager.sol";
import "../../src/mainnet/DoppiTrader.sol";
import "../../src/mainnet/DoppiPoints.sol";
import "../../src/mainnet/DoppiReferral.sol";
import "../../src/mainnet/private/PrivateDoppiTraderFactory.sol";
import {IPrivateAutomationHub} from "../../src/Interface/IPrivateAutomationHub.sol";
import {BotBillingState, PrivateJobView} from "../../src/mainnet/private/PrivateAutomationHubTypes.sol";
import {MockOracle} from "../../src/test/MockOracle.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
import {TestParamLib} from "../../src/Library/TestParamLib.sol";
import {DALiquidityLib} from "../../src/Library/DALiquidityLib.sol";
import {AggregatorV3Interface} from "../../src/Interface/AggregatorV3Interface.sol";

interface IPrivateAutomationHubBilling is IPrivateAutomationHub {
    function getBotBilling(address bot) external view returns (BotBillingState memory);
}

interface IPrivateAutomationHubDebug is IPrivateAutomationHubBilling {
    function scanCursor() external view returns (uint256);
    function getJobIdsByBot(address bot) external view returns (PrivateBotJobIds memory jobIds);
    function getJob(uint256 jobId) external view returns (PrivateJobView memory job);
    function doppiPointsExchangeRateBps() external view returns (uint256);
    function setDoppiPointsExchangeRate(uint256 _rateBps) external;
    function minCreditThreshold() external view returns (uint256);
}


contract MyLocalScript is Script {

    MockOracle oracle;

    function run() external {
        
        // oracle = new MockOracle(int256(64300 * 1e8), 8);
        AggregatorV3Interface chainLinkFeed = AggregatorV3Interface(address(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE));
        uint256 price = DALiquidityLib.getPrice(chainLinkFeed, 3 days);
        console.log("Price from DALiquidityLib:", block.timestamp, price);

        // PrivateDoppiGridTraderFactory gridFactory = PrivateDoppiGridTraderFactory(address(0x02860A23214811C26aabaAEC3Ff4605b135C05A5)); 
        
        address doppiLP = address(0x6B0456B5552b5B3F2561923C4b33e5E766da594E);
        _manipulateRealChainlink(doppiLP, int256(63_500 * 1e8));
        DoppiLiquidity lp = DoppiLiquidity(doppiLP);
        console.log("Current Price from DoppiLiquidity:", lp.getPrice(), "Decimals:", lp.getPriceDecimals());

        // gridFactory.setConfigParam(TestParamLib.getDefaultConfigParam());
        // PrivateDoppiTraderFactory factory = PrivateDoppiTraderFactory(address(0x61423bdE0b347e619b27faBd25a0cfAE50155A22)); 
        // IPrivateAutomationHubDebug hub = IPrivateAutomationHubDebug(address(factory.privateAutomationHub()));
        // console.log(hub.minCreditThreshold(), "minCreditThreshold");
        // address bot2 = address(0xca7219123f3d60aBF14DB1B61F37AF030C114d16);
        // address bot1 = address(0x41DAfaBbAa45C6f35aCE79E901FF0534B0fEd317); // private

        // _traderBotInfo(bot);
        // _privateBotInfo(factory, bot1);
        // _runPrivateAutomationHubUpkeep(factory);
        // _getBotBilling(factory, bot1);

        
        // PrivateBotJobIds memory jobId = hub.getJobIdsByBot(bot1);
        // console.log("Doppi Points Exchange Rate Bps:", hub.doppiPointsExchangeRateBps());

        // console.log("jobId:", jobId.coreJobId);
        // PrivateJobView memory job = hub.getJob(jobId.coreJobId);
        // console.log(job.failCount, "failCount core job");
        // console.log(job.gasLimitHint, "gasLimitHint core job");
        
        // job = hub.getJob(jobId.traderJobId);
        // console.log(job.failCount, "failCount trader job");
        // console.log(job.gasLimitHint, "gasLimitHint trader job");

        
    }

    function _manipulateRealChainlink(address _doppiLP, int256 newPrice) internal {
        
        MockOracle _oracle = MockOracle(address(0xa9bc57aE55EC7Ca436AA6632B6853EE75062C80E));
        _oracle.setPrice(newPrice);
        DoppiLiquidity lp = DoppiLiquidity(_doppiLP);

        ConfigParam memory configLP = TestParamLib.get_configLP_localhost();
        configLP.chainLinkFeed = address(_oracle);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        lp.setConfig(configLP); 
        vm.stopBroadcast();
        console.log("Updated Price:", lp.getPrice());

        console.log("Chainlink feed updated to MockOracle with price:", newPrice);
        
    }

    function _traderBotInfo(address bot) internal view {
        DoppiTrader traderBot = DoppiTrader(bot);
        (uint256 totalAssetA, uint256 totalAssetB, uint256 price) = traderBot.getTotalBalances();
        console.log("Total Asset A:", totalAssetA);
        console.log("Total Asset B:", totalAssetB); 
        console.log("Current Price:", price);
    }

    function _privateBotInfo(PrivateDoppiTraderFactory factory, address bot) internal view {
        address privateCoreAddr = factory.botPrivateCore(bot);
        address privateLiquidityAddr = factory.botPrivateLiquidity(bot);

        console.log("PrivateCore Address:", privateCoreAddr);
        console.log("PrivateLiquidity Address:", privateLiquidityAddr);

        if (privateCoreAddr == address(0) || privateLiquidityAddr == address(0)) {
            console.log("Private bot mappings not set in factory");
            return;
        }

        DoppiCore privateCore = DoppiCore(privateCoreAddr);
        DoppiLiquidity privateLiquidity = DoppiLiquidity(privateLiquidityAddr);

        uint256 buyCount = privateCore.getBuyPositionCount(bot);
        uint256 sellCount = privateCore.getSellPositionCount(bot);
        uint256 minOrderA = privateCore.minOrderA();
        uint256 minOrderB = privateCore.minOrderB();
        uint256 maxSwap = privateCore.maxSwap();

        console.log("PrivateCore Buy Position Count:", buyCount);
        console.log("PrivateCore Sell Position Count:", sellCount);
        console.log("PrivateCore Min Order A:", minOrderA);
        console.log("PrivateCore Min Order B:", minOrderB);
        console.log("PrivateCore Max Swap:", maxSwap);

        (uint256 lpAssetA, uint256 lpAssetB) = privateLiquidity.getBalances(bot);
        console.log("PrivateLP AssetA Balance:", lpAssetA);
        console.log("PrivateLP AssetB Balance:", lpAssetB);
    }

    function _runPrivateAutomationHubUpkeep(PrivateDoppiTraderFactory factory) internal {
        address hubAddr = factory.privateAutomationHub();
        console.log("PrivateAutomationHub Address:", hubAddr);

        if (hubAddr == address(0)) {
            console.log("PrivateAutomationHub not configured on factory");
            return;
        }

        IPrivateAutomationHubDebug hub = IPrivateAutomationHubDebug(hubAddr);
        // console.log("Hub scanCursor before:", scanCursorBefore);

        (bool upkeepNeeded, bytes memory performData) = hub.checkUpkeep("");
        console.log("Hub checkUpkeep needed:", upkeepNeeded);
        console.log("Hub performData length:", performData.length);

        if (!upkeepNeeded) {
            console.log("No eligible jobs to perform");
            return;
        }

        (uint256 nextCursor, uint256[] memory jobIds, bytes[] memory payloads) =
            abi.decode(performData, (uint256, uint256[], bytes[]));

        console.log("Decoded nextCursor:", nextCursor);
        console.log("Selected job count:", jobIds.length);
        console.log("Selected payload count:", payloads.length);

        for (uint256 i = 0; i < jobIds.length; ) {
            PrivateJobView memory beforeJob = hub.getJob(jobIds[i]);
            console.log("Before jobId:", jobIds[i]);
            console.log("Before active:", beforeJob.active);
            console.log("Before failCount:", beforeJob.failCount);
            console.log("Before lastRunAt:", uint256(beforeJob.lastRunAt));
            console.log("Before nextEligibleAt:", uint256(beforeJob.nextEligibleAt));
            unchecked { ++i; }
        }

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        hub.performUpkeep(performData);
        vm.stopBroadcast();
        console.log("Hub performUpkeep executed");

        uint256 scanCursorAfter = hub.scanCursor();
        console.log("Hub scanCursor after:", scanCursorAfter);

        for (uint256 i = 0; i < jobIds.length; ) {
            PrivateJobView memory afterJob = hub.getJob(jobIds[i]);
            console.log("After jobId:", jobIds[i]);
            console.log("After active:", afterJob.active);
            console.log("After failCount:", afterJob.failCount);
            console.log("After lastRunAt:", uint256(afterJob.lastRunAt));
            console.log("After nextEligibleAt:", uint256(afterJob.nextEligibleAt));
            unchecked { ++i; }
        }

    }

    function _getBotBilling(PrivateDoppiTraderFactory factory, address bot) internal view {
        address hubAddr = factory.privateAutomationHub();
        console.log("PrivateAutomationHub Address:", hubAddr);

        IPrivateAutomationHubBilling hub = IPrivateAutomationHubBilling(hubAddr);
        BotBillingState memory billingState = hub.getBotBilling(bot);
        console.log("Trader:", billingState.trader);
        console.log(billingState.creditBalance, "Credit Balance");
        console.log(billingState.totalGasFeePaid, "Total Gas Fee Paid");
        console.log("Low Credit Paused:", billingState.lowCreditPaused);
        console.log("Use Points:", billingState.usePoint);
        

    }


    // function _getTotalOrders(address _address) internal view {

    //     DoppiCore doppiCore = DoppiCore(_address);
    //     console.log(doppiCore.minOrderA(), "Min Order A");
    //     console.log(doppiCore.minOrderB(), "Min Order B");

    //     uint64 length = doppiCore.getPositionLength(1);
    //     uint64 nextId = doppiCore.nextProcessId(1);
    //     uint64 end = nextId + length;
    //     console.log("length:", length);

    //     if(length == 0){
    //         console.log("No unsettled orders");
    //         return;
    //     }
    //     uint256 totalOrders = 0;
    //     for (uint64 i = nextId; i < end; ) {
    //         bool isBuy = true;
    //         (uint256 amount, , uint256 strikePrice, uint32 expiryTimestamp, , address owner, ,) = doppiCore.positions_buy(1, i);
    //         if(owner == address(0)){
    //             isBuy = false;
    //             (amount, , strikePrice, expiryTimestamp, , owner, , ) = doppiCore.positions_sell(1, i);
    //         }
    //         console.log(i, amount, strikePrice, owner);
    //         totalOrders++;
    //         unchecked { ++i; }
    //     }
    //     console.log("Total Unsettled Orders", totalOrders);
    // }
    
}