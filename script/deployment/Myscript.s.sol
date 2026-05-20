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
import {MockOracle} from "../../src/test/MockOracle.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
import {TestParamLib} from "../../src/Library/TestParamLib.sol";
import {DALiquidityLib} from "../../src/Library/DALiquidityLib.sol";
import {AggregatorV3Interface} from "../../src/Interface/AggregatorV3Interface.sol";


contract MyScript is Script {

    address DOPPI_OFFER = address(0x418f56B5e660882ae00145fc6ab200AfEE9e0595);
    address DOPPI_LP = address(0x2deB22F6fCFE371c5024b52045850d9B32d33Bcd);
    address DOPPI_OFFER_ETH = address(0x42d7C78839Ff39D797d08Fde1Ae3f1433035519A);
    address DOPPI_LP_ETH = address(0x9b0e4260311a8874a0f7EeDB9545e93960e113c6);
    address DOPPI_CORE = address(0xa2d49d1c8b89Cd0b11AeA445887661CDcF9e9611);
    address DOPPI_CORE_ETH = address(0x8532f74529F4295f882f73Cd3D3cCfBcD6900e08);
    address DOPPI_OPPO = address(0x66C4e3c5A73d0fF469462a7fE7D740DF972CbB6D);
    address DOPPI_UPKEEP = address(0x72F662ebf6d2E4c89BDD6f5Ca2EfAaBebf6A715a);
    address DOPPI_REF = address(0xAA9CBB0221638720F3b73C50DFC08Ed1E6e878b3);
    address DOPPI_POINTS = address(0x656AC29F67fd8FA3f273f4594E9B07ee53eC8D5D);
    
    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);
        

        AggregatorV3Interface chainLinkFeed = AggregatorV3Interface(address(0xca236E327F629f9Fc2c30A4E95775EbF0B89fac8));
        uint256 price = DALiquidityLib.getPrice(chainLinkFeed, 10 minutes);
        console.log("Price from DALiquidityLib:", block.timestamp, price);

        // _getDoppiPoints();
        address bot = address(0x1E389F00c11D6B6721D8F703e2D9eCb38F54BB95);
        // _traderBotInfo(bot);
        // _getDoppiTraderUnwindData(bot);
        // console.log("-----", block.timestamp, block.number);

        _getUpkeepData(bot);
        // _getBuffer(DOPPI_OFFER, DOPPI_LP);
        // _getBuffer(DOPPI_OFFER_ETH, DOPPI_LP_ETH);
        // _getTotalOrders(DOPPI_CORE);
        // _getTotalOrders(DOPPI_CORE_ETH);

        // _manipulateRealChainlink(int256(79_400 * 1e8)); 
        // _getOpportunityData();

        // _updateMaxOfferDoppiOffers(DOPPI_OFFER);
        // _updateMaxOfferDoppiOffers(DOPPI_OFFER_ETH);

        // _setMinOrders(DOPPI_CORE);

        // _getDoppiReferral();

        // _getDoppiLP(DOPPI_LP);
        // _getDoppiLPUnwindData(DOPPI_LP);

        // DoppiTraderFactory factory = DoppiTraderFactory(address(0x095e4C543839c3C0403DbC5AA8acC259689A419C)); 
        // console.log(factory.traderBotImplementation(), "Trader Bot Implementation Address");
        

        
        vm.stopBroadcast();
    }

    function _getDoppiPoints() internal view {
        
        address trader = address(0xB91a71FA558ec371eA09477c1D9f46E6AbA60719); 
        address bot1 = address(0x0cEf2894D5aE740016a9b1ad3c40e6A2986d8600); 
        address bot2 = address(0x89CcbcC1e1260cf52190FdB7b979461cd0066dd2);
        address bot3 = address(0x48034E691f1F9D1919259Cf5FFc636F694462755);

        DoppiPoints doppiPoints = DoppiPoints(DOPPI_POINTS);
        (uint256 totalClaimedPoint, uint256 readyPoint, uint256 currentMonthPoint) = doppiPoints.getAllPointData(trader);
        (uint256 totalClaimedPointBot1, uint256 readyPointBot1, uint256 currentMonthPointBot1) = doppiPoints.getAllPointData(bot1);
        (uint256 totalClaimedPointBot2, uint256 readyPointBot2, uint256 currentMonthPointBot2) = doppiPoints.getAllPointData(bot2);
        (uint256 totalClaimedPointBot3, uint256 readyPointBot3, uint256 currentMonthPointBot3) = doppiPoints.getAllPointData(bot3);

        uint256 totalVolume = doppiPoints.totalVolume();
            
        console.log("Total Claimed Point:", totalClaimedPoint);
        console.log("Ready Point:", readyPoint); 
        console.log("Current Month Point:", currentMonthPoint);
        
        // console.log("Total Claimed Point (Bot1):", totalClaimedPointBot1);
        // console.log("Ready Point (Bot1):", readyPointBot1); 
        console.log("Current Month Point (Bot1):", currentMonthPointBot1);
        
        // console.log("Total Claimed Point (Bot2):", totalClaimedPointBot2);
        // console.log("Ready Point (Bot2):", readyPointBot2); 
        console.log("Current Month Point (Bot2):", currentMonthPointBot2);

        // console.log("Total Claimed Point (Bot3):", totalClaimedPointBot3);
        // console.log("Ready Point (Bot3):", readyPointBot3); 
        console.log("Current Month Point (Bot3):", currentMonthPointBot3);

        console.log("Total Volume:", totalVolume);

    }

    function _getDoppiReferral() internal view {
        
        // address trader = address(0xB91a71FA558ec371eA09477c1D9f46E6AbA60719); 
        // address bot1 = address(0x0cEf2894D5aE740016a9b1ad3c40e6A2986d8600); 
        // address bot2 = address(0x89CcbcC1e1260cf52190FdB7b979461cd0066dd2);
        // address bot3 = address(0x48034E691f1F9D1919259Cf5FFc636F694462755);

        DoppiReferral doppiReferral = DoppiReferral(DOPPI_REF);
        (uint24 effectiveMonthId0, uint256 minL2_0, uint256 minL3_0) = doppiReferral.getMinVolumeCheckpoint(0);
        (uint24 effectiveMonthId1, uint256 minL2_1, uint256 minL3_1) = doppiReferral.getMinVolumeCheckpoint(1);
        // (uint24 effectiveMonthId2, uint256 minL2_2, uint256 minL3_2) = doppiReferral.getMinVolumeCheckpoint(2);
        console.log("Level 2 Min Volume Checkpoint:", effectiveMonthId0, minL2_0);
        console.log("Level 3 Min Volume Checkpoint:", effectiveMonthId1, minL3_1);

        (uint16 level1Bps, uint16 level2Bps, uint16 level3Bps) = doppiReferral.getRatesForMonth(effectiveMonthId1);
        console.log("Referral rates for month", level1Bps, level2Bps, level3Bps);


        DoppiPoints doppiPoints = DoppiPoints(DOPPI_POINTS);
        console.log("Current Month ID:", doppiPoints.getCurrentMonthId());


        // console.log("Level 3 Min Volume Checkpoint:", effectiveMonthId2, minL3_2);
        


    }

    function _traderBotInfo(address bot) internal view {
        DoppiTrader bot = DoppiTrader(bot);
        (uint256 totalAssetA, uint256 totalAssetB, uint256 price) = bot.getTotalBalances();
        console.log("Total Asset A:", totalAssetA);
        console.log("Total Asset B:", totalAssetB); 
        console.log("Current Price:", price);
        bot = DoppiTrader(address(0x062eA0062499455765241b1fC2bBdE4B9405B6B2));
        console.log("-----", bot.owner());
        
    }

    function _getUpkeepData(address bot) internal {

        DoppiUpkeepManager doppiUpkeepManager = DoppiUpkeepManager(DOPPI_UPKEEP);
        uint256 keepId = doppiUpkeepManager.getUpkeepIdByBot(bot);
        IAutomationRegistryConsumer.UpkeepInfo memory result = doppiUpkeepManager.getUpkeep(keepId);
        address forwarder = doppiUpkeepManager.getForwarder(keepId);
        console.log(forwarder, "Forwarder address");
        console.log(result.admin, result.balance);
        console.log(result.maxValidBlocknumber, block.timestamp, result.paused, result.target);
        console.log("Paused:", result.paused);
        console.log("Execute Gas:", result.executeGas);

        uint256 upkeepBalance = doppiUpkeepManager.getUpkeepBalance(keepId);
        console.log("Upkeep ID for bot:", keepId);
        console.log("Upkeep balance:", doppiUpkeepManager.getUpkeepBalance(keepId));

        // doppiUpkeepManager.setMaxDelay(5 days);
    }

    function _getBuffer(address doppiOfferAddress, address doppiLPAddress) internal view {

        DoppiOffer doppiOffer = DoppiOffer(doppiOfferAddress);
        DoppiLiquidity doppiLP = DoppiLiquidity(doppiLPAddress);
        uint256 price = doppiLP.getPrice();
        uint256 buyBuffer = doppiOffer.getOneDayBuffer(price, true);
        uint256 sellBuffer = doppiOffer.getOneDayBuffer(price, false);
        console.log("buyBuffer", buyBuffer);
        console.log("sellBuffer", sellBuffer);
    }

    function _setMinOrders(address _address) internal {

        DoppiCore doppiCore = DoppiCore(_address);
        doppiCore.setMinOrder(50 ether, 0.0005 ether);
        console.log(doppiCore.minOrderA(), "Min Order A");
        console.log(doppiCore.minOrderB(), "Min Order B");
    }

    function _getTotalOrders(address _address) internal view {

        DoppiCore doppiCore = DoppiCore(_address);
        console.log(doppiCore.minOrderA(), "Min Order A");
        console.log(doppiCore.minOrderB(), "Min Order B");

        uint64 length = doppiCore.getPositionLength(1);
        uint64 nextId = doppiCore.nextProcessId(1);
        uint64 end = nextId + length;
        
        if(length == 0){
            console.log("No unsettled orders");
            return;
        }
        for (uint64 i = nextId; i < end; ) {
            bool isBuy = true;
            (uint256 amount, , uint256 strikePrice, uint32 expiryTimestamp, , address owner, ,) = doppiCore.positions_buy(1, i);
            if(owner == address(0)){
                isBuy = false;
                (amount, , strikePrice, expiryTimestamp, , owner, , ) = doppiCore.positions_sell(1, i);
            }
            console.log(isBuy, amount, strikePrice, owner);
            unchecked { ++i; }
        }
        uint256 totalOrders = length - nextId + 1;
        console.log("Total Unsettled Orders", totalOrders);
    }
    
    function _getOpportunityData() internal {

        DoppiOpportunity doppiOpportunity = DoppiOpportunity(DOPPI_OPPO);
        DoppiCore doppiCore = DoppiCore(DOPPI_CORE);
        (uint256 lowerBound, uint256 upperBound) = doppiCore.getLowerUpperBound();
        console.log(lowerBound, upperBound, "lowerBound, upperBound");
        
        if(upperBound == 0){
            console.log("No orders in the book");
            return;
        }

        for (uint256 price = upperBound; price >= lowerBound; ) {
            // console.log(price, "price");
            bool isBuy = true;
            (uint256 amount, uint256 swappedAmount, uint256 outAmount) = doppiCore.opportunityBuy(price);
            console.log("Buy", price, swappedAmount, outAmount);
            (amount, swappedAmount, outAmount) = doppiCore.opportunitySell(price);
            console.log("Sell", price, swappedAmount, outAmount);
            price -= (500 * 1e8); 
        }

        DoppiLiquidity doppiLP = DoppiLiquidity(DOPPI_LP);
        uint256 price = doppiLP.getPrice();
        console.log(price, "Current price");

        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        console.log("Opportunity Upkeep needed:", upkeepNeeded);
        if (upkeepNeeded) {
            console.log("Performing upkeep for opportunity");
            // // Perform the upkeep
            // doppiOpportunity.performUpkeep(performData);
            console.log("Upkeep performed successfully");
        } else {
            console.log("No upkeep needed at this time");
        }

        
    }

    function _getDoppiLP(address lpaddress) internal {

        DoppiLiquidity doppiLP = DoppiLiquidity(lpaddress);
        uint256 price = doppiLP.getPrice();
        console.log(price, "Current price");

        uint256 maxDepositAmounts = doppiLP.getMaxDepositAmount(true);
        console.log(maxDepositAmounts, "Max deposit amounts");

        (,,,,,,,,, uint24 maxDepositPercentage,,,,) = doppiLP.config();
        console.log(maxDepositPercentage, "Max deposit percentage");

        (uint256 currentDeposits,
        uint256 maxDepositAmount,
        uint256 availableCapacity) = doppiLP.getPoolCapacityInfo(true);
        console.log(currentDeposits, maxDepositAmount, availableCapacity, "Current deposits, Max deposit amount, Available capacity");
    }

    function _getDoppiLPUnwindData(address lpaddress) internal view {

        console.log("start DoppiLPUnwindData");
        DoppiLiquidity doppiLP = DoppiLiquidity(lpaddress);
        (uint256 lowerBound, uint256 upperBound) = doppiLP.getLowerUpperBound();
        console.log(lowerBound, upperBound, "lowerBound, upperBound");
        for (uint256 price = upperBound; price >= lowerBound; ) {
            uint256 amountBuy = doppiLP.amountToBuy(price);
            uint256 amountSell = doppiLP.amountToSell(price);
            console.log(price, amountBuy, amountSell);
            price -= (500 * 1e8); 
        }
        
    }

    function _getDoppiTraderUnwindData(address traderBot) internal view {
        DoppiTrader doppiTrader = DoppiTrader(traderBot);
        (uint256 lowerBound, uint256 upperBound) = doppiTrader.getLowerUpperBound();
        
        console.log(doppiTrader.unwindGapMultiplier(), "Unwind gap multiplier");
        console.log(doppiTrader.owner(), "Owner");
        console.log(lowerBound, upperBound, "lowerBound, upperBound");
        
        if(lowerBound == 0 && upperBound == 0) {
            console.log("No active positions");
            return;
        }

        for (uint256 price = upperBound; price >= lowerBound; ) {
            uint256 unwindBuy = doppiTrader.unWindBuy(price);
            uint256 unwindSell = doppiTrader.unWindSell(price);
            console.log(price, unwindBuy, unwindSell);
            price -= (500 * 1e8); 
        }

    }

    function _manipulateRealChainlink(int256 newPrice) internal {
        
        // Then override the feed address
        MockOracle oracle = new MockOracle(int256(100_000 * 1e8), 8);
        oracle.setPrice(newPrice);
        ConfigParam memory configLP = TestParamLib.get_configLP_localhost();
        configLP.chainLinkFeed = address(oracle);
        configLP.slippage = 500; // 5% slippage for testing
        DoppiLiquidity doppiLP = DoppiLiquidity(DOPPI_LP);
        doppiLP.setConfig(configLP); 
        
    }

    function _updateMaxOfferDoppiOffers(address doppiOfferAddress) internal {
        
        DoppiOffer doppiOffer = DoppiOffer(doppiOfferAddress);
        doppiOffer.setMaxOfferAPR(30000);
        
    }
}