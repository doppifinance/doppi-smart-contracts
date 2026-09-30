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
import {DoppiTraderAdminView} from "../DoppiTraderAdminView.sol";

contract DoppiSimpleTrader is DoppiTraderAdminView, ReentrancyGuard, AutomationCompatibleInterface, Initializable {
    using SafeERC20 for IERC20;

    uint16 private constant BPS = 10000;
    bytes4 private constant RECORD_SELECTOR = bytes4(keccak256("recordTrade(address,uint256)"));

    mapping(uint256 => uint256) public unWindBuyCostA;
    mapping(uint256 => uint256) public unWindSellCostB;

    uint256 public nextBuyTriggerPrice;
    uint256 public nextSellTriggerPrice;
    uint256 public lastBuyPlacedPrice;
    uint256 public lastSellPlacedPrice;
    uint16 public firstOrderScaleBps;
    uint16 public orderCountMultiplierBps; 
    uint16 public triggerRefreshThresholdBps;
    uint16 public opportunityBufferCutBps;
    uint16 public opportunityMinBufferBps;
    uint256 public minOrderA;
    uint256 public minOrderB;
    address public feePool;
    IDoppiPoints public doppiPoints;

    uint256 public buyCostAOutstanding;
    uint256 public buyQtyBOutstanding;
    uint256 public sellProceedsAOutstanding;
    uint256 public sellQtyBOutstanding;

    uint256 public openBuyOrderCount;
    uint256 public openSellOrderCount;

    bool public engineStarted;

    struct PositionInfo {
        bool engineStarted;
        uint256 currentBuyPosition;
        uint256 currentSellPosition;
        uint256 pendingUnwindBuy;
        uint256 pendingUnwindSell;
        uint256 averageBuyPrice;
        uint256 averageSellPrice;
        uint256 nextBuyPrice;
        uint256 nextSellPrice;
    }

    event TriggerInitialized(uint256 buyTrigger, uint256 sellTrigger);
    event OrderPlaced(bool indexed isBuy, uint256 indexed executionPrice, uint256 amountIn, uint256 amountOut, uint256 nextTrigger);
    event UnwindExecuted(bool indexed fromBuyBucket, uint256 amountIn, uint256 amountOut, uint256 profit);
    event ResetTriggerPrice(uint256 nextTriggerBuyOld, uint256 nextTriggerSellOld, uint256 nextTriggerBuy, uint256 nextTriggerSell);
    
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
        address _doppiPoints
    ) external initializer {
        assetA = _assetA;
        assetB = _assetB;
        doppiLP = IDoppiLiquidity(_doppiLP);
        impliedVol = IDoppiOffer(_doppiOffer);
        doppiPoints = IDoppiPoints(_doppiPoints);
        validTrader = _trader;
        _transferOwnership(msg.sender);

        maxSwap = 10000 ether;
        priceDecimals = 10 ** doppiLP.getPriceDecimals();

        minOrderA = 50 ether;
        minOrderB = 0.0005 ether;
        opportunityBufferCutBps = 1000;
        opportunityMinBufferBps = 100;
        profitFeeBps = 2000;
        firstOrderScaleBps = 6000;
        orderCountMultiplierBps = 1000;
        triggerRefreshThresholdBps = 500;
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
        nextBuyTriggerPrice = _lowerTriggerPrice(price);
        nextSellTriggerPrice = _upperTriggerPrice(price);

    }

    function stop() external nonReentrant {
        _onlyTrader();
        engineStarted = false;
        _payStopProfitFees();

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
        nextBuyTriggerPrice = 0;
        nextSellTriggerPrice = 0;
        lastBuyPlacedPrice = 0;
        lastSellPlacedPrice = 0;
        buyCostAOutstanding = 0;
        buyQtyBOutstanding = 0;
        sellProceedsAOutstanding = 0;
        sellQtyBOutstanding = 0;
        openSellOrderCount = 0;
        openBuyOrderCount = 0;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        if (!engineStarted || paused() || s_forwarderAddress == address(0)) return (false, bytes(""));

        uint256 price = doppiLP.getPrice();
        if (price == 0) return (false, bytes(""));

        uint256 buyOrderAmount = _getRoundBudget(true);
        uint256 sellOrderAmount = _getRoundBudget(false);

        bool placeBuy = price <= nextBuyTriggerPrice && buyOrderAmount >= minOrderA;
        bool placeSell = price >= nextSellTriggerPrice && sellOrderAmount >= minOrderB;
        bool unwindBuy = _shouldUnwindBuy(price);
        bool unwindSell = _shouldUnwindSell(price);
        bool refreshTriggers = _shouldResetTriggers(price);

        upkeepNeeded = placeBuy || placeSell || unwindBuy || unwindSell || refreshTriggers;
        performData = abi.encode(placeBuy, placeSell, unwindBuy, unwindSell, refreshTriggers);
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant {
        _onlyForwarder();
        if (!engineStarted || paused()) return;

        uint256 price = doppiLP.getPrice();
        if (price == 0) return;

        (bool placeBuy, bool placeSell, bool unwindBuy, bool unwindSell, bool refreshTriggers) =
            abi.decode(performData, (bool, bool, bool, bool, bool));

        if (unwindBuy && _shouldUnwindBuy(price)) {
            _performUnwindBuyBuckets(price);
        }

        if (unwindSell && _shouldUnwindSell(price)) {
            _performUnwindSellBuckets(price);
        }
        
        if (placeBuy && price <= nextBuyTriggerPrice) {
            _executeBuyOrder(price);
        }

        if (placeSell && price >= nextSellTriggerPrice) {
            _executeSellOrder(price);
        }

        if (refreshTriggers && _shouldResetTriggers(price)) {
            _refreshEntryTriggers(price);
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

    function setAutoBudgetAggressive(uint16 _firstOrderScaleBps, uint16 _orderCountMultiplierBps) external {
        _onlyTrader();
        if (_firstOrderScaleBps > BPS || _orderCountMultiplierBps > BPS) revert InvalidBps();
        firstOrderScaleBps = _firstOrderScaleBps;
        orderCountMultiplierBps = _orderCountMultiplierBps;
        maxOrderPerRoundA = 0;
        maxOrderPerRoundB = 0;
    }

    function setTriggerRefreshThresholdBps(uint16 bps) external {
        _onlyTrader();
        if (bps > BPS) revert InvalidBps();
        triggerRefreshThresholdBps = bps;
    }

    function refreshEntryTriggers() external {
        _onlyTrader();
        uint256 price = doppiLP.getPrice();
        if(price == 0) revert InvalidPrice();
        _refreshEntryTriggers(price);
    }
    
    function setMinOrder(uint256 _minOrderA, uint256 _minOrderB) external {
        _onlyTrader();
        minOrderA = _minOrderA;
        minOrderB = _minOrderB;
    }

    function getAveragePrices() external view returns (uint256 avgBuyEntryPrice, uint256 avgSellEntryPrice) {
        avgBuyEntryPrice = _averageBuyEntryPrice();
        avgSellEntryPrice = _averageSellEntryPrice();
    }

    function getNextOrderAmount(bool isBuy) external view returns (uint256) {
        return _getRoundBudget(isBuy);
    }

    function getUnwindTriggerPrices() external view returns (uint256 buyUnwindTrigger, uint256 sellUnwindTrigger) {
        uint256 avgBuy = _averageBuyEntryPrice();
        uint256 avgSell = _averageSellEntryPrice();
        buyUnwindTrigger = avgBuy == 0 ? 0 : _upperTriggerPrice(avgBuy);
        sellUnwindTrigger = avgSell == 0 ? 0 : _lowerTriggerPrice(avgSell);
    }

    function getPositionInfo() external view returns (PositionInfo memory info) {
        info.engineStarted = engineStarted;
        info.currentBuyPosition = buyQtyBOutstanding;
        info.currentSellPosition = sellProceedsAOutstanding;
        info.pendingUnwindBuy = undoStat.undo_assetB;
        info.pendingUnwindSell = undoStat.undo_assetA;
        info.averageBuyPrice = _averageBuyEntryPrice();
        info.averageSellPrice = _averageSellEntryPrice();
        info.nextBuyPrice = nextBuyTriggerPrice;
        info.nextSellPrice = nextSellTriggerPrice;
    }

    function _canResetTriggers() internal view returns (bool) {
        return
            openBuyOrderCount == 0 &&
            openSellOrderCount == 0 &&
            undoStat.undo_assetA == 0 &&
            undoStat.undo_assetB == 0;
    }

    function _shouldResetTriggers(uint256 currentPrice)
        internal
        view
        returns (bool)
    {
        if (!_canResetTriggers()) return false;

        uint256 expectedBuy = _lowerTriggerPrice(currentPrice);
        uint256 expectedSell = _upperTriggerPrice(currentPrice);

        uint256 buyDiff =
            nextBuyTriggerPrice > expectedBuy
                ? nextBuyTriggerPrice - expectedBuy
                : expectedBuy - nextBuyTriggerPrice;

        uint256 sellDiff =
            nextSellTriggerPrice > expectedSell
                ? nextSellTriggerPrice - expectedSell
                : expectedSell - nextSellTriggerPrice;

        return
            buyDiff * BPS / currentPrice >= triggerRefreshThresholdBps ||
            sellDiff * BPS / currentPrice >= triggerRefreshThresholdBps;
    }

    function _executeBuyOrder(uint256 price) internal {
        uint256 amountInA = _getRoundBudget(true);
        if (amountInA < minOrderA) return;

        bool wasEmpty = unWindBuy[price] == 0;

        _approveLPExact(assetA, amountInA);
        uint256 amountOutB = doppiLP.swap(amountInA, price, true);
        _recordTradeVolumeInA(amountInA);

        unWindBuy[price] += amountOutB;
        unWindBuyCostA[price] += amountInA;
        undoStat.undo_assetB += amountOutB;
        _syncStrikeState(price, true);

        buyCostAOutstanding += amountInA;
        buyQtyBOutstanding += amountOutB;

        if (wasEmpty) {
            unchecked {
                ++openBuyOrderCount;
            }
        }

        lastBuyPlacedPrice = price;
        nextBuyTriggerPrice = _lowerPlacementTriggerPrice(price, true);
        
        emit OrderPlaced(true, price, amountInA, amountOutB, nextBuyTriggerPrice);
    }

    function _executeSellOrder(uint256 price) internal {
        uint256 amountInB = _getRoundBudget(false);
        if (amountInB < minOrderB) return;

        bool wasEmpty = unWindSell[price] == 0;

        _approveLPExact(assetB, amountInB);
        uint256 amountOutA = doppiLP.swap(amountInB, price, false);
        _recordTradeVolumeInA((amountInB * price) / priceDecimals);

        unWindSell[price] += amountOutA;
        unWindSellCostB[price] += amountInB;
        undoStat.undo_assetA += amountOutA;
        _syncStrikeState(price, false);

        sellProceedsAOutstanding += amountOutA;
        sellQtyBOutstanding += amountInB;
        if (wasEmpty) {
            unchecked {
                ++openSellOrderCount;
            }
        }

        lastSellPlacedPrice = price;
        nextSellTriggerPrice = price + _placementBufferAmount(price, false);


        emit OrderPlaced(false, price, amountInB, amountOutA, nextSellTriggerPrice);
    }

    function _performUnwindBuyBuckets(uint256 price) internal {
        uint256 maxInB = maxSwap * priceDecimals / price;
        uint256 totalInB;
        uint256 strikesCount;
        uint256[] memory strikes = new uint256[](activeBuyStrikeCount);
        uint256[] memory usedAmounts = new uint256[](activeBuyStrikeCount);

        uint256 strike = buyHead;
        while (strike != 0) {
            uint256 nextStrike = buyStrikeNodes[strike].next;
            uint256 amount = unWindBuy[strike];
            if (amount > 0) {
                uint256 remaining = maxInB > totalInB ? maxInB - totalInB : 0;
                if (remaining == 0) break;
                uint256 used = amount > remaining ? remaining : amount;
                strikes[strikesCount] = strike;
                usedAmounts[strikesCount] = used;
                totalInB += used;
                unchecked {
                    ++strikesCount;
                }
            }
            strike = nextStrike;
        }

        if (totalInB == 0) return;
        _approveLPExact(assetB, totalInB);
        uint256 totalOutA = doppiLP.swap(totalInB, price, false);
        _recordTradeVolumeInA((totalInB * price) / priceDecimals);

        uint256 outRemaining = totalOutA;
        uint256 totalProfitA;
        for (uint256 i = 0; i < strikesCount; ) {
            uint256 s = strikes[i];
            uint256 used = usedAmounts[i];
            uint256 outShare = i + 1 == strikesCount ? outRemaining : (totalOutA * used) / totalInB;
            if (outShare > outRemaining) outShare = outRemaining;
            outRemaining -= outShare;

            totalProfitA += _consumeUnwindBuyBucket(s, used, outShare);
            unchecked {
                ++i;
            }
        }

        _refreshEntryTriggers(price);

        emit UnwindExecuted(true, totalInB, totalOutA, totalProfitA);
    }

    function _performUnwindSellBuckets(uint256 price) internal {
        uint256 maxInA = maxSwap;
        uint256 totalInA;
        uint256 strikesCount;
        uint256[] memory strikes = new uint256[](activeSellStrikeCount);
        uint256[] memory usedAmounts = new uint256[](activeSellStrikeCount);

        uint256 strike = sellHead;
        while (strike != 0) {
            uint256 nextStrike = sellStrikeNodes[strike].next;
            uint256 amount = unWindSell[strike];
            if (amount > 0) {
                uint256 remaining = maxInA > totalInA ? maxInA - totalInA : 0;
                if (remaining == 0) break;
                uint256 used = amount > remaining ? remaining : amount;
                strikes[strikesCount] = strike;
                usedAmounts[strikesCount] = used;
                totalInA += used;
                unchecked {
                    ++strikesCount;
                }
            }
            strike = nextStrike;
        }

        if (totalInA == 0) return;
        _approveLPExact(assetA, totalInA);
        uint256 totalOutB = doppiLP.swap(totalInA, price, true);
        _recordTradeVolumeInA(totalInA);

        uint256 outRemaining = totalOutB;
        uint256 totalProfitB;
        for (uint256 i = 0; i < strikesCount; ) {
            uint256 s = strikes[i];
            uint256 used = usedAmounts[i];
            uint256 outShare = i + 1 == strikesCount ? outRemaining : (totalOutB * used) / totalInA;
            if (outShare > outRemaining) outShare = outRemaining;
            outRemaining -= outShare;

            totalProfitB += _consumeUnwindSellBucket(s, used, outShare);
            unchecked {
                ++i;
            }
        }

        _refreshEntryTriggers(price);

        emit UnwindExecuted(false, totalInA, totalOutB, totalProfitB);
    }

    function _consumeUnwindBuyBucket(uint256 strike, uint256 amountInB, uint256 amountOutA) internal returns (uint256 profitA) {
        uint256 bucketAmountB = unWindBuy[strike];
        uint256 bucketCostA = unWindBuyCostA[strike];
        if (bucketAmountB == 0) return 0;

        uint256 costConsumedA = (bucketCostA * amountInB) / bucketAmountB;

        unWindBuy[strike] = bucketAmountB - amountInB;
        unWindBuyCostA[strike] = bucketCostA > costConsumedA ? bucketCostA - costConsumedA : 0;
        undoStat.undo_assetB = undoStat.undo_assetB > amountInB ? undoStat.undo_assetB - amountInB : 0;
        _syncStrikeState(strike, true);

        buyCostAOutstanding = buyCostAOutstanding > costConsumedA ? buyCostAOutstanding - costConsumedA : 0;
        buyQtyBOutstanding = buyQtyBOutstanding > amountInB ? buyQtyBOutstanding - amountInB : 0;

        if (unWindBuy[strike] == 0 && openBuyOrderCount > 0) {
            unchecked {
                --openBuyOrderCount;
            }
        }

        if (amountOutA > costConsumedA) {
            profitA = amountOutA - costConsumedA;
            _payFee(address(assetA), profitA);
        }
    }

    function _consumeUnwindSellBucket(uint256 strike, uint256 amountInA, uint256 amountOutB) internal returns (uint256 profitB) {
        uint256 bucketAmountA = unWindSell[strike];
        uint256 bucketCostB = unWindSellCostB[strike];
        if (bucketAmountA == 0) return 0;

        uint256 costConsumedB = (bucketCostB * amountInA) / bucketAmountA;

        unWindSell[strike] = bucketAmountA - amountInA;
        unWindSellCostB[strike] = bucketCostB > costConsumedB ? bucketCostB - costConsumedB : 0;
        undoStat.undo_assetA = undoStat.undo_assetA > amountInA ? undoStat.undo_assetA - amountInA : 0;
        _syncStrikeState(strike, false);

        sellProceedsAOutstanding = sellProceedsAOutstanding > amountInA ? sellProceedsAOutstanding - amountInA : 0;
        sellQtyBOutstanding = sellQtyBOutstanding > costConsumedB ? sellQtyBOutstanding - costConsumedB : 0;

        if (unWindSell[strike] == 0 && openSellOrderCount > 0) {
            unchecked {
                --openSellOrderCount;
            }
        }
        
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

    function _recordTradeVolumeInA(uint256 volumeInA) internal {
        if (volumeInA == 0 || address(doppiPoints) == address(0) || doppiPoints.paused()) return;
        (bool ok, ) = address(doppiPoints).call(abi.encodeWithSelector(RECORD_SELECTOR, validTrader, volumeInA));
        if (!ok) revert RecordTradeFailed();
    }

    function _getRoundBudget(bool isBuy) internal view returns (uint256) {
        uint256 availableBalance = _availableBalance(isBuy);
        if (availableBalance == 0) return 0;

        uint256 minOrder = isBuy ? minOrderA : minOrderB;
        uint256 amountToTrade = isBuy ? maxOrderPerRoundA : maxOrderPerRoundB;

        if(amountToTrade > 0) return amountToTrade;

        uint256 sideHint = isBuy ? 1 : 2;
        amountToTrade = _getAutoRoundBudget(availableBalance, minOrder, sideHint);            
        
        if (amountToTrade > 0) {
            uint256 baseBudget = availableBalance < amountToTrade ? availableBalance : amountToTrade;
            uint256 candidateBudget = (baseBudget * _nextOrderMultiplierBps(isBuy)) / BPS;
            uint256 maxSwapForSide = _getSideMaxSwap(isBuy);

            // In capped mode, maxOrderPerRound remains the hard ceiling.
            if (candidateBudget > baseBudget) candidateBudget = baseBudget;
            if (candidateBudget > maxSwapForSide) candidateBudget = maxSwapForSide;
            return candidateBudget;
        }

        return 0;
    }

    function _getAutoRoundBudget(uint256 availableBalance, uint256 minOrder, uint256 sideHint)
        internal
        view
        override
        returns (uint256 budget)
    {
        if (availableBalance == 0) return 0;
        bool isBuy = sideHint != 2;
        uint256 currentOpenCount = isBuy ? openBuyOrderCount : openSellOrderCount;
        uint256 maxSwapForSide = _getSideMaxSwap(isBuy);

        if (currentOpenCount >= 5) {
            return availableBalance > maxSwapForSide ? maxSwapForSide : availableBalance;
        }

        uint256 loop = 5 - currentOpenCount;
        for (uint256 split = loop; split > 0; ) {
            uint256 candidateBudget = availableBalance / split;
            if (candidateBudget >= minOrder) {
                return candidateBudget > maxSwapForSide ? maxSwapForSide : candidateBudget;
            }
            unchecked {
                --split;
            }
        }

        return 0;
    }

    function _nextOrderMultiplierBps(bool isBuy) internal view returns (uint256) {
        uint256 currentOpenCount = isBuy ? openBuyOrderCount : openSellOrderCount;
        uint256 nextOrderIndex = currentOpenCount + 1;
        if (nextOrderIndex > 4) nextOrderIndex = 4;
        return firstOrderScaleBps + ((nextOrderIndex - 1) * orderCountMultiplierBps);
    }

    function _getOrderWeight(uint256) internal pure override returns (uint256) {
        return 0;
    }

    function _bufferAmount(uint256 price, bool isBuy) internal view returns (uint256) {
        uint256 oneDayBps = impliedVol.getOneDayBuffer(price, isBuy);
        if (oneDayBps == 0) {
            return (price * opportunityMinBufferBps) / BPS;
        }
        uint256 reduced = (oneDayBps * (BPS - opportunityBufferCutBps)) / BPS;
        uint256 effectiveBps = reduced > opportunityMinBufferBps ? reduced : opportunityMinBufferBps;
        return (price * effectiveBps) / BPS;
    }

    function _lowerTriggerPrice(uint256 referencePrice) internal view returns (uint256) {
        uint256 buffer = _bufferAmount(referencePrice, true);
        return referencePrice > buffer ? referencePrice - buffer : 0;
    }

    function _upperTriggerPrice(uint256 referencePrice) internal view returns (uint256) {
        return referencePrice + _bufferAmount(referencePrice, false);
    }

    function _averageBuyEntryPrice() internal view returns (uint256) {
        if (buyQtyBOutstanding == 0) return 0;
        return (buyCostAOutstanding * priceDecimals) / buyQtyBOutstanding;
    }

    function _averageSellEntryPrice() internal view returns (uint256) {
        if (sellQtyBOutstanding == 0) return 0;
        return (sellProceedsAOutstanding * priceDecimals) / sellQtyBOutstanding;
    }

    function _shouldUnwindBuy(uint256 currentPrice) internal view returns (bool) {
        uint256 avgBuy = _averageBuyEntryPrice();
        if (avgBuy == 0) return false;
        uint256 unwindTrigger = _upperTriggerPrice(avgBuy);
        return currentPrice >= unwindTrigger;
    }

    function _shouldUnwindSell(uint256 currentPrice) internal view returns (bool) {
        uint256 avgSell = _averageSellEntryPrice();
        if (avgSell == 0) return false;
        uint256 unwindTrigger = _lowerTriggerPrice(avgSell);
        return currentPrice <= unwindTrigger;
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
    }

    function _placementBufferAmount(uint256 price, bool isBuy) internal view returns (uint256) {
        
        uint256 baseBuffer = _bufferAmount(price, isBuy); // volatility-based
        uint256 count = isBuy ? openBuyOrderCount : openSellOrderCount;
        uint256 multiplier = BPS + (count * 2 * orderCountMultiplierBps);
        return (baseBuffer * multiplier) / BPS;
    }

    function _lowerPlacementTriggerPrice(uint256 referencePrice, bool isBuy) internal view returns (uint256) {
        uint256 buffer = _placementBufferAmount(referencePrice, isBuy);
        return referencePrice > buffer ? referencePrice - buffer : 0;
    }

    function _refreshEntryTriggers(uint256 referencePrice) internal {

        uint256 adjustedBuffer = _bufferAmount(referencePrice, true) * 2;
        nextBuyTriggerPrice = referencePrice > adjustedBuffer ? referencePrice - adjustedBuffer : 0;

        adjustedBuffer = _bufferAmount(referencePrice, false) * 2;
        nextSellTriggerPrice = referencePrice + adjustedBuffer;
        
    }

    function _onlyForwarder() internal view {
        if (msg.sender != s_forwarderAddress) revert OnlyForwarder();
    }

    function _approveLPExact(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        token.forceApprove(address(doppiLP), amount);
    }
}
