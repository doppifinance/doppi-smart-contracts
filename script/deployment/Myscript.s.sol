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

    address DOPPI_OFFER = address(0x19CEAe6d9c7c19730Dcb6D88226b097DA8F13085);
    address DOPPI_LP = address(0x1B12F8dabB09e9abEfBB7A1c396f5ceB9a8D478A);
    address DOPPI_CORE = address(0x4cC96326eB2b9703c094CD8E78226881fC4eC8bc);
    address DOPPI_OPPO = address(0xCa901bb81b3467A1BF079003c9c5Bd41a4041891);
    address DOPPI_UPKEEP = address(0x84223a8a269103fB590Bf6aaDE2977a27a4CB93d);
    
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
        uint256 keepId = doppiUpkeepManager.getUpkeepIdByBot(address(0x3555B406B689B438A6CABC3Da43C6C59782cf84e));
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