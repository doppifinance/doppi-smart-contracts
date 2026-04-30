// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiOffer.sol";
import "../../src/mainnet/DoppiLiquidity.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiOpportunity.sol";
import "../../src/mainnet/DoppiUpkeepManager.sol";
import "../../src/mainnet/DoppiTrader.sol";
import {MockOracle} from "../../src/test/MockOracle.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
import {TestParamLib} from "../../src/Library/TestParamLib.sol";

contract MyScript is Script {

    address DOPPI_OFFER = address(0x083F2aFDafb76207eFFccabF7166D86504943a8E);
    address DOPPI_LP = address(0x4Dce091BdAb9CBD8eF972aca1923315F8C2be652);
    address DOPPI_CORE = address(0x0C049C1A2c8DaB66cf44e36F654e93Dd951390b2);
    address DOPPI_OPPO = address(0x3Ca7813860ef7aF2A4D42717ddBa492F967bC02f);
    address DOPPI_UPKEEP = address(0xA2918099Dd898b537EAA60476E809Bdaa849bb2a);
    
    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // address bot = address(0x4F7554796137C8C9B0F76665a2e0dFD4aB1B2231);
        // _traderBotInfo(bot);
        // _getUpkeepData(bot);
        // _getBuffer();
        // _getTotalOrders();

        _manipulateRealChainlink(int256(77_400 * 1e8)); 
        _getOpportunityData();

        
        vm.stopBroadcast();
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

    function _getBuffer() internal view {

        DoppiOffer doppiOffer = DoppiOffer(DOPPI_OFFER);
        DoppiLiquidity doppiLP = DoppiLiquidity(DOPPI_LP);
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
}