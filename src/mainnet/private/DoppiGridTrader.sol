// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AutomationCompatibleInterface} from "../../Interface/AutomationCompatibleInterface.sol";
import {IDoppiLiquidity} from "../../Interface/IDoppiLiquidity.sol";
import {IDoppiOffer} from "../../Interface/IDoppiOffer.sol";
import {IDoppiPoints} from "../../Interface/IDoppiPoints.sol";
import {DALiquidityLib} from "../../Library/DALiquidityLib.sol";
import {DoppiTraderAdminView} from "../DoppiTraderAdminView.sol";
// import "forge-std/console.sol";

contract DoppiGridTrader is DoppiTraderAdminView, ReentrancyGuard, AutomationCompatibleInterface, Initializable {
    using SafeERC20 for IERC20;

    uint16 private constant BPS = 10000;
    bytes4 private constant RECORD_SELECTOR = bytes4(keccak256("recordTrade(address,uint256)"));
    
    mapping(uint256 => uint256) public opportunityBuy;
    mapping(uint256 => uint256) public opportunitySell;
    uint256[] private activeBuyOpportunityStrikes;
    uint256[] private activeSellOpportunityStrikes;

    // Cost trackers for unwind buckets.
    mapping(uint256 => uint256) public unWindBuyCostA;
    mapping(uint256 => uint256) public unWindSellCostB;

    uint64 public currentEpochStart;
    uint64 public currentEpochExpiry;
    uint256 public currentAnchorPrice;
    bool public engineStarted;

    uint16 public opportunityBufferCutBps;
    uint16 public opportunityMinBufferBps;
    uint32 public epochDuration;
    uint16 public firstEpochBudgetScaleBps;
    uint16 public epochBudgetScaleStepBps;
    uint16 public maxEpochBudgetScaleBps;
    uint256 public minOrderA;
    uint256 public minOrderB;
    address public feePool;
    IDoppiPoints public doppiPoints;

    mapping(uint8 => uint256) public epochOriginalBuyByZone;
    mapping(uint8 => uint256) public epochOriginalSellByZone;

    struct EpochZoneInfo {
        uint8 zone;
        uint256 buyStrike;
        uint256 sellStrike;
        uint256 originalBuyAmount;
        uint256 originalSellAmount;
        uint256 remainingBuyOpportunity;
        uint256 remainingSellOpportunity;
    }

    event OrdersPlaced(uint64 indexed epochStart, uint64 indexed epochExpiry, uint256 anchorPrice, uint256 buyBudget, uint256 sellBudget);
    event OpportunityExecuted(bool indexed isBuy, uint256 indexed strikePrice, uint256 amountIn, uint256 amountOut, uint256 unwindStrike);
    event UnwindExecuted(bool indexed fromBuyBucket, uint256 amountIn, uint256 amountOut, uint256 profit);

    error AmountNotSpecified();
    error OnlyForwarder();
    error InvalidBps();
    error NoEnoughBalance();
    error RecordTradeFailed();

    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    function initialize(
        address _trader,
        IERC20 _assetA,
        IERC20 _assetB,
        address _doppiLP,
        address _doppiOffer,
        address _doppiPoints,
        uint24[] memory _weights
    ) external initializer {
        assetA = _assetA;
        assetB = _assetB;
        doppiLP = IDoppiLiquidity(_doppiLP);
        impliedVol = IDoppiOffer(_doppiOffer);
        doppiPoints = IDoppiPoints(_doppiPoints);
        validTrader = _trader;
        _transferOwnership(msg.sender);
    
        _initializeOrderConfigs(_weights);
        traderDefaultDay = 1;
        maxOrder = 5;
        maxSwap = 30000 ether;
        unwindGapMultiplier = 1;
        priceDecimals = 10 ** doppiLP.getPriceDecimals();
        epochDuration = 2 days;
        minOrderA = 50 ether;
        minOrderB = 0.0005 ether;
        opportunityBufferCutBps = 2000;
        opportunityMinBufferBps = 100;
        profitFeeBps = 2000;

        // Default to no behavior change. Budget ramp is opt-in via setBudgetRampParams.
        firstEpochBudgetScaleBps = 5000;
        epochBudgetScaleStepBps = 9000;
        maxEpochBudgetScaleBps = BPS * 3;
    }

    function start(uint256 _amountA, uint256 _amountB) external nonReentrant {
        _onlyTrader();
        if (_amountA == 0 && _amountB == 0) revert AmountNotSpecified();
        uint256 price = doppiLP.getPrice();
        if(price == 0) revert InvalidPrice();

        (uint256 currentBalanceA, uint256 currentBalanceB, ) = getTotalBalances();
        
        if (_amountA > 0) assetA.safeTransferFrom(msg.sender, address(this), _amountA);
        if (_amountB > 0) assetB.safeTransferFrom(msg.sender, address(this), _amountB);

        (uint256 finalAmountA, uint256 finalAmountB) = _performTopUp(_amountA, _amountB);
        _updateUnitAndCostBasis(finalAmountA, finalAmountB, currentBalanceA, currentBalanceB, price);

        engineStarted = true;
        _resetAndPlace(price);
    }

    function stop() external nonReentrant {
        _onlyTrader();
        engineStarted = false;
        _payStopProfitFees();
        _clearOpportunityOrders();
        _removeMapping();

        uint256 balanceA = assetA.balanceOf(address(this));
        uint256 balanceB = assetB.balanceOf(address(this));
        if (balanceA > 0) assetA.safeTransfer(msg.sender, balanceA);
        if (balanceB > 0) assetB.safeTransfer(msg.sender, balanceB);

        undoStat.undo_assetA = 0;
        undoStat.undo_assetB = 0;
        totalUnits = 0;
        totalUnitsB = 0;
        costBasis = 0;
        costBasisB = 0;
        currentEpochStart = 0;
        currentEpochExpiry = 0;
        currentAnchorPrice = 0;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        if (!engineStarted || paused() || s_forwarderAddress == address(0)) return (false, bytes(""));

        uint256 price = doppiLP.getPrice();
        if (price == 0) return (false, bytes(""));

        bool needUnwind = _hasTriggeredUnwind(price);
        bool needOpportunity = _hasTriggeredOpportunity(price);
        bool needPlace = _needPlaceOrders();

        upkeepNeeded = needUnwind || needOpportunity || needPlace;
        return (upkeepNeeded, abi.encode(""));
    }

    function performUpkeep(bytes calldata /* performData */) external override nonReentrant {
        _onlyForwarder();
        if (!engineStarted || paused()) return;

        uint256 price = doppiLP.getPrice();
        if (price == 0) return;

        bool needUnwind = _hasTriggeredUnwind(price);
        if(needUnwind){
            _performUnwindBuyBuckets(price);
            _performUnwindSellBuckets(price);
        }

        bool needOpportunity = _hasTriggeredOpportunity(price);
        if(needOpportunity){
            _performOpportunityBuy(price);
            _performOpportunitySell(price);            
        }

        bool needPlace = _needPlaceOrders();
        if (needPlace) {
            _resetAndPlace(price);
        }
    }

    function getOpportunityInfo(bool isBuy, uint256 strikePrice) external view returns (uint256) {
        return isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
    }

    function getEpochInfo() external view returns (uint64 epochStart, uint64 expiry, uint256 anchorPrice) {
        return (currentEpochStart, currentEpochExpiry, currentAnchorPrice);
    }

    function getEpochZoneInfo() external view returns (EpochZoneInfo[] memory zones) {
        uint256 gap = _priceGapWithDecimals();
        bool hasActiveAnchor = engineStarted && currentAnchorPrice > 0;

        if (hasActiveAnchor) {
            uint256 totalOffers = impliedVol.TOTAL_OFFER();
            uint256 maxZones = uint256(type(uint8).max) + 1;
            if (totalOffers > maxZones) totalOffers = maxZones;

            uint256 count;
            for (uint256 z = 0; z < totalOffers; ) {
                uint8 zone = uint8(z);
                if (epochOriginalBuyByZone[zone] > 0 || epochOriginalSellByZone[zone] > 0) {
                    unchecked {
                        ++count;
                    }
                }
                unchecked {
                    ++z;
                }
            }

            zones = new EpochZoneInfo[](count);
            uint256 idx;
            for (uint256 z = 0; z < totalOffers; ) {
                uint8 zone = uint8(z);
                uint256 originalBuyAmount = epochOriginalBuyByZone[zone];
                uint256 originalSellAmount = epochOriginalSellByZone[zone];
                if (originalBuyAmount > 0 || originalSellAmount > 0) {
                    uint256 buyStrike = currentAnchorPrice >= uint256(zone) * gap
                        ? currentAnchorPrice - (uint256(zone) * gap)
                        : 0;
                    uint256 sellStrike = currentAnchorPrice + ((uint256(zone) + 1) * gap);

                    zones[idx] = EpochZoneInfo({
                        zone: zone,
                        buyStrike: buyStrike,
                        sellStrike: sellStrike,
                        originalBuyAmount: originalBuyAmount,
                        originalSellAmount: originalSellAmount,
                        remainingBuyOpportunity: buyStrike == 0 ? 0 : opportunityBuy[buyStrike],
                        remainingSellOpportunity: opportunitySell[sellStrike]
                    });

                    unchecked {
                        ++idx;
                    }
                }
                unchecked {
                    ++z;
                }
            }
            return zones;
        }

        uint256 len = orderConfigs.length;
        zones = new EpochZoneInfo[](len);
        for (uint256 i = 0; i < len; ) {
            uint8 zone = orderConfigs[i].strikeZone;
            zones[i] = EpochZoneInfo({
                zone: zone,
                buyStrike: 0,
                sellStrike: 0,
                originalBuyAmount: 0,
                originalSellAmount: 0,
                remainingBuyOpportunity: 0,
                remainingSellOpportunity: 0
            });
            unchecked {
                ++i;
            }
        }
    }

    function setOpportunityBufferParams(uint16 _bufferCutBps, uint16 _minBufferBps) external {
        _onlyTrader();
        if (_bufferCutBps > BPS || _minBufferBps > BPS) revert InvalidBps();
        opportunityBufferCutBps = _bufferCutBps;
        opportunityMinBufferBps = _minBufferBps;
    }

    function setFeeConfig(address _feePool, uint16 _profitFeeBps) external onlyOwner {
        if (_profitFeeBps > 3000) revert InvalidBps();
        feePool = _feePool;
        profitFeeBps = _profitFeeBps;
    }

    function setEpochDuration(uint32 _epochDuration) external {
        _onlyTrader();
        require(_epochDuration > 1 days && _epochDuration < 15 days, "invalid epoch duration");
        epochDuration = _epochDuration;
    }

    function setMinOrder(uint256 _minOrderA, uint256 _minOrderB) external {
        _onlyTrader();
        minOrderA = _minOrderA;
        minOrderB = _minOrderB;
    }

    function setBudgetRampParams(
        uint16 _firstEpochBudgetScaleBps,
        uint16 _epochBudgetScaleStepBps,
        uint16 _maxEpochBudgetScaleBps
    ) external {
        _onlyTrader();
        if (_firstEpochBudgetScaleBps == 0 || _firstEpochBudgetScaleBps > BPS) revert InvalidBps();
        if (_maxEpochBudgetScaleBps == 0 || _maxEpochBudgetScaleBps > BPS * 5) revert InvalidBps();
        if (_firstEpochBudgetScaleBps > _maxEpochBudgetScaleBps) revert InvalidBps();
        if (_epochBudgetScaleStepBps > BPS) revert InvalidBps();

        firstEpochBudgetScaleBps = _firstEpochBudgetScaleBps;
        epochBudgetScaleStepBps = _epochBudgetScaleStepBps;
        maxEpochBudgetScaleBps = _maxEpochBudgetScaleBps;

        maxOrderPerRoundA = 0;
        maxOrderPerRoundB = 0;
    }

    function _performOpportunityBuy(uint256 price) internal {
        if (activeBuyOpportunityStrikes.length == 0) return;
        uint256 buffer = _getBufferAmount(price, true);
        uint256 maxIn = maxSwap;
        uint256 totalIn;

        uint256 length = activeBuyOpportunityStrikes.length;
        for (uint256 i = 0; i < length; ) {
            uint256 strike = activeBuyOpportunityStrikes[i];
            uint256 amount = opportunityBuy[strike];
            if (amount > 0 && price + buffer <= strike) {
                uint256 remaining = maxIn > totalIn ? maxIn - totalIn : 0;
                if (remaining == 0) break;
                uint256 toSwap = amount > remaining ? remaining : amount;
                _approveLPExact(assetA, toSwap);
                uint256 amountOut = doppiLP.swap(toSwap, price, true);
                _recordTradeVolumeInA(toSwap);
                opportunityBuy[strike] = amount - toSwap;
                totalIn += toSwap;

                unWindBuy[strike] += amountOut;
                unWindBuyCostA[strike] += toSwap;
                undoStat.undo_assetB += amountOut;
                _syncStrikeState(strike, true);

                emit OpportunityExecuted(true, strike, toSwap, amountOut, strike);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _performOpportunitySell(uint256 price) internal {
        if (activeSellOpportunityStrikes.length == 0) return;
        uint256 buffer = _getBufferAmount(price, false);
        uint256 maxIn = maxSwap * priceDecimals / price;
        uint256 totalIn;

        uint256 length = activeSellOpportunityStrikes.length;
        for (uint256 i = 0; i < length; ) {
            uint256 strike = activeSellOpportunityStrikes[i];
            uint256 amount = opportunitySell[strike];
            
            if (amount > 0 && price >= strike + buffer) {
                uint256 remaining = maxIn > totalIn ? maxIn - totalIn : 0;
                if (remaining == 0) break;
                uint256 toSwap = amount > remaining ? remaining : amount;
                _approveLPExact(assetB, toSwap);
                uint256 amountOut = doppiLP.swap(toSwap, price, false);
                _recordTradeVolumeInA((toSwap * price) / priceDecimals);
                opportunitySell[strike] = amount - toSwap;
                totalIn += toSwap;

                unWindSell[strike] += amountOut;
                unWindSellCostB[strike] += toSwap;
                undoStat.undo_assetA += amountOut;
                _syncStrikeState(strike, false);
                emit OpportunityExecuted(false, strike, toSwap, amountOut, strike);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _performUnwindBuyBuckets(uint256 price) internal {
        if (price == 0) return;

        uint256 maxIn = maxSwap * priceDecimals / price;
        uint256 totalIn;
        uint256 strikesCount;
        uint256[] memory strikes = new uint256[](activeBuyStrikeCount);
        uint256[] memory usedAmounts = new uint256[](activeBuyStrikeCount);

        uint256 strike = buyHead;
        while (strike != 0 && strike <= price) {
            uint256 nextStrike = buyStrikeNodes[strike].next;
            uint256 amount = unWindBuy[strike];
            if (amount > 0) {
                uint256 remaining = maxIn > totalIn ? maxIn - totalIn : 0;
                if (remaining == 0) break;
                uint256 used = amount > remaining ? remaining : amount;
                strikes[strikesCount] = strike;
                usedAmounts[strikesCount] = used;
                totalIn += used;
                unchecked {
                    ++strikesCount;
                }
            }
            strike = nextStrike;
        }

        if (totalIn == 0) return;
        _approveLPExact(assetB, totalIn);
        uint256 totalOut = doppiLP.swap(totalIn, price, false);
        _recordTradeVolumeInA((totalIn * price) / priceDecimals);

        uint256 outRemaining = totalOut;
        uint256 totalProfitA;
        for (uint256 i = 0; i < strikesCount; ) {
            uint256 s = strikes[i];
            uint256 used = usedAmounts[i];
            uint256 outShare = i + 1 == strikesCount ? outRemaining : (totalOut * used) / totalIn;
            if (outShare > outRemaining) outShare = outRemaining;
            outRemaining -= outShare;

            totalProfitA += _consumeUnwindBuyBucket(s, used, outShare);
            unchecked {
                ++i;
            }
        }

        emit UnwindExecuted(true, totalIn, totalOut, totalProfitA);
    }

    function _performUnwindSellBuckets(uint256 price) internal {
        uint256 maxIn = maxSwap;
        uint256 totalIn;
        uint256 strikesCount;
        uint256[] memory strikes = new uint256[](activeSellStrikeCount);
        uint256[] memory usedAmounts = new uint256[](activeSellStrikeCount);

        uint256 strike = sellTail;
        while (strike != 0 && strike >= price) {
            uint256 prevStrike = sellStrikeNodes[strike].prev;
            uint256 amount = unWindSell[strike];
            if (amount > 0) {
                uint256 remaining = maxIn > totalIn ? maxIn - totalIn : 0;
                if (remaining == 0) break;
                uint256 used = amount > remaining ? remaining : amount;
                strikes[strikesCount] = strike;
                usedAmounts[strikesCount] = used;
                totalIn += used;
                unchecked {
                    ++strikesCount;
                }
            }
            strike = prevStrike;
        }

        if (totalIn == 0) return;
        _approveLPExact(assetA, totalIn);
        uint256 totalOut = doppiLP.swap(totalIn, price, true);
        _recordTradeVolumeInA(totalIn);

        uint256 outRemaining = totalOut;
        uint256 totalProfitB;
        for (uint256 i = 0; i < strikesCount; ) {
            uint256 s = strikes[i];
            uint256 used = usedAmounts[i];
            uint256 outShare = i + 1 == strikesCount ? outRemaining : (totalOut * used) / totalIn;
            if (outShare > outRemaining) outShare = outRemaining;
            outRemaining -= outShare;

            totalProfitB += _consumeUnwindSellBucket(s, used, outShare);
            unchecked {
                ++i;
            }
        }

        emit UnwindExecuted(false, totalIn, totalOut, totalProfitB);
    }

    function _consumeUnwindBuyBucket(uint256 strike, uint256 amountInB, uint256 amountOutA) internal returns (uint256 profitA) {
        uint256 bucketAmount = unWindBuy[strike];
        uint256 bucketCostA = unWindBuyCostA[strike];
        if (bucketAmount == 0) return 0;

        uint256 costConsumedA = (bucketCostA * amountInB) / bucketAmount;
        unWindBuy[strike] = bucketAmount - amountInB;
        unWindBuyCostA[strike] = bucketCostA > costConsumedA ? bucketCostA - costConsumedA : 0;
        opportunityBuy[strike] += costConsumedA;
        undoStat.undo_assetB = undoStat.undo_assetB > amountInB ? undoStat.undo_assetB - amountInB : 0;
        _syncStrikeState(strike, true);

        if (amountOutA > costConsumedA) {
            profitA = amountOutA - costConsumedA;
            _payFee(address(assetA), profitA);
        }
    }

    function _consumeUnwindSellBucket(uint256 strike, uint256 amountInA, uint256 amountOutB) internal returns (uint256 profitB) {
        uint256 bucketAmount = unWindSell[strike];
        uint256 bucketCostB = unWindSellCostB[strike];
        if (bucketAmount == 0) return 0;

        uint256 costConsumedB = (bucketCostB * amountInA) / bucketAmount;
        unWindSell[strike] = bucketAmount - amountInA;
        unWindSellCostB[strike] = bucketCostB > costConsumedB ? bucketCostB - costConsumedB : 0;
        opportunitySell[strike] += costConsumedB;
        undoStat.undo_assetA = undoStat.undo_assetA > amountInA ? undoStat.undo_assetA - amountInA : 0;
        _syncStrikeState(strike, false);

        if (amountOutB > costConsumedB) {
            profitB = amountOutB - costConsumedB;
            _payFee(address(assetB), profitB);
        }
    }

    function _getUnwindEntryValue(bool isBuy, uint256 strikePrice, uint256 unwindAmount)
        internal
        view
        override
        returns (uint256)
    {
        uint256 trackedCost = isBuy ? unWindBuyCostA[strikePrice] : unWindSellCostB[strikePrice];
        if (trackedCost > 0 || unwindAmount == 0) return trackedCost;
        return super._getUnwindEntryValue(isBuy, strikePrice, unwindAmount);
    }

    function _getStopProfitEntryValue(bool isBuy, uint256 strikePrice, uint256)
        internal
        view
        override
        returns (uint256)
    {
        return isBuy ? unWindBuyCostA[strikePrice] : unWindSellCostB[strikePrice];
    }

    function _getFeePool() internal view override returns (address) {
        return feePool;
    }

    function _resetAndPlace(uint256 price) internal {
        _clearOpportunityOrders();
        _placeOrdersForEpoch(price);
    }

    function _placeOrdersForEpoch(uint256 price) internal {
        uint256 length = orderConfigs.length;
        if (length == 0) return;

        uint256 minA = minOrderA;
        uint256 minB = minOrderB;
        uint256 availableA = _availableBalance(true);
        uint256 availableB = _availableBalance(false);
        uint256 buyBudget = _getRoundBudget(true, availableA, minA, maxOrder);
        uint256 sellBudget = _getRoundBudget(false, availableB, minB, maxOrder);
        
        if(maxOrderPerRoundA == 0) {
            buyBudget = _applyBudgetRamp(buyBudget, true, availableA);
        }
        if(maxOrderPerRoundB == 0) {
            sellBudget = _applyBudgetRamp(sellBudget, false, availableB);
        }
        
        if (buyBudget == 0 && sellBudget == 0) return;
        
        uint256 gap = _priceGapWithDecimals();
        uint256 anchor = _roundPrice(price, gap);

        uint256 maxOrderLocal = maxOrder;
        uint256 maxSupportedZones = uint256(type(uint8).max) + 1;
        if (maxOrderLocal > maxSupportedZones) {
            maxOrderLocal = maxSupportedZones;
        }

        for (uint256 z = 0; z < maxOrderLocal; ) {
            uint8 zone = uint8(z);
            epochOriginalBuyByZone[zone] = 0;
            epochOriginalSellByZone[zone] = 0;
            unchecked {
                ++z;
            }
        }

        delete activeBuyOpportunityStrikes;
        delete activeSellOpportunityStrikes;

        for (uint256 i = 0; i < length; ) {
            uint256 zone = orderConfigs[i].strikeZone;
            uint256 weight = orderConfigs[i].weight;

            uint256 buyStrike = anchor >= zone * gap ? anchor - (zone * gap) : 0;
            if (buyStrike > 0 && buyBudget > 0) {
                uint256 amountA = (buyBudget * weight) / BPS;
                if (amountA >= minA) {
                    opportunityBuy[buyStrike] = amountA;
                    epochOriginalBuyByZone[uint8(zone)] = amountA;
                    activeBuyOpportunityStrikes.push(buyStrike);
                }
            }

            uint256 sellStrike = anchor + ((zone + 1) * gap);
            if (sellBudget > 0) {
                uint256 amountB = (sellBudget * weight) / BPS;
                if (amountB >= minB) {
                    opportunitySell[sellStrike] = amountB;
                    epochOriginalSellByZone[uint8(zone)] = amountB;
                    activeSellOpportunityStrikes.push(sellStrike);
                }
            }

            unchecked {
                ++i;
            }
        }

        currentAnchorPrice = anchor;
        currentEpochStart = uint64(block.timestamp);
        currentEpochExpiry = uint64(block.timestamp + (uint64(traderDefaultDay) * uint64(epochDuration)));
        emit OrdersPlaced(currentEpochStart, currentEpochExpiry, currentAnchorPrice, buyBudget, sellBudget);
    }

    function _applyBudgetRamp(
        uint256 baseBudget,
        bool isBuy,
        uint256 availableBalance
    )
        internal
        view
        returns (uint256)
    {
        if (baseBudget == 0 || availableBalance == 0) {
            return 0;
        }

        uint256 sideCostBasis = isBuy ? costBasis : costBasisB;

        if (sideCostBasis == 0) {
            return baseBudget;
        }

        uint256 drawdownBps = 0;

        if (availableBalance < sideCostBasis) {
            drawdownBps =
                ((sideCostBasis - availableBalance) * BPS)
                / sideCostBasis;
        }

        uint256 scaleBps =
            firstEpochBudgetScaleBps +
            (drawdownBps * 2 * epochBudgetScaleStepBps) / BPS;

        if (scaleBps > maxEpochBudgetScaleBps) {
            scaleBps = maxEpochBudgetScaleBps;
        }

        uint256 adjustedBudget =
            (baseBudget * scaleBps) / BPS;

        return adjustedBudget > availableBalance
            ? availableBalance
            : adjustedBudget;
    }

    function _clearOpportunityOrders() internal {
        for (uint256 i = 0; i < activeBuyOpportunityStrikes.length; ) {
            delete opportunityBuy[activeBuyOpportunityStrikes[i]];
            unchecked {
                ++i;
            }
        }
        for (uint256 i = 0; i < activeSellOpportunityStrikes.length; ) {
            delete opportunitySell[activeSellOpportunityStrikes[i]];
            unchecked {
                ++i;
            }
        }
        delete activeBuyOpportunityStrikes;
        delete activeSellOpportunityStrikes;
    }

    function _hasTriggeredOpportunity(uint256 price) internal view returns (bool) {
        if (activeBuyOpportunityStrikes.length == 0 && activeSellOpportunityStrikes.length == 0) return false;

        uint256 buyBuffer = _getBufferAmount(price, true);
        for (uint256 i = 0; i < activeBuyOpportunityStrikes.length; ) {
            uint256 strike = activeBuyOpportunityStrikes[i];
            if (opportunityBuy[strike] > 0 && price + buyBuffer <= strike) return true;
            unchecked {
                ++i;
            }
        }

        uint256 sellBuffer = _getBufferAmount(price, false);
        for (uint256 i = 0; i < activeSellOpportunityStrikes.length; ) {
            uint256 strike = activeSellOpportunityStrikes[i];
            if (opportunitySell[strike] > 0 && price >= strike + sellBuffer) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _hasTriggeredUnwind(uint256 price) internal view returns (bool) {
        if (price > 0) {
            uint256 strikeBuy = buyHead;
            while (strikeBuy != 0) {
                if (strikeBuy <= price && unWindBuy[strikeBuy] > 0) return true;
                strikeBuy = buyStrikeNodes[strikeBuy].next;
            }
        }

        uint256 strikeSell = sellTail;
        while (strikeSell != 0) {
            if (strikeSell >= price && unWindSell[strikeSell] > 0) return true;
            strikeSell = sellStrikeNodes[strikeSell].prev;
        }
        return false;
    }

    function _needPlaceOrders() internal view returns (bool) {
        if (currentEpochExpiry == 0) return true;
        return block.timestamp >= currentEpochExpiry;
    }

    function _getOrderWeight(uint256 index) internal view override returns (uint256) {
        return orderConfigs[index].weight;
    }

    function _getBufferAmount(uint256 price, bool isBuy) internal view returns (uint256) {
        uint256 oneDayBps = impliedVol.getOneDayBuffer(price, isBuy);
        if (oneDayBps == 0) {
            return price * opportunityMinBufferBps / BPS;
        }
        uint256 reduced = oneDayBps * (BPS - opportunityBufferCutBps) / BPS;
        uint256 effectiveBps = reduced > opportunityMinBufferBps ? reduced : opportunityMinBufferBps;
        
        return price * effectiveBps / BPS;
    }

    function _roundPrice(uint256 price, uint256 gap) internal pure returns (uint256) {
        return (price / gap) * gap;
    }

    function _priceGapWithDecimals() internal view returns (uint256) {
        return impliedVol.getPriceGapPerOffer() * priceDecimals;
    }

    function _recordTradeVolumeInA(uint256 volumeInA) internal {
        if (volumeInA == 0 || address(doppiPoints) == address(0) || doppiPoints.paused()) return;
        (bool ok, ) = address(doppiPoints).call(abi.encodeWithSelector(RECORD_SELECTOR, validTrader, volumeInA));
        if (!ok) revert RecordTradeFailed();
    }

    function _removeMapping() internal {
        uint256 strikePrice = buyHead;
        while (strikePrice != 0) {
            uint256 nextStrike = buyStrikeNodes[strikePrice].next;
            delete unWindBuy[strikePrice];
            delete unWindBuyCostA[strikePrice];
            delete buyStrikeNodes[strikePrice];
            strikePrice = nextStrike;
        }

        strikePrice = sellHead;
        while (strikePrice != 0) {
            uint256 nextStrike = sellStrikeNodes[strikePrice].next;
            delete unWindSell[strikePrice];
            delete unWindSellCostB[strikePrice];
            delete sellStrikeNodes[strikePrice];
            strikePrice = nextStrike;
        }

        buyHead = 0;
        buyTail = 0;
        sellHead = 0;
        sellTail = 0;
        activeBuyStrikeCount = 0;
        activeSellStrikeCount = 0;

        uint256 maxOrderLocal = maxOrder;
        uint256 maxSupportedZones = uint256(type(uint8).max) + 1;
        if (maxOrderLocal > maxSupportedZones) {
            maxOrderLocal = maxSupportedZones;
        }

        for (uint256 z = 0; z < maxOrderLocal; ) {
            uint8 zone = uint8(z);
            epochOriginalBuyByZone[zone] = 0;
            epochOriginalSellByZone[zone] = 0;
            unchecked {
                ++z;
            }
        }
    }

    function _onlyForwarder() internal view {
        if (msg.sender != s_forwarderAddress) revert OnlyForwarder();
    }

    function _approveLPExact(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        token.forceApprove(address(doppiLP), amount);
    }
}
