// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/mainnet/DoppiOffer.sol";

contract SetImpliedVolRegression is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Replace with your deployed ImpliedVol contract address
        address impliedVolAddress = 0x46B59Cad078EB85158548CF79c85E7ca7874F3E4;

        vm.startBroadcast(deployerPrivateKey);

        DoppiOffer impliedVol = DoppiOffer(impliedVolAddress);

        // Example regression parameters (adjust these values as needed)
        // Note: a, b, c must be * 1e27 according to contract comments
        uint256 daysInTimestamp = 86400; // 1 day in seconds

        int256 buyA = 0.0000000807142857142833 * 1e27;
        int256 buyB = -0.019095857142856592 * 1e27;
        int256 buyC = 1159.8454285713972 * 1e27;

        int256 sellA = 0.000000102857142857143 * 1e27;
        int256 sellB = -0.02447200000000008 * 1e27;
        int256 sellC = 1485.8762857142906 * 1e27;

        // Call setRegression
        impliedVol.setRegression(daysInTimestamp, buyA, buyB, buyC, sellA, sellB, sellC);

        console.log("Regression parameters set successfully for DoppiOffer at:", impliedVolAddress);
        console.log("Days in timestamp:", daysInTimestamp);
        console.log("Buy regression - a:", vm.toString(buyA));
        console.log("Buy regression - b:", vm.toString(buyB));
        console.log("Buy regression - c:", vm.toString(buyC));
        console.log("Sell regression - a:", vm.toString(sellA));
        console.log("Sell regression - b:", vm.toString(sellB));
        console.log("Sell regression - c:", vm.toString(sellC));

        
        // deal(USDT, address(0xaD8234bC07168d9f7E49c3780e4b5fefa6620f8A), 100_000 ether);
        // address payable myWallet = payable(0xaD8234bC07168d9f7E49c3780e4b5fefa6620f8A);
        // (bool success, ) = myWallet.call{value: msg.value}("");
        // require(success, "ETH transfer failed");
        // vm.stopBroadcast();
    }
}
