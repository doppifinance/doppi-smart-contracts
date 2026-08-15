// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiOffer.sol";
import "../../src/mainnet/DoppiLiquidity.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiOpportunity.sol";
// import "../../src/mainnet/DoppiUpkeepManager.sol";
import "../../src/mainnet/DoppiTrader.sol";
import "../../src/mainnet/private/DoppiSimpleTrader.sol";
// import "../../src/mainnet/DoppiPoints.sol";
import "../../src/mainnet/DoppiClaim.sol";
import "../../src/mainnet/DoppiReferral.sol";
import "../../src/mainnet/private/DoppiGridTrader.sol";
import {IPrivateAutomationHub} from "../../src/Interface/IPrivateAutomationHub.sol";
import {BotBillingState, PrivateBotJobIds, PrivateJobView} from "../../src/mainnet/private/PrivateAutomationHubTypes.sol";
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
    function getPointValueInUSDT(uint256 numPoints) external view returns (uint256);
}

interface IPrivateCoreStackFactory {
    function privateAutomationHub() external view returns (address);
    function botPrivateCore(address bot) external view returns (address);
    function botPrivateOpportunity(address bot) external view returns (address);
    function botPrivateLiquidity(address bot) external view returns (address);
    function setLPConfig(ConfigParam calldata _lpConfig) external;
    function setPrivateLiquidityConfig(address bot) external;
}


