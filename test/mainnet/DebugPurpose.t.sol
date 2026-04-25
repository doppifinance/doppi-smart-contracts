// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// import "forge-std/Test.sol";
// import "../../src/mainnet/DoppiUpkeepManager.sol";
// import "../../src/mainnet/DoppiTrader.sol";
// import "../../src/mainnet/DoppiLiquidity.sol";
// import "../../src/Interface/IAutomationRegistryConsumer.sol";

// contract DebugPurposeTest is Test {
    
//     DoppiUpkeepManager doppiupkeep;
//     DoppiLiquidity doppiLP;
//     DoppiTrader doppiTrader;
//     IAutomationRegistryConsumer registryConsumer;

//     address payable DOPPI_UPKEEP = payable(0x84223a8a269103fB590Bf6aaDE2977a27a4CB93d);
//     address DOPPI_TRADER = address(0x3555B406B689B438A6CABC3Da43C6C59782cf84e);
//     address DOPPI_LP = address(0xc7D5CB3567CbB2f52189C64e0067Bf9B2c2ab0eB);
//     uint256 upkeepId = 16531882998370319773276920806591893588096275106134558017517017460775116440086; // doppitrader upkeepId
    
//     address constant CHAINLINK_RegistryConsumer = address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C);
    
//     function setUp() public {
        
//         // Fork Mainnet at a specific block
//         uint256 mainnetFork = vm.createFork("mainnet", 76894719); 
//         vm.selectFork(mainnetFork);
        
//         // Start prank as owner
//         // vm.startPrank(owner);
        
//         doppiupkeep = DoppiUpkeepManager(DOPPI_UPKEEP);
//         doppiLP = DoppiLiquidity(DOPPI_LP);
//         doppiTrader = DoppiTrader(DOPPI_TRADER);
//         registryConsumer = IAutomationRegistryConsumer(CHAINLINK_RegistryConsumer);
        
        
//         // vm.stopPrank();
//     }

//     // function testDoppiTraderUnwind_Issue_1() public {

//     //     address forw = registryConsumer.getForwarder(upkeepId);
//     //     console.log("getForwarder: ", forw);

//     //     (bool upkeepNeeded, bytes memory performData) = doppiTrader.checkUpkeep("");
//     //     _getDoppiTraderUnwindData();
//     //     vm.prank(forw);
//     //     doppiTrader.performUpkeep(performData);
//     //     vm.stopPrank();
//     //     _getDoppiTraderUnwindData();
//     //     // assertEq(upkeepNeeded, false);
        
//     // }

//     function testDoppiTraderUnwind_Simulate_1() public {
//         uint256 amount = 1117318435754189;
//         uint256 strikePrice = 89_500 * 1e8;

//         // vm.roll(block.number - 111);
//         uint256 price = doppiLP.getPrice();
//         console.log(price, "price 1");
//         vm.startPrank(address(0x4Fe2973Df9c541c23Ce0C1e8752D16E797920d99));
//         doppiTrader.createUnwindPosition(amount, strikePrice, true);
//         vm.stopPrank();

//         // vm.roll(block.number + 111);
//         price = doppiLP.getPrice();
//         console.log(price, "price 2");
//         (bool upkeepNeeded, bytes memory performData) = doppiTrader.checkUpkeep("");
//         _getDoppiTraderUnwindData();

//         // address forw = registryConsumer.getForwarder(upkeepId);
//         // vm.prank(forw);
//         // doppiTrader.performUpkeep(performData);
//         // vm.stopPrank();
//         // assertEq(upkeepNeeded, false);
        
//     }

//     function _getDoppiTraderUnwindData() internal view {

//         console.log("start DoppiTraderUnwindData");
//         (uint256 lowerBound, uint256 upperBound) = doppiTrader.getLowerUpperBound();
//         console.log(lowerBound, upperBound);
//         for (uint256 price = upperBound; price >= lowerBound; ) {
//             bool isBuy = true;
//             uint256 amountBuy = doppiTrader.unWindBuy(price);
//             uint256 amountSell = doppiTrader.unWindSell(price);
            
//             (uint256 undo_assetB, uint256 undo_assetA) = doppiTrader.undoStat();
            
//             console.log(amountBuy, amountSell, price, undo_assetB);
//             price -= (500 * 1e8); 
//         }
        
//     }

// }
