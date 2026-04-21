// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiOffer.sol";
import "../../src/mainnet/DoppiLiquidity.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiOpportunity.sol";
import "../../src/mainnet/DoppiTrader.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";

contract MyScript is Script {

    DoppiCore doppiCore;
    DoppiOffer doppiOffer;
    DoppiLiquidity doppiLP;
    DoppiTrader doppiTrader;

    address DOPPI_OFFER = address(0xe8e7Bb547C8E09b314C7ddDFFFaEd0652aA03ff9);
    address DOPPI_LP = address(0xc7D5CB3567CbB2f52189C64e0067Bf9B2c2ab0eB);
    address DOPPI_CORE = address(0x4Fe2973Df9c541c23Ce0C1e8752D16E797920d99);
    address DOPPI_OPPO = address(0xA5bBf8eB82EA8a0E13f6A071073f6CFD8A57fd7f);
    address DOPPI_Trader1 = address(0x3555B406B689B438A6CABC3Da43C6C59782cf84e);
    
    
    function run() external {
        
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // // Start broadcasting transactions
        // vm.startBroadcast(deployerPrivateKey);

        doppiTrader = DoppiTrader(DOPPI_Trader1);
        doppiCore = DoppiCore(DOPPI_CORE);
        doppiOffer = DoppiOffer(DOPPI_OFFER);
        doppiLP = DoppiLiquidity(DOPPI_LP);

        // _getBuffer();
        _getTotalOrders();
        _getOpportunityData();
        _getDoppiTraderUnwindData();
        _getDoppiLPUnwindData();
        
        // vm.stopBroadcast();
    }

    function _getBuffer() internal view {

        console.log("start doppiOffer buffer");
        uint256 price = doppiLP.getPrice();
        uint256 buyBuffer = doppiOffer.getOneDayBuffer(price, true);
        uint256 sellBuffer = doppiOffer.getOneDayBuffer(price, false);
        console.log("buyBuffer", buyBuffer);
        console.log("sellBuffer", sellBuffer);
    }

    function _getTotalOrders() internal view {

        console.log("start doppi core orders");
        uint64 length = doppiCore.getPositionLength(1);
        uint64 nextId = doppiCore.nextProcessId(1);
        uint64 nextPositionId = doppiCore.nextPositionId(1);
        
        console.log(length, nextId, nextPositionId, "length, nextId");
        uint64 end = nextId + length;
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
        uint256 totalOrders = nextPositionId - nextId;
        console.log("Total Unsettled Orders", totalOrders);
    }
    
    function _getOpportunityData() internal view {

        console.log("start OpportunityData");
        (uint256 lowerBound, uint256 upperBound) = doppiCore.getLowerUpperBound();
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

    function _getDoppiTraderUnwindData() internal view {

        console.log("start DoppiTraderUnwindData");
        uint256 lowerBound = doppiTrader.lowerBound();
        uint256 upperBound = doppiTrader.upperBound();
        console.log(lowerBound, upperBound);
        for (uint256 price = upperBound; price >= lowerBound; ) {
            bool isBuy = true;
            uint256 amount = doppiTrader.unWindBuy(price);
            if(amount == 0){
                isBuy = false;
                amount = doppiTrader.unWindSell(price);
            }
            (uint256 undo_assetB, uint256 undo_assetA) = doppiTrader.undoStat();
            
            console.log(isBuy, amount, undo_assetB, undo_assetA);
            price -= (500 * 1e8); 
        }
        
    }

    function _getDoppiLPUnwindData() internal view {

        console.log("start DoppiLPUnwindData");
        uint256 lowerBound = doppiLP.lowerBound();
        if(lowerBound == 0) {
            lowerBound = 80000 * 1e8;
        }
        uint256 upperBound = doppiLP.upperBound();
        console.log(lowerBound, upperBound);
        upperBound += 1000 * 1e8;
        lowerBound -= 1000 * 1e8;
        for (uint256 price = upperBound; price > lowerBound; ) {
            bool isBuy = true;
            uint256 amount = doppiLP.amountToBuy(price);
            if(amount == 0){
                isBuy = false;
                amount = doppiLP.amountToSell(price);
            }
            console.log(isBuy, price, amount);
            price -= (500 * 1e8); 
        }
        
    }
}