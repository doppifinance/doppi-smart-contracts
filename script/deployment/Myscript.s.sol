// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiOffer.sol";
import "../../src/mainnet/DoppiLiquidity.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiOpportunity.sol";
import "../../src/mainnet/DoppiUpkeepManager.sol";
import "../../src/mainnet/DoppiTrader.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";

contract MyScript is Script {

    address DOPPI_OFFER = address(0x17F38AB89496E10E34268bDc66ae48D50Fb4A227);
    address DOPPI_LP = address(0x4793A63Fbc11d79Bd72C362AFA5a9C04Bc55Fb65);
    address DOPPI_CORE = address(0x15c07435B0B38b075E28B1D7969e3C87FBCDDC49);
    address DOPPI_OPPO = address(0xa3A3e161b73Ec6535927E7c77b901db80B100852);
    address DOPPI_UPKEEP = address(0x0909645Fb7a98594836279d08c45C5b4f946c2A4);
    
    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // _traderBotInfo();
        _getUpkeepData();
        // _getBuffer();
        // _getTotalOrders();
        // _getOpportunityData();
        
        vm.stopBroadcast();
    }

    function _traderBotInfo() internal view {
        DoppiTrader bot = DoppiTrader(address(0x234765F220DB7F6C062Bc552AAfe0005Cc8Ce04a));
        (uint256 totalAssetA, uint256 totalAssetB, uint256 price) = bot.getTotalBalances();
        console.log("Total Asset A:", totalAssetA);
        console.log("Total Asset B:", totalAssetB); 
        console.log("Current Price:", price);
    }

    function _getUpkeepData() internal view {

        DoppiUpkeepManager doppiUpkeepManager = DoppiUpkeepManager(DOPPI_UPKEEP);
        uint256 keepId = doppiUpkeepManager.getUpkeepIdByBot(address(0x344F302F0c7609FF9526AB7ceF2a9e62d8991431));
        IAutomationRegistryConsumer.UpkeepInfo memory result = doppiUpkeepManager.getUpkeep(keepId);
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
    
    function _getOpportunityData() internal view {

        DoppiCore doppiCore = DoppiCore(DOPPI_CORE);
        uint256 lowerBound = doppiCore.lowerBound();
        uint256 upperBound = doppiCore.upperBound();
        console.log(lowerBound, upperBound);
        for (uint256 price = upperBound; price >= lowerBound; ) {
            // console.log(price, "price");
            bool isBuy = true;
            (uint256 amount, uint256 swappedAmount, uint256 outAmount) = doppiCore.opportunityBuy(price);
            
            if(amount == 0){
                isBuy = false;
                (amount, swappedAmount, outAmount) = doppiCore.opportunitySell(price);
            }
            console.log(isBuy, amount, price, outAmount);
            price -= (500 * 1e8); 
        }
        
    }
}