contract MyLocalScript is Script {

    MockOracle oracle;

    function run() external {
        
        
        address doppiOffer_ETH = address(0xb7Fda4264533929945A1B21A32CdcfD405ac5244);
        // address doppiLP_ETH = address(0x3f3284764A9bD533E0a372Da38Ea936D7D30f897);
        address doppiLP = address(0xb843CCb0b66F30F69a816dD8D221413F4F446295);
        address doppiCore = address(0xD166769b15298700f55e360E4BE0C2a24E77e5EA);
        address doppiOpportunity = address(0x09CBA9a411A52ea7447fe7Ec993E35b8Cd10FD69);
        address doppiClaimAdr = address(0x858B26c86E40F75fF69B6d9f571f920d9F2300d7);
        address privateHub = address(0x3d3D4A7DC7e5d5728fC170Cbfde12D2F2ebccBB7);
        
        // uint256 pointValueInUSDT = IPrivateAutomationHubDebug(privateHub).getPointValueInUSDT(107);
        // console.log(pointValueInUSDT, "pointValueInUSDT for 107 points");

        // DoppiClaim claim = DoppiClaim(doppiClaimAdr);
        // console.log(claim.paused(), "claim.paused()");

        // DoppiOffer offer = DoppiOffer(doppiOffer_ETH);
        // DualAssetOffer[] memory buyoffers = offer.getBuyOffers(1);
        // console.log(buyoffers.length, "buyoffers length");
        // uint256 buffer = offer.getOneDayBuffer(1_842 * 1e8, true);

        // console.log(buffer, "buffer");
        
        // (DualAssetOffer[] memory buyoffers, DualAssetOffer[] memory selloffers) = offer.getAllOffers(1);
        // console.log("Buy Offers Count:", buyoffers.length);
        // for (uint256 i = 0; i < buyoffers.length; i++) {
        //     console.log("Buy Offer", i, "APR:", buyoffers[i].apr);
        // }

        
        DoppiLiquidity lp = DoppiLiquidity(doppiLP);
        console.log("Price:", lp.getPrice());
    
        _manipulateRealChainlink(doppiLP, int256(63600 * 1e8), address(0x8Ab84962B15FEE0C95CD10cEED2219432Dcc76f8));
        // _manipulateRealChainlink(doppiLP_ETH, int256(2_069 * 1e8), address(0xf512De86d7c347b19483EDb08048ADA34551F74E));

        DoppiCore core = DoppiCore(doppiCore);
        console.log(core.emergencyMode(), "core.emergencyMode()");
        console.log(core.paused(), "core.paused()");
        console.log(DoppiLiquidity(address(core.doppiLP())).getPrice(), "doppiLP.getPrice()");
        console.log(core.UPKEEPS_PER_CHECK(), "core.upkeeps_per_check()");
        console.log(core.nextPositionId(1), "core.nextPositionId()");
        console.log(core.nextProcessId(1), "core.nextProcessId()");

        (
            uint256 currentDeposits,
            uint256 maxDepositAmount,
            uint256 availableCapacity
        ) = lp.getPoolCapacityInfo(true);
        console.log(currentDeposits, "lp.getPoolCapacityInfo(true).currentDeposits");
        console.log(maxDepositAmount, "lp.getPoolCapacityInfo(true).maxDepositAmount");
        console.log(availableCapacity, "lp.getPoolCapacityInfo(true).availableCapacity");

        (
            currentDeposits,
            maxDepositAmount,
            availableCapacity
        ) = lp.getPoolCapacityInfo(false);

        console.log(currentDeposits, "lp.getPoolCapacityInfo(false).currentDeposits");
        console.log(maxDepositAmount, "lp.getPoolCapacityInfo(false).maxDepositAmount");
        console.log(availableCapacity, "lp.getPoolCapacityInfo(false).availableCapacity");
        
        // console.log("Price:", lp.getPrice());

        // (, , uint256 availableCapacity) = lp.getPoolCapacityInfo(true);
        // console.log(availableCapacity, "availableCapacity");
        
        // _checkSharedUpkeep(doppiCore, doppiOpportunity, doppiLP);

        // IPrivateCoreStackFactory factory = IPrivateCoreStackFactory(address(0x4a0dEFe3aF7e5Bd2500aDe85Ba37A743801e9D84)); 
        // IPrivateAutomationHubDebug hub = IPrivateAutomationHubDebug(address(factory.privateAutomationHub()));
        // console.log(hub.minCreditThreshold(), "minCreditThreshold");
        // address bot2 = address(0xca7219123f3d60aBF14DB1B61F37AF030C114d16);
        // address bot1 = address(0x41DAfaBbAa45C6f35aCE79E901FF0534B0fEd317); // private

        // DoppiTrader traderCommonBot = DoppiTrader(address(0xf9E700F3178C7401DC798ff63Dda40dc202311BE));
        // _debugTraderCheckUpkeep(traderCommonBot);
        
        // // DoppiTrader traderBot = DoppiTrader(bot);
        // (uint256 totalAssetA, uint256 totalAssetB, uint256 price2) = traderCommonBot.getTotalBalances();
        // console.log("TraderBot Total Asset A:", totalAssetA);
        // console.log("TraderBot Total Asset B:", totalAssetB);
        // console.log("TraderBot Current Price:", price2);
        // (uint256 multiplierA, uint256 multiplierB, ,) = traderCommonBot.getPerformanceMultipliers();
        // console.log("TraderBot Performance Multiplier A:", multiplierA);
        // console.log("TraderBot Performance Multiplier B:", multiplierB);
        

        // DoppiSimpleTrader traderBot = DoppiSimpleTrader(address(0x34E4F0b5B5853Ee2CeEb41BCC414aa615E8Fa5ff));
        // console.log(traderBot.firstOrderScaleBps(), "firstOrderScaleBps");
        // console.log(traderBot.orderCountMultiplierBps(), "orderCountMultiplierBps");
        // console.log(traderBot.maxOrderPerRoundA(), "maxOrderPerRoundA");
        // console.log(traderBot.maxOrderPerRoundB(), "maxOrderPerRoundB");

        // (uint256 avgBuyEntryPrice, uint256 avgSellEntryPrice) = traderBot.getAveragePrices();
        // console.log(avgBuyEntryPrice, avgSellEntryPrice, "Average");
        // console.logInt(traderBot.get_unrealized_PNL());
        // (DoppiSimpleTrader.StrikePnLView[] memory items, int256 totalPnl, uint256 currentPrice) = traderBot.getStrikePnL(false);
        // console.log("Current Price:", currentPrice);
        // console.logInt(totalPnl);
        // for (uint256 i = 0; i < items.length; i++) {
        //     console.log("Strike:", items[i].strikePrice);
        //     console.logInt(items[i].pnl);
        //     console.log("currentValue:", items[i].currentValue, "entryValue:", items[i].entryValue);
        //     console.log("averageCost:", items[i].averageCost);
        //     console.log("unwindAmount:", items[i].unwindAmount);
        // }

        
        // DoppiSimpleTrader traderSimpleBot = DoppiSimpleTrader(address(0x34E4F0b5B5853Ee2CeEb41BCC414aa615E8Fa5ff));
        // console.log("TraderBot Performance Multipliers:");
        // (uint256 multiplierA, uint256 multiplierB, uint256 unitPriceA,) = traderBot.getPerformanceMultipliers();
        // (uint256 balA, uint256 balB, ) = traderBot.getTotalBalances();
        // uint256 costBasis = traderBot.costBasis();
        // uint256 costBasisB = traderBot.costBasisB();
        
        // console.log("Total Balances A:", balA, "B:", balB);
        // console.log("Cost Basis A:", costBasis, "B:", costBasisB);

        // console.log("Multiplier A:", multiplierA);
        // console.log("Multiplier B:", multiplierB);
        // console.log("Unit Price A:", unitPriceA);

        // DoppiGridTrader traderGridBot = DoppiGridTrader(address(0x46A8904211993824973bf970f3e2fD4347561deB));
        // // DoppiGridTrader.EpochZoneInfo[] memory zones = traderGridBot.getEpochZoneInfo();
        // // _display(zones, 0);
        // // _display(zones, 1);
        // // _display(zones, 2);
        // // _display(zones, 3);
        // // _display(zones, 4);

        
        // (DoppiSimpleTrader.StrikePnLView[] memory items, int256 totalPnl, uint256 currentPrice) = traderGridBot.getStrikePnL(true);
        // console.log("Current Price:", currentPrice);
        // console.log("Total PnL:", totalPnl);
        // for (uint256 i = 0; i < items.length; i++) {

        //     console.log("Strike:", items[i].strikePrice, "average Price:", items[i].averageCost);
        //     console.log("currentValue:", items[i].currentValue, "entryValue:", items[i].entryValue);
        //     console.log("unwindAmount:", items[i].unwindAmount);
        //     console.logInt(items[i].pnl);
        // }

        // (uint256 lower, uint256 upper) = traderGridBot.getLowerUpperBound();
        // console.log("Lower Bound:", lower, "Upper Bound:", upper);
        // for (uint256 i = lower; i <= upper;) {
        //     console.log("Strike:", i);
        //     uint256 buyOpportunity = traderGridBot.getOpportunityInfo(true, i);
        //     uint256 sellOpportunity = traderGridBot.getOpportunityInfo(false,i);
        //     uint256 unWindBuyCostA = traderGridBot.unWindBuyCostA(i);
        //     uint256 unWindSellCostB = traderGridBot.unWindSellCostB(i);
        //     uint256 unWindBuy = traderGridBot.unWindBuy(i);
        //     uint256 unWindSell = traderGridBot.unWindSell(i);
        //     uint256 costForA = unWindBuy == 0 ? 0 : unWindBuyCostA * 1e8 / unWindBuy;
        //     uint256 costForB = unWindSellCostB == 0 ? 0 : unWindSell * 1e8 / unWindSellCostB;
        //     console.log("unWindBuyCostA, unWindSellCostB", unWindBuyCostA, unWindSellCostB);
        //     console.log("costForA, costForB", costForA, costForB);
        //     console.log("unWindBuy, unWindSell", unWindBuy, unWindSell);
        //     console.log("Strike, Buy Sell Opportunity:", i, buyOpportunity, sellOpportunity);
        //     i=i+ (500*1e8);
        // }

        // // _traderBotInfo(bot);
        // address bot1 = address(0x64D2Aa585bCd4b80819C1a56FA0BA444812C18E7); // private
        // // _manipulateRealChainlinkByFactory(factory, bot1, int256(63_900 * 1e8));
        // _privateBotInfo(factory, bot1);
        

        // address privateLiquidityAddr = factory.botPrivateLiquidity(bot1);
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

    function _display(DoppiGridTrader.EpochZoneInfo[] memory zones, uint256 index) internal view {
        console.log(zones[index].zone, "zone"); // 1
        console.log(zones[index].buyStrike, "buyStrike");
        console.log(zones[index].sellStrike, "sellStrike");
        console.log(zones[index].originalBuyAmount, "originalBuyAmount");
        console.log(zones[index].originalSellAmount, "originalSellAmount");
        console.log(zones[index].remainingBuyOpportunity, "remainingBuyOpportunity");
        console.log(zones[index].remainingSellOpportunity, "remainingSellOpportunity");
        // console.log(zones[index].pendingBuyUnwind, "pendingBuyUnwind");
        // console.log(zones[index].pendingSellUnwind, "pendingSellUnwind");
    }

    function _debugTraderCheckUpkeep(DoppiTrader traderBot) internal view {
        address bot = address(traderBot);
        DoppiCore core = DoppiCore(address(traderBot.doppiCore()));
        DoppiLiquidity lp = DoppiLiquidity(address(traderBot.doppiLP()));
        DoppiOffer offer = DoppiOffer(address(traderBot.impliedVol()));

        console.log("========== DoppiTrader checkUpkeep debug ==========");
        console.log(bot, "bot");
        console.log(traderBot.s_forwarderAddress(), "s_forwarderAddress");
        console.log(traderBot.paused(), "bot.paused()");
        console.log(core.paused(), "core.paused()");

        uint256 price = lp.getPrice();
        console.log(price, "lp.getPrice()");

        uint256 buyPos = core.getBuyPositionCount(bot);
        uint256 sellPos = core.getSellPositionCount(bot);
        console.log(buyPos, "core.getBuyPositionCount(bot)");
        console.log(sellPos, "core.getSellPositionCount(bot)");

        address assetA = address(traderBot.assetA());
        address assetB = address(traderBot.assetB());
        uint256 balA = IERC20(assetA).balanceOf(bot);
        uint256 balB = IERC20(assetB).balanceOf(bot);
        (uint256 undoA, uint256 undoB) = traderBot.undoStat();

        uint256 availableA = balA > undoA ? balA - undoA : 0;
        uint256 availableB = balB > undoB ? balB - undoB : 0;

        console.log(balA, "assetA.balanceOf(bot)");
        console.log(balB, "assetB.balanceOf(bot)");
        console.log(undoA, "undoStat.undo_assetA");
        console.log(undoB, "undoStat.undo_assetB");
        console.log(availableA, "availableA(balanceA-undoA)");
        console.log(availableB, "availableB(balanceB-undoB)");

        uint8 day = traderBot.traderDefaultDay();
        DualAssetOffer memory buyOffer = offer.getSingleOffer(true, day, 0, price);
        DualAssetOffer memory sellOffer = offer.getSingleOffer(false, day, 0, price);
        console.log(day, "traderDefaultDay");
        console.log(buyOffer.apr, "buyOffer.apr");
        console.log(sellOffer.apr, "sellOffer.apr");

        (, , uint256 capBuy) = lp.getPoolCapacityInfo(true);
        (, , uint256 capSell) = lp.getPoolCapacityInfo(false);
        console.log(capBuy, "lp.availableCapacity.buy");
        console.log(capSell, "lp.availableCapacity.sell");
        console.log(core.minOrderA(), "core.minOrderA");
        console.log(core.minOrderB(), "core.minOrderB");

        (bool upkeepNeeded, bytes memory performData) = traderBot.checkUpkeep("0x");
        console.log("TraderBot checkUpkeep needed:", upkeepNeeded);
        console.log(performData.length, "performData.length");
        console.log("==================================================");
    }

    // function _displayNew(DoppiGridTrader.EpochZoneCurrentInfo[] memory epochZones,
    //         DoppiGridTrader.ZonePendingUnwindInfo[] memory pendingByZone,
    //         DoppiGridTrader.UnwindBucketInfo[] memory buyUnwindBuckets,
    //         DoppiGridTrader.UnwindBucketInfo[] memory sellUnwindBuckets) 
    // internal view {
        
    //     for (uint256 i = 0; i < epochZones.length; i++) {
    //         console.log(epochZones[i].zone, "zone");
    //         console.log(epochZones[i].buyStrike, "buyStrike");
    //         console.log(epochZones[i].sellStrike, "sellStrike");
    //         console.log(epochZones[i].originalBuyAmount, "originalBuyAmount");
    //         console.log(epochZones[i].originalSellAmount, "originalSellAmount");
    //         console.log(epochZones[i].remainingBuyOpportunity, "remainingBuyOpportunity");
    //         console.log(epochZones[i].remainingSellOpportunity, "remainingSellOpportunity");
            
    //     }

    //     for (uint256 i = 0; i < pendingByZone.length; i++) {
    //         console.log(pendingByZone[i].zone, "zone");
    //         console.log(pendingByZone[i].pendingBuyUnwind, "pendingBuyUnwind");
    //         console.log(pendingByZone[i].pendingSellUnwind, "pendingSellUnwind");           
    //     }

    //     for (uint256 i = 0; i < buyUnwindBuckets.length; i++) {
    //         console.log(buyUnwindBuckets[i].strike, "strike");
    //         console.log(buyUnwindBuckets[i].amount, "amount");
    //         console.log(buyUnwindBuckets[i].cost, "cost");
    //     }

    //     for (uint256 i = 0; i < sellUnwindBuckets.length; i++) {
    //         console.log(sellUnwindBuckets[i].strike, "strike");
    //         console.log(sellUnwindBuckets[i].amount, "amount");
    //         console.log(sellUnwindBuckets[i].cost, "cost");          
    //     }
        
    // }

    function _manipulateRealChainlink(address _doppiLP, int256 newPrice, address oracleAddress) internal {
        
        MockOracle _oracle = MockOracle(oracleAddress);
        DoppiLiquidity lp = DoppiLiquidity(_doppiLP);

        (
            ,
            address currentRouter,
            uint24 poolFee,
            uint24 slippage,
            uint24 liquidityFee,
            uint8 priceDecimals,
            uint256 decimals,
            address v3Pool,
            uint32 twapDuration,
            uint24 maxDepositPercentage,
            uint32 maxDelay,
            uint256 maxSwap,
            uint256 priceGap,
            uint8 unwindGapMultiplier
        ) = lp.config();

        ConfigParam memory configLP = ConfigParam({
            chainLinkFeed: address(_oracle),
            router: currentRouter,
            poolFee: poolFee,
            slippage: slippage,
            liquidityFee: liquidityFee,
            priceDecimals: priceDecimals,
            decimals: decimals,
            v3Pool: v3Pool,
            twapDuration: twapDuration,
            maxDepositPercentage: maxDepositPercentage,
            maxDelay: maxDelay,
            maxSwap: maxSwap,
            priceGap: priceGap,
            unwindGapMultiplier: unwindGapMultiplier
        });

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        _oracle.setPrice(newPrice);
        lp.setConfig(configLP); 
        vm.stopBroadcast();
        console.log("MockOracle latestAnswer:", uint256(_oracle.latestAnswer()));
        console.log("Updated Price:", lp.getPrice());

        console.log("Chainlink feed updated to MockOracle with price:", newPrice);
        
    }

    function _manipulateRealChainlinkByFactory(IPrivateCoreStackFactory factory,  address bot, int256 newPrice, address oracleAddress) internal {
        
        MockOracle _oracle = MockOracle(oracleAddress);
        address privateLiquidityAddr = factory.botPrivateLiquidity(bot);

        DoppiLiquidity lp = DoppiLiquidity(privateLiquidityAddr);

        (
            ,
            address currentRouter,
            uint24 poolFee,
            uint24 slippage,
            uint24 liquidityFee,
            uint8 priceDecimals,
            uint256 decimals,
            address v3Pool,
            uint32 twapDuration,
            uint24 maxDepositPercentage,
            uint32 maxDelay,
            uint256 maxSwap,
            uint256 priceGap,
            uint8 unwindGapMultiplier
        ) = lp.config();

        ConfigParam memory configLP = ConfigParam({
            chainLinkFeed: address(_oracle),
            router: currentRouter,
            poolFee: poolFee,
            slippage: slippage,
            liquidityFee: liquidityFee,
            priceDecimals: priceDecimals,
            decimals: decimals,
            v3Pool: v3Pool,
            twapDuration: twapDuration,
            maxDepositPercentage: maxDepositPercentage,
            maxDelay: maxDelay,
            maxSwap: maxSwap,
            priceGap: priceGap,
            unwindGapMultiplier: unwindGapMultiplier
        });

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        _oracle.setPrice(newPrice);
        factory.setLPConfig(configLP);
        factory.setPrivateLiquidityConfig(bot);
        vm.stopBroadcast();
        console.log("MockOracle latestAnswer:", uint256(_oracle.latestAnswer()));
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

    function _checkSharedUpkeep(address core, address oppo, address lp) internal view {
        DoppiCore doppiCore = DoppiCore(core);
        (bool upkeepNeeded, bytes memory performData) = doppiCore.checkUpkeep("");
        console.log("Shared Core Upkeep Needed:", upkeepNeeded);
        // console.log("Shared Perform Data Length:", performData.length);

        DoppiOpportunity doppiOpportunity = DoppiOpportunity(oppo);
        (bool oppoUpkeepNeeded, bytes memory oppoPerformData) = doppiOpportunity.checkUpkeep("");
        console.log("Shared Opportunity Upkeep Needed:", oppoUpkeepNeeded);
        
        DoppiLiquidity doppiLP = DoppiLiquidity(lp);
        (bool lpUpkeepNeeded, bytes memory lpPerformData) = doppiLP.checkUpkeep("");
        console.log("Shared Liquidity Upkeep Needed:", lpUpkeepNeeded);
    }


    function _privateBotInfo(IPrivateCoreStackFactory factory, address bot) internal view {
        address privateCoreAddr = factory.botPrivateCore(bot);
        address privateOpportunityAddr = factory.botPrivateOpportunity(bot);
        address privateLiquidityAddr = factory.botPrivateLiquidity(bot);

        console.log("PrivateCore Address:", privateCoreAddr);
        console.log("PrivateOpportunity Address:", privateOpportunityAddr);
        console.log("PrivateLiquidity Address:", privateLiquidityAddr);

        

        DoppiCore privateCore = DoppiCore(privateCoreAddr);
        DoppiOpportunity privateOpportunity = DoppiOpportunity(privateOpportunityAddr);
        (bool upkeepNeeded, bytes memory performData) = privateOpportunity.checkUpkeep("");
        console.log("PrivateOpportunity Upkeep Needed:", upkeepNeeded);
        
        console.log(address(privateOpportunity.doppiLP()), "privateOpportunity doppiLP Address:");
        console.log(address(privateLiquidityAddr), "PrivateCore PrivateLiquidity Address:");
        
        DoppiLiquidity privateLiquidity = DoppiLiquidity(address(privateOpportunity.doppiLP()));


        (uint256 lowerBound, uint256 upperBound) = privateOpportunity.getLowerUpperBound();
        _displayBound(privateCore, lowerBound, upperBound);

        (lowerBound, upperBound) = privateOpportunity.getLowerUpperBound();
        _displayBoundLP(privateLiquidity, lowerBound, upperBound);

        uint256 price = privateLiquidity.getPrice();
        console.log("PrivateLiquidity Current Price:", price);

        uint256 oneDayMove = privateCore.doppiOffer().getOneDayBuffer(price, false);
        console.log("PrivateCore One Day Move:", oneDayMove);
        
        
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

        DoppiTrader traderBot = DoppiTrader(bot);
        (uint256 totalAssetA, uint256 totalAssetB, uint256 price2) = traderBot.getTotalBalances();
        console.log("TraderBot Total Asset A:", totalAssetA);
        console.log("TraderBot Total Asset B:", totalAssetB);
        console.log("TraderBot Current Price:", price2);
        (uint256 multiplierA, uint256 multiplierB, ,) = traderBot.getPerformanceMultipliers();
        console.log("TraderBot Performance Multiplier A:", multiplierA);
        console.log("TraderBot Performance Multiplier B:", multiplierB);
    }

    function _runPrivateAutomationHubUpkeep(IPrivateCoreStackFactory factory) internal {
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

    function _getBotBilling(IPrivateCoreStackFactory factory, address bot) internal view {
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

    function _displayBound(DoppiCore doppiCore, uint256 lowerBound, uint256 upperBound) internal view {
        IDoppiOpportunity opportunityStore = doppiCore.doppiOpportunity();
        
        for (uint256 price = upperBound; price >= lowerBound; ) {
            console.log(price, "strike price");
            bool isBuy = true;
            OpportunityOrders memory order = opportunityStore.getBuyOpportunity(price);
            OpportunityOrders memory orderSell = opportunityStore.getSellOpportunity(price);

            console.log("Buy Opportunity:", order.amount, order.swappedAmount, order.outAmount);
            console.log("Sell Opportunity:", orderSell.amount, orderSell.swappedAmount, orderSell.outAmount);
            price -= (500 * 1e8); 
        }

    }

    function _displayBoundLP(DoppiLiquidity doppiLP, uint256 lowerBound, uint256 upperBound) internal view {
        
        if(lowerBound == 0 && upperBound == 0) return;
        for (uint256 price = upperBound; price >= lowerBound; ) {
            uint256 amount = doppiLP.amountToBuy(price);
            uint256 amountSell = doppiLP.amountToSell(price);
            console.log("price, amount, amountSell", price, amount, amountSell);
            price -= (500 * 1e8); 
        }

    }
    
}