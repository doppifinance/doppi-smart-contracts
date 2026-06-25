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
import {MockOracle} from "../../src/test/MockOracle.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
import {TestParamLib} from "../../src/Library/TestParamLib.sol";
import {DALiquidityLib} from "../../src/Library/DALiquidityLib.sol";
import {AggregatorV3Interface} from "../../src/Interface/AggregatorV3Interface.sol";


contract MyLocalScript is Script {

    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);
        
        address bot = address(0x4fbda92d4B40213A6b051DF6B0A2908a7483F973);
        _traderBotInfo(bot);
        PrivateDoppiTraderFactory factory = PrivateDoppiTraderFactory(address(0x150e8baa7cF0f3FD2B8dd4F5a53Ee99375a1834A)); 
        console.log(factory.getPrivateCore(bot), "PrivateCore Address");
        console.log(factory.getPrivateLiquidity(bot), "PrivateLiquidity Address");
        
        vm.stopBroadcast();
    }

    function _traderBotInfo(address bot) internal view {
        DoppiTrader bot = DoppiTrader(bot);
        (uint256 totalAssetA, uint256 totalAssetB, uint256 price) = bot.getTotalBalances();
        console.log("Total Asset A:", totalAssetA);
        console.log("Total Asset B:", totalAssetB); 
        console.log("Current Price:", price);        
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