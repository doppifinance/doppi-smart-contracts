// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ImpliedVol} from "../src/mainnet/ImpliedVol.sol";
// import {IBlackScholes} from "../Interface/IBlackScholes.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";

contract ImpliedVolTest is Test {
    ImpliedVol markIV;
    BlackScholes blackScholes;
    address owner = address(this);

    function setUp() public {
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;

        blackScholes = new BlackScholes();
        markIV = new ImpliedVol(blackScholes);
        markIV.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
    }

    function test_getRegression() public view {
        (ImpliedVol.RegressionVar memory buy, ImpliedVol.RegressionVar memory sell) = markIV.getRegression(86400);
        assertEq((buy.a), 0.0000000807142857142833 * 1e27);
        assertEq((buy.b), -0.019095857142856592 * 1e27);
        assertEq((buy.c), 1159.8454285713972 * 1e27);
        assertEq((sell.a), 0.000000102857142857143 * 1e27);
        assertEq((sell.b), -0.02447200000000008 * 1e27);
        assertEq((sell.c), 1485.8762857142906 * 1e27);
    }

    function test_getImpliedVol() public view {
        uint256 ivSell_1 = markIV.getImpliedVol(86400, 121000 * 1e18, false);
        uint256 ivBuy_2 = markIV.getImpliedVol(86400, 112000 * 1e18, true);
        assertEq((ivSell_1), 306957142857115830); // 30.6957142857115830
        assertEq((ivBuy_2), 335894285714286112); // 33.5894285714286112
    }

    function test_buyapr() public view {
        uint256 spot = 116500 * 1e18;
        uint256 timeToExpiry = 86400;
        uint256 strike = 115500 * 1e18;
        (uint256 buyapr, uint256 delta) = markIV.getBuyAPR(timeToExpiry, spot, strike);
        // console.log(buyapr, delta);
        assertEq(buyapr, 9369); // 93.69%
        assertEq(delta, 2949); // 0.2949
    }

    function test_getSellAPR() public view {
        uint256 spot = 116500 * 1e18;
        uint256 timeToExpiry = 86400;
        uint256 strike = 117000 * 1e18;
        (uint256 sellapr, uint256 delta) = markIV.getSellAPR(timeToExpiry, spot, strike);
        // console.log(sellapr, delta);
        assertEq(sellapr, 14081); // 140.81%
        assertEq(delta, 3979); // 0.3979
    }
}
