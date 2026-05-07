// TestEnv.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiOffer.sol";

contract UpdateDoppiOfferAdmin is Script {

    address public constant DOPPI_OFFER_BTC = address(0x418f56B5e660882ae00145fc6ab200AfEE9e0595); 
    address public constant DOPPI_OFFER_ETH = address(0x42d7C78839Ff39D797d08Fde1Ae3f1433035519A); 
    address executor = address(0xFD2D482ABBc3Bc70354311e83B9347e83132E060);
    
    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_MAINNET");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Get DoppiOffer instance
        DoppiOffer doppiOffer = DoppiOffer(DOPPI_OFFER_BTC);
        doppiOffer.setAdmin(executor, true);
        console.log("done updating doppiOffer BTC-USDT admin address");
        console.log(doppiOffer.admins(executor), "is admin BTC");

        // Get DoppiOffer instance
        DoppiOffer doppiOfferETH = DoppiOffer(DOPPI_OFFER_ETH);
        doppiOfferETH.setAdmin(executor, true);
        console.log("done updating doppiOffer ETH-USDT admin address");
        console.log(doppiOfferETH.admins(executor), "is admin ETH");
        
    
        vm.stopBroadcast();
    }
    
    
}