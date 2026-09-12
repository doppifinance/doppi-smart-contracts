// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../../src/Interface/AggregatorV3Interface.sol";
import "../../src/mainnet/DoppiCore.sol";
import "../../src/mainnet/DoppiLiquidity.sol";
import "../../src/mainnet/DoppiOpportunity.sol";
import "../../src/mainnet/private/DoppiGridTrader.sol";
import "../../src/mainnet/private/DoppiSimpleTrader.sol";
import "../../src/mainnet/DoppiFeePool.sol";
contract PrintDoppiConfig is Script {
    // Mainnet BTC-USDT
    address internal constant MAINNET_BTC_CORE = 0x13073F01791C01Fd6b73fc1B9558B7944f9a0D7e;
    address internal constant MAINNET_BTC_LP = 0x3Df1Eb646f4B39441d73AdbFE6e14710f5877CDE;
    address internal constant MAINNET_BTC_OPPORTUNITY = 0xbf051f272222F20F7E41df89Ed0b8a00736E976b;
    address internal constant MAINNET_BTC_GRID_BOT = address(0);
    address internal constant MAINNET_BTC_SIMPLE_BOT = address(0);
    address internal constant MAINNET_FEE_POOL_ADDR = 0xA3ec92E6B7494329Cf0Cf4feFA0a00859D5Ef73f;

    // Localhost example from current local scripts
    address internal constant LOCAL_CORE = 0x53DBB13EFE722256DA8e603635f9d59647C0DdAc;
    address internal constant LOCAL_LP = 0x3f3284764A9bD533E0a372Da38Ea936D7D30f897;
    address internal constant LOCAL_OPPORTUNITY = 0x03C8222f20E0ed94895721D94a5C811499804e11;
    address internal constant LOCAL_GRID_BOT = address(0x46A8904211993824973bf970f3e2fD4347561deB);
    address internal constant LOCAL_SIMPLE_BOT = address(0);
    address internal constant LOCAL_FEE_POOL_ADDR = 0x4d58eE0954A2dBC754F0aF10217F22aa8C173347;

    // Active addresses for the default run().
    // Switch these assignments to the profile you want before running the script.
    address internal constant CORE_ADDR = LOCAL_CORE;
    address internal constant LP_ADDR = LOCAL_LP;
    address internal constant OPPORTUNITY_ADDR = LOCAL_OPPORTUNITY;
    address internal constant GRID_BOT_ADDR = LOCAL_GRID_BOT;
    address internal constant SIMPLE_BOT_ADDR = LOCAL_SIMPLE_BOT;
    address internal constant FEE_POOL_ADDR = LOCAL_FEE_POOL_ADDR;

    function run() external view {
        // _run(CORE_ADDR, LP_ADDR, OPPORTUNITY_ADDR, GRID_BOT_ADDR, SIMPLE_BOT_ADDR, FEE_POOL_ADDR);
        _run(MAINNET_BTC_CORE, MAINNET_BTC_LP, MAINNET_BTC_OPPORTUNITY, MAINNET_BTC_GRID_BOT, MAINNET_BTC_SIMPLE_BOT, MAINNET_FEE_POOL_ADDR);
    }

    function _run(
        address coreAddr,
        address lpAddr,
        address opportunityAddr,
        address gridBotAddr,
        address simpleBotAddr,
        address feePoolAddr
    ) internal view {
        if (coreAddr != address(0)) {
            DoppiCore core = DoppiCore(coreAddr);
            _printCore(core);

            if (lpAddr == address(0)) {
                lpAddr = address(core.doppiLP());
            }
            if (opportunityAddr == address(0)) {
                opportunityAddr = address(core.doppiOpportunity());
            }
        }

        if (lpAddr != address(0)) {
            _printLiquidity(DoppiLiquidity(lpAddr));
        }

        if (opportunityAddr != address(0)) {
            _printOpportunity(DoppiOpportunity(opportunityAddr));
        }

        if (gridBotAddr != address(0)) {
            _printGridTrader(DoppiGridTrader(gridBotAddr));
        }

        if (simpleBotAddr != address(0)) {
            _printSimpleTrader(DoppiSimpleTrader(simpleBotAddr));
        }

        if (feePoolAddr != address(0)) {
            _printFeePool(DoppiFeePool(feePoolAddr));
        }
    }

    function _printFeePool(DoppiFeePool pool) internal view {
        console.log("\n================ DOPPI FEE POOL ================");
        console.log("feePool", address(pool));
        console.log("sharedLiquidity", pool.sharedLiquidity());
        console.log("feeReceiver", pool.feeReceiver());
        console.log("sharedLPSplitBps", pool.sharedLPSplitBps());
        console.log("owner", pool.owner());
    }


    function _printCore(DoppiCore core) internal view {
        console.log("\n================ DOPPI CORE ================");
        console.log("core", address(core));
        console.log("owner", core.owner());
        console.log("paused", core.paused());
        console.log("emergencyMode", core.emergencyMode());
        console.log("assetA", address(core.assetA()));
        console.log("assetB", address(core.assetB()));
        console.log("doppiLP", address(core.doppiLP()));
        console.log("doppiOffer", address(core.doppiOffer()));
        console.log("doppiPoints", address(core.doppiPoints()));
        console.log("doppiOpportunity", address(core.doppiOpportunity()));
        console.log("doppiTraderFactory", address(core.doppiTraderFactory()));
        console.log("forwarder", core.s_forwarderAddress());
        console.log("treasury", core.treasury());
        console.log("treasury_fee_bps", core.treasury_fee());
        console.log("minOrderA", core.minOrderA());
        console.log("minOrderB", core.minOrderB());
        console.log("UPKEEPS_PER_CHECK", core.UPKEEPS_PER_CHECK());
        console.log("aprToleranceBP", core.aprToleranceBP());
        console.log("maxSwap", core.maxSwap());
        console.log("priceDecimal", core.priceDecimal());
        console.log("opportunityBot[doppiOpportunity]", core.opportunityBots(address(core.doppiOpportunity())));
    }

    function _printLiquidity(DoppiLiquidity lp) internal view {
        console.log("\n============= DOPPI LIQUIDITY =============");
        console.log("lp", address(lp));
        console.log("owner", lp.owner());
        console.log("paused", lp.paused());
        console.log("assetA", lp.assetA());
        console.log("assetB", lp.assetB());
        console.log("doppiCore", lp.doppiCore());
        console.log("doppiLiquidityRouter", lp.doppiLiquidityRouter());
        console.log("forwarder", lp.s_forwarderAddress());
        console.log("entryPointsLocked", lp.entryPointsLocked());
        console.log("tokenName", lp.name());
        console.log("tokenSymbol", lp.symbol());

        (
            AggregatorV3Interface chainLinkFeed,
            address router,
            uint24 poolFee,
            uint24 slippage,
            uint24 liquidityFee,
            uint8 priceDecimals,
            uint256 decimals,
            address v3Pool,
            uint32 twapDuration,
            uint24 maxDepositPercentage,
            uint32 maxDelay,
            uint256 maxSwap,
            uint256 priceGap,
            uint8 unwindGapMultiplier
        ) = lp.config();

        console.log("config.chainLinkFeed", address(chainLinkFeed));
        console.log("config.router", router);
        console.log("config.poolFee", poolFee);
        console.log("config.slippage", slippage);
        console.log("config.liquidityFee", liquidityFee);
        console.log("config.priceDecimals", priceDecimals);
        console.log("config.decimals", decimals);
        console.log("config.v3Pool", v3Pool);
        console.log("config.twapDuration", twapDuration);
        console.log("config.maxDepositPercentage", maxDepositPercentage);
        console.log("config.maxDelay", maxDelay);
        console.log("config.maxSwap", maxSwap);
        console.log("config.priceGap", priceGap);
        console.log("config.unwindGapMultiplier", unwindGapMultiplier);

        console.log("currentPrice", lp.getPrice());
        console.log("priceDecimalsFromGetter", lp.getPriceDecimals());
    }

    function _printOpportunity(DoppiOpportunity opportunity) internal view {
        console.log("\n============ DOPPI OPPORTUNITY ============");
        console.log("opportunity", address(opportunity));
        console.log("owner", opportunity.owner());
        console.log("paused", opportunity.paused());
        console.log("doppiCore", address(opportunity.doppiCore()));
        console.log("doppiLP", address(opportunity.doppiLP()));
        console.log("forwarder", opportunity.s_forwarderAddress());
        console.log("opportunityBufferCutBps", opportunity.opportunityBufferCutBps());
        console.log("opportunityMinBufferBps", opportunity.opportunityMinBufferBps());
        console.log("fee", "N/A - shared opportunity has no direct fee config");
    }

    function _printGridTrader(DoppiGridTrader trader) internal view {
        console.log("\n========== PRIVATE GRID TRADER ============");
        console.log("gridBot", address(trader));
        console.log("owner", trader.owner());
        console.log("paused", trader.paused());
        console.log("engineStarted", trader.engineStarted());
        console.log("validTrader", trader.validTrader());
        console.log("forwarder", trader.s_forwarderAddress());
        console.log("privateAutomationHub", address(trader.privateAutomationHub()));
        console.log("doppiLP", address(trader.doppiLP()));
        console.log("doppiOffer", address(trader.impliedVol()));
        console.log("doppiPoints", address(trader.doppiPoints()));
        console.log("feePool", trader.feePool());
        console.log("profitFeeBps", trader.profitFeeBps());
        console.log("opportunityBufferCutBps", trader.opportunityBufferCutBps());
        console.log("opportunityMinBufferBps", trader.opportunityMinBufferBps());
        console.log("epochDuration", trader.epochDuration());
        console.log("minOrderA", trader.minOrderA());
        console.log("minOrderB", trader.minOrderB());
        console.log("maxSwap", trader.maxSwap());
        console.log("maxOrder", trader.maxOrder());
        console.log("traderDefaultDay", trader.traderDefaultDay());
        console.log("maxOrderPerRoundA", trader.maxOrderPerRoundA());
        console.log("maxOrderPerRoundB", trader.maxOrderPerRoundB());
        console.log("unwindGapMultiplier", trader.unwindGapMultiplier());
        console.log("currentAnchorPrice", trader.currentAnchorPrice());
        console.log("currentEpochStart", trader.currentEpochStart());
        console.log("currentEpochExpiry", trader.currentEpochExpiry());
    }

    function _printSimpleTrader(DoppiSimpleTrader trader) internal view {
        console.log("\n========= PRIVATE SIMPLE TRADER ===========");
        console.log("simpleBot", address(trader));
        console.log("owner", trader.owner());
        console.log("paused", trader.paused());
        console.log("engineStarted", trader.engineStarted());
        console.log("validTrader", trader.validTrader());
        console.log("forwarder", trader.s_forwarderAddress());
        console.log("privateAutomationHub", address(trader.privateAutomationHub()));
        console.log("doppiLP", address(trader.doppiLP()));
        console.log("doppiOffer", address(trader.impliedVol()));
        console.log("doppiPoints", address(trader.doppiPoints()));
        console.log("feePool", trader.feePool());
        console.log("profitFeeBps", trader.profitFeeBps());
        console.log("opportunityBufferCutBps", trader.opportunityBufferCutBps());
        console.log("opportunityMinBufferBps", trader.opportunityMinBufferBps());
        console.log("minOrderA", trader.minOrderA());
        console.log("minOrderB", trader.minOrderB());
        console.log("maxSwap", trader.maxSwap());
        console.log("maxOrder", trader.maxOrder());
        console.log("traderDefaultDay", trader.traderDefaultDay());
        console.log("orderCountMultiplierBps", trader.orderCountMultiplierBps());
        console.log("nextBuyTriggerPrice", trader.nextBuyTriggerPrice());
        console.log("nextSellTriggerPrice", trader.nextSellTriggerPrice());
        console.log("maxOrderPerRoundA", trader.maxOrderPerRoundA());
        console.log("maxOrderPerRoundB", trader.maxOrderPerRoundB());
        console.log("unwindGapMultiplier", trader.unwindGapMultiplier());
    }

}