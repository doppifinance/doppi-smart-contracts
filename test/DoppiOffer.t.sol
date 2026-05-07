// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiOffer} from "../src/mainnet/DoppiOffer.sol";
import {BlackScholes} from "../src/mainnet/BlackScholes.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import "../src/mainnet/DoppiCoreTypes.sol";

contract DoppiOfferTest is Test {
    DoppiOffer markIV;
    BlackScholes blackScholes;
    address owner = address(this);
    uint256 priceDecimal = 1e8;
    uint256 constant INITIAL_PRICE = 100_000 * 1e8;
    address chainLinkFeed = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
    MockOracle oracle;

    function setUp() public {
        int256 a_buy = 0.0000000807142857142833 * 1e27;
        int256 b_buy = -0.019095857142856592 * 1e27;
        int256 c_buy = 1159.8454285713972 * 1e27;

        int256 a_sell = 0.000000102857142857143 * 1e27;
        int256 b_sell = -0.02447200000000008 * 1e27;
        int256 c_sell = 1485.8762857142906 * 1e27;

        blackScholes = new BlackScholes();
        oracle = new MockOracle(int256(INITIAL_PRICE), 8);
        markIV = new DoppiOffer(blackScholes, address(oracle), 500);
        // oracle.setPrice(int256(90400 * 1e8));
        vm.warp(1735689600);
        markIV.setRegression(86400, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
        markIV.setRegression(86400 * 3, a_buy, b_buy, c_buy, a_sell, b_sell, c_sell);
    }
    
    function test_getRegression() public view {
        (DoppiOffer.RegressionVar memory buy, DoppiOffer.RegressionVar memory sell) = markIV.getRegression(86400);
        assertEq((buy.a), 0.0000000807142857142833 * 1e27);
        assertEq((buy.b), -0.019095857142856592 * 1e27);
        assertEq((buy.c), 1159.8454285713972 * 1e27);
        assertEq((sell.a), 0.000000102857142857143 * 1e27);
        assertEq((sell.b), -0.02447200000000008 * 1e27);
        assertEq((sell.c), 1485.8762857142906 * 1e27);
    }

    function test_getNotAvailImpliedVol() public view {
        (uint256 ivSell_1, ) = markIV.getImpliedVol(86400 * 2, 121000 * priceDecimal, false);
        (uint256 ivBuy_2, ) = markIV.getImpliedVol(86400 * 2, 112000 * priceDecimal, true);
        assertEq(ivSell_1, 0);
        assertEq(ivBuy_2, 0);
    }

    function test_getImpliedVol() public view {
        (uint256 ivSell_1, ) = markIV.getImpliedVol(86400, 121000 * priceDecimal, false);
        (uint256 ivBuy_2, ) = markIV.getImpliedVol(86400, 112000 * priceDecimal, true);
        // console.log(ivSell_1, ivBuy_2);
        assertEq((ivSell_1), 306957142857115830); // 30.6957142857115830
        assertEq((ivBuy_2), 335894285714286112); // 33.5894285714286112
    }

    function test_buyapr() public view {
        uint256 spot = 116500 * priceDecimal;
        uint256 timeToExpiry = 86400;
        uint256 strike = 115500 * priceDecimal;
        (uint256 buyapr, uint256 delta) = markIV.getBuyAPR(timeToExpiry, spot, strike);
        // console.log(buyapr, delta);
        assertEq(buyapr, 9369); // 93.69%
        assertEq(delta, 2949); // 0.2949
    }

    function test_getSellAPR() public view {
        uint256 spot = 116500 * priceDecimal;
        uint256 timeToExpiry = 86400;
        uint256 strike = 117000 * priceDecimal;
        (uint256 sellapr, uint256 delta) = markIV.getSellAPR(timeToExpiry, spot, strike);
        // console.log(sellapr, delta);
        assertEq(sellapr, 14081); // 140.81%
        assertEq(delta, 3979); // 0.3979
    }

    function test_buyapr_notavailable() public view {
        uint256 spot = 116500 * priceDecimal;
        uint256 timeToExpiry = 86400 * 2;
        uint256 strike = 115500 * priceDecimal;
        (uint256 buyapr, uint256 delta) = markIV.getBuyAPR(timeToExpiry, spot, strike);
        // console.log(buyapr, delta);
        assertEq(buyapr, 0); 
        assertEq(delta, 0); 
    }

    function test_getSellAPR_notavailable() public view {
        uint256 spot = 116500 * priceDecimal;
        uint256 timeToExpiry = 86400 * 2;
        uint256 strike = 117000 * priceDecimal;
        (uint256 sellapr, uint256 delta) = markIV.getSellAPR(timeToExpiry, spot, strike);
        // console.log(sellapr, delta);
        assertEq(sellapr, 0);
        assertEq(delta, 0); 
    }

    function test_getOffers_notUpdated() public {
        
        vm.warp(vm.getBlockTimestamp() + 1.1 days); // passed 1 day and not updated
        DualAssetOffer[] memory buyOffers = markIV.getBuyOffers(1);
        assertEq(buyOffers[0].apr, 0);
        DualAssetOffer[] memory sellOffers = markIV.getSellOffers(1);
        assertEq(sellOffers[0].apr, 0);
    }


    function test_getBuyOffers() public view {
        DualAssetOffer[] memory buyOffers = markIV.getBuyOffers(1);
        assertEq(buyOffers.length, 5);
        assertEq(buyOffers[0].apr, 38315);
        assertEq(buyOffers[1].apr, 31399);
        assertEq(buyOffers[4].apr, 16837);
            
        for (uint256 i = 0; i < buyOffers.length; i++) {
            
            if(i>0){
                assertEq(buyOffers[i].price, INITIAL_PRICE);
                assertLt(buyOffers[i].strikePrice, INITIAL_PRICE);
                assertGt(buyOffers[i].apr, 0);
            }else{
                assertEq(buyOffers[i].price, INITIAL_PRICE);
                assertEq(buyOffers[i].strikePrice, INITIAL_PRICE);
                assertGt(buyOffers[i].apr, 0);
            }
        }

        // Strike prices should be decreasing (further from current price)
        for (uint256 i = 1; i < buyOffers.length; i++) {
            assertLt(buyOffers[i].strikePrice, buyOffers[i - 1].strikePrice);
        }
    }

    function test_getSellOffers() public view {
        DualAssetOffer[] memory sellOffers = markIV.getSellOffers(1);

        assertEq(sellOffers.length, 5);

        assertEq(sellOffers[0].apr, 35700);
        assertEq(sellOffers[1].apr, 27794);
        assertEq(sellOffers[4].apr, 10881);

        for (uint256 i = 0; i < sellOffers.length; i++) {
            // console.log(sellOffers[i].strikePrice, sellOffers[i].apr);
            assertEq(sellOffers[i].price, INITIAL_PRICE);
            assertGt(sellOffers[i].strikePrice, INITIAL_PRICE);
            assertGt(sellOffers[i].apr, 0);
            // assertGt(sellOffers[i].validUntilTimestamp, block.timestamp);
        }

        // Strike prices should be increasing (further from current price)
        for (uint256 i = 1; i < sellOffers.length; i++) {
            assertGt(sellOffers[i].strikePrice, sellOffers[i - 1].strikePrice);
        }
    }

    function test_getAllOffers() public view {
        (DualAssetOffer[] memory buyOffers, DualAssetOffer[] memory sellOffers) =
            markIV.getAllOffers(1);

        assertEq(buyOffers.length, 5);
        assertEq(sellOffers.length, 5);

        for (uint256 i = 0; i < 5; i++) {
            assertEq(buyOffers[i].price, INITIAL_PRICE);
            assertEq(sellOffers[i].price, INITIAL_PRICE);
            assertLe(buyOffers[i].strikePrice, INITIAL_PRICE);
            assertGt(sellOffers[i].strikePrice, INITIAL_PRICE);
        }
        
    }

    function test_getAllOffers_3days() public view {
        (DualAssetOffer[] memory buyOffers, DualAssetOffer[] memory sellOffers) =
            markIV.getAllOffers(3);

        assertEq(buyOffers.length, 5);
        assertEq(sellOffers.length, 5);

        for (uint256 i = 0; i < 5; i++) {
            assertEq(buyOffers[i].price, INITIAL_PRICE);
            assertEq(sellOffers[i].price, INITIAL_PRICE);
            assertGt(buyOffers[i].apr, 0);
            assertGt(sellOffers[i].apr, 0);
        }
    }

    function test_getAllOffers_2days_NoAPR() public {
        
        oracle.setPrice(int256(94100 * 1e8));
        (DualAssetOffer[] memory buyOffers, DualAssetOffer[] memory sellOffers) =
            markIV.getAllOffers(2);

        assertEq(buyOffers.length, 5);
        assertEq(sellOffers.length, 5);

        for (uint256 i = 0; i < 5; i++) {
            assertEq(buyOffers[i].apr, 0);
            assertEq(sellOffers[i].apr, 0);
            assertLt(buyOffers[i].strikePrice, 94100 * 1e8);
            assertGt(sellOffers[i].strikePrice, 94100 * 1e8);
        }
    }

    function test_getOneDayBuffer() public view {
        uint256 onedayVol = markIV.getOneDayBuffer(121000 * priceDecimal, true);
        assertEq((onedayVol), 162); // in bps
    }

    function test_getOneDayBuffer_outOfBuffer() public {
        
        markIV.setBuffer(200, 300);
        uint256 onedayVol = markIV.getOneDayBuffer(121000 * priceDecimal, true);
        assertEq((onedayVol), 200); // in bps
        onedayVol = markIV.getOneDayBuffer(101000 * priceDecimal, false);
        assertEq((onedayVol), 300); // in bps
    }

    // =========================================================
    // MAX_OFFER_APR / clampAPR tests
    // =========================================================

    function test_setMaxOfferAPR_defaultValue() public view {
        assertEq(markIV.MAX_OFFER_APR(), 100000);
    }

    function test_setMaxOfferAPR_ownerCanChange() public {
        markIV.setMaxOfferAPR(50000);
        assertEq(markIV.MAX_OFFER_APR(), 50000);
    }

    function test_setMaxOfferAPR_nonOwnerReverts() public {
        address attacker = address(0xdead);
        vm.prank(attacker);
        vm.expectRevert();
        markIV.setMaxOfferAPR(50000);
    }

    function test_setMaxOfferAPR_zeroReverts() public {
        vm.expectRevert("max apr must be > 0");
        markIV.setMaxOfferAPR(0);
    }

    /// When MAX_OFFER_APR is high enough to never trigger, APRs are unchanged.
    function test_clampAPR_noClampWhenLimitIsHigh() public {
        markIV.setMaxOfferAPR(200000); // 2000%, well above any realistic APR
        DualAssetOffer[] memory buyOffers = markIV.getBuyOffers(1);
        assertEq(buyOffers[0].apr, 38315);
        assertEq(buyOffers[1].apr, 31399);
        assertEq(buyOffers[4].apr, 16837);
        DualAssetOffer[] memory sellOffers = markIV.getSellOffers(1);
        assertEq(sellOffers[0].apr, 35700);
        assertEq(sellOffers[1].apr, 27794);
        assertEq(sellOffers[4].apr, 10881);
    }

    /// Zone-0 is scaled to exactly MAX_OFFER_APR when clamping is active.
    function test_clampAPR_buyZone0EqualsMaxAPR() public {
        // Set cap below raw zone-0 buy APR (38315) to activate clamping
        markIV.setMaxOfferAPR(20000);
        DualAssetOffer memory offer = markIV.getSingleOffer(true, 1, 0, INITIAL_PRICE);
        assertEq(offer.apr, markIV.MAX_OFFER_APR());
    }

    /// Zone-0 is scaled to exactly MAX_OFFER_APR when clamping is active.
    function test_clampAPR_sellZone0EqualsMaxAPR() public {
        // Set cap below raw zone-0 sell APR (35700) to activate clamping
        markIV.setMaxOfferAPR(20000);
        DualAssetOffer memory offer = markIV.getSingleOffer(false, 1, 0, INITIAL_PRICE);
        assertEq(offer.apr, markIV.MAX_OFFER_APR());
    }

    /// No APR in the buy offer array exceeds MAX_OFFER_APR.
    function test_clampAPR_buyOffersAllCapped() public view {
        DualAssetOffer[] memory buyOffers = markIV.getBuyOffers(1);
        for (uint256 i = 0; i < buyOffers.length; i++) {
            assertLe(buyOffers[i].apr, markIV.MAX_OFFER_APR());
        }
    }

    /// No APR in the sell offer array exceeds MAX_OFFER_APR.
    function test_clampAPR_sellOffersAllCapped() public view {
        DualAssetOffer[] memory sellOffers = markIV.getSellOffers(1);
        for (uint256 i = 0; i < sellOffers.length; i++) {
            assertLe(sellOffers[i].apr, markIV.MAX_OFFER_APR());
        }
    }

    /// Zone ordering is preserved after proportional scaling (zone-0 >= zone-1 >= ...).
    function test_clampAPR_buyZoneOrderPreserved() public view {
        DualAssetOffer[] memory buyOffers = markIV.getBuyOffers(1);
        for (uint256 i = 1; i < buyOffers.length; i++) {
            assertLe(buyOffers[i].apr, buyOffers[i - 1].apr);
        }
    }

    /// Zone ordering is preserved after proportional scaling for sell offers.
    function test_clampAPR_sellZoneOrderPreserved() public view {
        DualAssetOffer[] memory sellOffers = markIV.getSellOffers(1);
        for (uint256 i = 1; i < sellOffers.length; i++) {
            assertLe(sellOffers[i].apr, sellOffers[i - 1].apr);
        }
    }

    /// Exact proportional values: scaled[i] = mulDiv(raw[i], MAX_OFFER_APR, raw[0]).
    function test_clampAPR_buyExactProportionalValues() public {
        // Set cap below raw zone-0 (38315) to activate proportional scaling
        markIV.setMaxOfferAPR(20000);
        // raw: zone-0=38315, zone-1=31399, zone-4=16837; MAX_OFFER_APR=20000
        DualAssetOffer[] memory buyOffers = markIV.getBuyOffers(1);
        assertEq(buyOffers[0].apr, 20000);
        assertEq(buyOffers[1].apr, 16389); // floor(31399*20000/38315)
        assertEq(buyOffers[4].apr, 8788);  // floor(16837*20000/38315)
    }

    /// Exact proportional values for sell.
    function test_clampAPR_sellExactProportionalValues() public {
        // Set cap below raw zone-0 (35700) to activate proportional scaling
        markIV.setMaxOfferAPR(20000);
        // raw: zone-0=35700, zone-1=27794, zone-4=10881; MAX_OFFER_APR=20000
        DualAssetOffer[] memory sellOffers = markIV.getSellOffers(1);
        assertEq(sellOffers[0].apr, 20000);
        assertEq(sellOffers[1].apr, 15570); // floor(27794*20000/35700)
        assertEq(sellOffers[4].apr, 6095);  // floor(10881*20000/35700)
    }

    /// Lowering MAX_OFFER_APR further scales all offers down proportionally.
    function test_clampAPR_lowerMaxAPRScalesDown() public {
        markIV.setMaxOfferAPR(5000); // 50%
        DualAssetOffer[] memory buyOffers = markIV.getBuyOffers(1);
        assertEq(buyOffers[0].apr, 5000);
        for (uint256 i = 1; i < buyOffers.length; i++) {
            assertLe(buyOffers[i].apr, uint32(5000));
            assertLe(buyOffers[i].apr, buyOffers[i - 1].apr);
        }
    }

    /// Normal coefficients with a low cap: all APRs clamped, zone-0 equals the cap exactly.
    function test_clampAPR_extremeCoefficients_allCapped() public {
        // Lower the cap well below the natural raw APRs (38315 buy, 35700 sell)
        // to simulate what happens when regression produces very high APRs.
        markIV.setMaxOfferAPR(5000);

        DualAssetOffer[] memory buyOffers = markIV.getBuyOffers(1);
        DualAssetOffer[] memory sellOffers = markIV.getSellOffers(1);
        for (uint256 i = 0; i < 5; i++) {
            assertLe(buyOffers[i].apr, markIV.MAX_OFFER_APR());
            assertLe(sellOffers[i].apr, markIV.MAX_OFFER_APR());
        }
        // Zone-0 should equal MAX_OFFER_APR exactly (highest zone, hits the cap)
        assertEq(buyOffers[0].apr, markIV.MAX_OFFER_APR());
        assertEq(sellOffers[0].apr, markIV.MAX_OFFER_APR());
    }


}
