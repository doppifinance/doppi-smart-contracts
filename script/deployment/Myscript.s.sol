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
import {MockOracle} from "../../src/test/MockOracle.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
import {TestParamLib} from "../../src/Library/TestParamLib.sol";

contract MyScript is Script {

    address DOPPI_OFFER = address(0xb4ED6eddc9361D164C0deDA1da5D02359f87DF18);
    address DOPPI_LP = address(0x7f6283d037d51588D74cfbD677096Cff8Be4A73f);
    address DOPPI_OFFER_ETH = address(0xA8787E6F7c796eF644F734a6F4EF23B06032E4Ee);
    address DOPPI_LP_ETH = address(0x4f912dC0a656122bAf396B1a3156f1cBBc3f5256);
    address DOPPI_CORE = address(0x0Fd25f185431480dC698Bd01DD4F288972626cdA);
    address DOPPI_OPPO = address(0x684331E18F47505aeB903A9a10dD8312142A4415);
    address DOPPI_UPKEEP = address(0xA926721fe5A3465F06Af52BCdc46F22b5fE8B103);
    address DOPPI_POINTS = address(0xc77bE67A9043d7aDE933DD5dD9d5Acc7154D90C5);
    
    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // _getDoppiPoints();
        // address bot = address(0x4F7554796137C8C9B0F76665a2e0dFD4aB1B2231);
        // _traderBotInfo(bot);
        // _getUpkeepData(bot);
        // _getBuffer(DOPPI_OFFER, DOPPI_LP);
        // _getBuffer(DOPPI_OFFER_ETH, DOPPI_LP_ETH);
        // _getTotalOrders();

        // _manipulateRealChainlink(int256(77_400 * 1e8)); 
        // _getOpportunityData();

        _updateMaxOfferDoppiOffers(DOPPI_OFFER);
        // _updateMaxOfferDoppiOffers(DOPPI_OFFER_ETH);

        
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

    function _traderBotInfo(address bot) internal view {
        DoppiTrader bot = DoppiTrader(bot);
        (uint256 totalAssetA, uint256 totalAssetB, uint256 price) = bot.getTotalBalances();
        console.log("Total Asset A:", totalAssetA);
        console.log("Total Asset B:", totalAssetB); 
        console.log("Current Price:", price);
    }

    function _getUpkeepData(address bot) internal view {

        DoppiUpkeepManager doppiUpkeepManager = DoppiUpkeepManager(DOPPI_UPKEEP);
        uint256 keepId = doppiUpkeepManager.getUpkeepIdByBot(bot);
        IAutomationRegistryConsumer.UpkeepInfo memory result = doppiUpkeepManager.getUpkeep(keepId);
        address forwarder = doppiUpkeepManager.getForwarder(keepId);
        console.log(forwarder, "Forwarder address");
        console.log(result.admin, result.balance);
        console.log(result.maxValidBlocknumber, result.paused, result.target);

        uint256 upkeepBalance = doppiUpkeepManager.getUpkeepBalance(keepId);
        console.log("Upkeep ID for bot:", keepId);
        console.log("Upkeep balance:", doppiUpkeepManager.getUpkeepBalance(keepId));
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

    function _getTotalOrders() internal view {

        DoppiCore doppiCore = DoppiCore(DOPPI_CORE);
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
        
        for (uint256 price = upperBound; price >= lowerBound; ) {
            // console.log(price, "price");
            bool isBuy = true;
            (uint256 amount, uint256 swappedAmount, uint256 outAmount) = doppiCore.opportunityBuy(price);
            
            if(amount == 0){
                isBuy = false;
                (amount, swappedAmount, outAmount) = doppiCore.opportunitySell(price);
            }
            console.log(isBuy, price, swappedAmount, outAmount);
            price -= (500 * 1e8); 
        }

        DoppiLiquidity doppiLP = DoppiLiquidity(DOPPI_LP);
        uint256 price = doppiLP.getPrice();
        console.log(price, "Current price");

        (bool upkeepNeeded, bytes memory performData) = doppiOpportunity.checkUpkeep("");
        console.log("Opportunity Upkeep needed:", upkeepNeeded);
        if (upkeepNeeded) {
            console.log("Performing upkeep for opportunity");
            // Perform the upkeep
            doppiOpportunity.performUpkeep(performData);
            console.log("Upkeep performed successfully");
        } else {
            console.log("No upkeep needed at this time");
        }

        
    }

    function _manipulateRealChainlink(int256 newPrice) internal {
        
        // Then override the feed address
        MockOracle oracle = new MockOracle(int256(100_000 * 1e8), 8);
        oracle.setPrice(newPrice);
        ConfigParam memory configLP = TestParamLib.get_configLP();
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