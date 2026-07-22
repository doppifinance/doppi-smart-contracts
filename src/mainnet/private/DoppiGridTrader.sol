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
import {OrderConfig, UndoStat} from "../DoppiTraderTypes.sol";
import {DoppiTraderAdminView} from "../DoppiTraderAdminView.sol";
// import "forge-std/console.sol";

contract DoppiGridTrader is DoppiTraderAdminView, ReentrancyGuard, AutomationCompatibleInterface, Initializable {
    using SafeERC20 for IERC20;

    uint16 private constant BPS = 10000;
    bytes4 private constant RECORD_SELECTOR = bytes4(keccak256("recordTrade(address,uint256)"));
    bytes4 private constant FEE_POOL_NOTIFY_SELECTOR = bytes4(keccak256("onFeeReceived(address,uint256)"));
    OrderConfig[] public orderConfigs;
    UndoStat public undoStat;

    mapping(uint256 => uint256) public opportunityBuy;
    mapping(uint256 => uint256) public opportunitySell;
    mapping(uint256 => uint8) private buyStrikeZone;
    mapping(uint256 => uint8) private sellStrikeZone;
    uint256[] private activeBuyOpportunityStrikes;
    uint256[] private activeSellOpportunityStrikes;

    // Cost trackers for unwind buckets.
    // unWindBuy (amount in assetB) cost is tracked in assetA.
    // unWindSell (amount in assetA) cost is tracked in assetB.
    mapping(uint256 => uint256) public unWindBuyCostA;
    mapping(uint256 => uint256) public unWindSellCostB;

    uint64 public currentEpochStart;
    uint64 public currentEpochExpiry;
    uint256 public currentAnchorPrice;
    bool public engineStarted;

    uint16 public opportunityBufferCutBps;
    uint16 public opportunityMinBufferBps;
    uint16 public profitFeeBps;
    uint32 public epochDuration;
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
    event FeePaid(address indexed token, uint256 amount);

    error ArrayMismatch();
    error MaxLimit();
    error MustHundred();
    error ExceedMaxZone();
    error AmountNotSpecified();
    error OnlyForwarder();
    error InvalidBps();
    error NoEnoughBalance();
    error RecordTradeFailed();
    error InvalidPrice();

    constructor() Ownable(msg.sender) {}

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

        assetA.safeIncreaseAllowance(_doppiLP, type(uint256).max);
        assetB.safeIncreaseAllowance(_doppiLP, type(uint256).max);
    
        _initializeOrderConfigs(_weights);
        traderDefaultDay = 1;
        maxOrder = 5;
        ratioLP = 0;
        maxSwap = 50000 ether;
        unwindGapMultiplier = 1;
        priceDecimals = 10 ** doppiLP.getPriceDecimals();
        epochDuration = 1 days;
        minOrderA = 50 ether;
        minOrderB = 0.0005 ether;
        opportunityBufferCutBps = 3000;
        opportunityMinBufferBps = 100;
        profitFeeBps = 2000;
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

    function placeOrders() external nonReentrant {
        _onlyTrader();
        uint256 price = doppiLP.getPrice();
        if (_availableBalance(true) == 0 && _availableBalance(false) == 0) revert NoEnoughBalance();
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
        return (upkeepNeeded, abi.encode(needUnwind, needOpportunity, needPlace));
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant {
        _onlyForwarder();
        if (!engineStarted || paused()) return;

        uint256 price = doppiLP.getPrice();
        if (price == 0) return;

        (bool needUnwind, bool needOpportunity, bool needPlace) = 
            abi.decode(performData, (bool, bool, bool));

        if(needUnwind){
            _performUnwindBuyBuckets(price);
            _performUnwindSellBuckets(price);
        }
        if(needOpportunity){
            _performOpportunityBuy(price);
            _performOpportunitySell(price);            
        }

        if (needPlace && _needPlaceOrders()) {
            _resetAndPlace(price);
        }
    }

    function setMultipleOrderConfigs(uint8[] calldata strikeZones, uint24[] calldata weights) external {
        _onlyTrader();
        if (strikeZones.length != weights.length) revert ArrayMismatch();
        if (strikeZones.length > maxOrder || weights.length > maxOrder) revert MaxLimit();

        uint24 sum = DALiquidityLib.sumArray(weights);
        if (sum != BPS) revert MustHundred();

        delete orderConfigs;
        for (uint256 i = 0; i < weights.length; ) {
            if (strikeZones[i] >= maxOrder) revert ExceedMaxZone();
            orderConfigs.push(OrderConfig(strikeZones[i], weights[i]));
            unchecked {
                ++i;
            }
        }
    }

    function getOrderConfigs() external view returns (OrderConfig[] memory) {
        return orderConfigs;
    }

    function getOpportunityInfo(bool isBuy, uint256 strikePrice) external view returns (uint256) {
        return isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
    }

    function getEpochInfo() external view returns (uint64 epochStart, uint64 expiry, uint256 anchorPrice) {
        return (currentEpochStart, currentEpochExpiry, currentAnchorPrice);
    }

    function getEpochZoneInfo() external view returns (EpochZoneInfo[] memory zones) {
        uint256 len = orderConfigs.length;
        zones = new EpochZoneInfo[](len);
        uint256 gap = _priceGapWithDecimals();
        bool hasActiveAnchor = engineStarted && currentAnchorPrice > 0;

        for (uint256 i = 0; i < len; ) {
            uint8 zone = orderConfigs[i].strikeZone;
            uint256 buyStrike;
            uint256 sellStrike;
            if (hasActiveAnchor) {
                buyStrike = currentAnchorPrice >= uint256(zone) * gap ? currentAnchorPrice - (uint256(zone) * gap) : 0;
                sellStrike = currentAnchorPrice + ((uint256(zone) + 1) * gap);
            }

            zones[i] = EpochZoneInfo({
                zone: zone,
                buyStrike: buyStrike,
                sellStrike: sellStrike,
                originalBuyAmount: epochOriginalBuyByZone[zone],
                originalSellAmount: epochOriginalSellByZone[zone],
                remainingBuyOpportunity: buyStrike == 0 ? 0 : opportunityBuy[buyStrike],
                remainingSellOpportunity: opportunitySell[sellStrike]
            });

            unchecked {
                ++i;
            }
        }
    }

    function setOpportunityBufferParams(uint16 _bufferCutBps, uint16 _minBufferBps) external {
        _onlyTraderOrOwner();
        if (_bufferCutBps > BPS || _minBufferBps > BPS) revert InvalidBps();
        opportunityBufferCutBps = _bufferCutBps;
        opportunityMinBufferBps = _minBufferBps;
    }

    function setFeeConfig(address _feePool, uint16 _profitFeeBps) external onlyOwner {
        if (_profitFeeBps > BPS) revert InvalidBps();
        feePool = _feePool;
        profitFeeBps = _profitFeeBps;
    }

    function setEpochDuration(uint32 _epochDuration) external {
        _onlyTraderOrOwner();
        require(_epochDuration > 0, "invalid epoch duration");
        epochDuration = _epochDuration;
    }

    function setMinOrder(uint256 _minOrderA, uint256 _minOrderB) external {
        _onlyTraderOrOwner();
        minOrderA = _minOrderA;
        minOrderB = _minOrderB;
    }

    function setOffer(address _offer) external onlyOwner {
        impliedVol = IDoppiOffer(_offer);
    }

    function _performOpportunityBuy(uint256 price) internal {
        if (activeBuyOpportunityStrikes.length == 0) return;
        uint256 gap = _priceGapWithDecimals();
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
                uint256 amountOut = doppiLP.swap(toSwap, price, true);
                _recordTradeVolumeInA(toSwap);
                opportunityBuy[strike] = amount - toSwap;
                totalIn += toSwap;

                uint8 zone = buyStrikeZone[strike];
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
        uint256 gap = _priceGapWithDecimals();
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
                uint256 amountOut = doppiLP.swap(toSwap, price, false);
                _recordTradeVolumeInA((toSwap * price) / priceDecimals);
                opportunitySell[strike] = amount - toSwap;
                totalIn += toSwap;
                uint8 zone = sellStrikeZone[strike];

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
        uint256 threshold = price > _getBufferAmount(price, false) ? price - _getBufferAmount(price, false) : 0;
        if (threshold == 0) return;

        uint256 maxIn = maxSwap * priceDecimals / price;
        uint256 totalIn;
        uint256 strikesCount;
        uint256[] memory strikes = new uint256[](activeBuyStrikeCount);
        uint256[] memory usedAmounts = new uint256[](activeBuyStrikeCount);

        uint256 strike = buyHead;
        while (strike != 0 && strike <= threshold) {
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
        uint256 threshold = price + _getBufferAmount(price, true);
        uint256 maxIn = maxSwap;
        uint256 totalIn;
        uint256 strikesCount;
        uint256[] memory strikes = new uint256[](activeSellStrikeCount);
        uint256[] memory usedAmounts = new uint256[](activeSellStrikeCount);

        uint256 strike = sellTail;
        while (strike != 0 && strike >= threshold) {
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

    function _payFee(address token, uint256 profitAmount) internal {
        if (feePool == address(0) || profitFeeBps == 0 || profitAmount == 0) return;
        uint256 fee = (profitAmount * profitFeeBps) / BPS;
        _payFeeAmount(token, fee);
    }

    function _payFeeAmount(address token, uint256 fee) internal {
        if (feePool == address(0) || fee == 0) return;
        IERC20(token).safeTransfer(feePool, fee);
        if (feePool.code.length > 0) {
            (bool ok, ) = feePool.call(abi.encodeWithSelector(FEE_POOL_NOTIFY_SELECTOR, token, fee));
            if (!ok) {
                // no-op
            }
        }
        emit FeePaid(token, fee);
    }

    function _payStopProfitFees() internal {
        if (feePool == address(0) || profitFeeBps == 0) return;
        if (activeBuyStrikeCount == 0 && activeSellStrikeCount == 0) return;

        uint256 price = doppiLP.getPrice();
        if (price == 0) revert InvalidPrice();

        _payStopBuyProfitFees(price);
        _payStopSellProfitFees(price);
    }

    function _payStopBuyProfitFees(uint256 price) internal {
        uint256 strike = buyHead;
        while (strike != 0) {
            uint256 nextStrike = buyStrikeNodes[strike].next;
            uint256 amountB = unWindBuy[strike];
            uint256 entryValueA = unWindBuyCostA[strike];
            uint256 currentValueA = (amountB * price) / priceDecimals;

            if (currentValueA > entryValueA) {
                uint256 profitA = currentValueA - entryValueA;
                uint256 feeA = (profitA * profitFeeBps) / BPS;
                uint256 feeB = (feeA * priceDecimals) / price;
                _payFeeAmount(address(assetB), feeB);
            }

            strike = nextStrike;
        }
    }

    function _payStopSellProfitFees(uint256 price) internal {
        uint256 strike = sellHead;
        while (strike != 0) {
            uint256 nextStrike = sellStrikeNodes[strike].next;
            uint256 amountA = unWindSell[strike];
            uint256 entryValueB = unWindSellCostB[strike];
            uint256 currentValueB = (amountA * priceDecimals) / price;

            if (currentValueB > entryValueB) {
                uint256 profitB = currentValueB - entryValueB;
                uint256 feeB = (profitB * profitFeeBps) / BPS;
                uint256 feeA = (feeB * price) / priceDecimals;
                _payFeeAmount(address(assetA), feeA);
            }

            strike = nextStrike;
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
        uint256 buyBudget = _getRoundBudget(true, availableA, minA, length);
        uint256 sellBudget = _getRoundBudget(false, availableB, minB, length);
        if (buyBudget == 0 && sellBudget == 0) return;

        uint256 gap = _priceGapWithDecimals();
        uint256 anchor = _roundPrice(price, gap);

        for (uint8 z = 0; z < maxOrder; ) {
            epochOriginalBuyByZone[z] = 0;
            epochOriginalSellByZone[z] = 0;
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
                    buyStrikeZone[buyStrike] = uint8(zone);
                    epochOriginalBuyByZone[uint8(zone)] = amountA;
                    activeBuyOpportunityStrikes.push(buyStrike);
                }
            }

            uint256 sellStrike = anchor + ((zone + 1) * gap);
            if (sellBudget > 0) {
                uint256 amountB = (sellBudget * weight) / BPS;
                if (amountB >= minB) {
                    opportunitySell[sellStrike] = amountB;
                    sellStrikeZone[sellStrike] = uint8(zone);
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
        uint256 sellBuffer = _getBufferAmount(price, false);
        uint256 buyThreshold = price > sellBuffer ? price - sellBuffer : 0;
        if (buyThreshold > 0) {
            uint256 strikeBuy = buyHead;
            while (strikeBuy != 0) {
                if (strikeBuy <= buyThreshold && unWindBuy[strikeBuy] > 0) return true;
                strikeBuy = buyStrikeNodes[strikeBuy].next;
            }
        }

        uint256 buyBuffer = _getBufferAmount(price, true);
        uint256 sellThreshold = price + buyBuffer;
        uint256 strikeSell = sellTail;
        while (strikeSell != 0) {
            if (strikeSell >= sellThreshold && unWindSell[strikeSell] > 0) return true;
            strikeSell = sellStrikeNodes[strikeSell].prev;
        }
        return false;
    }

    function _needPlaceOrders() internal view returns (bool) {
        if (currentEpochExpiry == 0) return true;
        return block.timestamp >= currentEpochExpiry;
    }

    function _getRoundBudget(bool isBuy, uint256 availableBalance, uint256 minOrder, uint256 length)
        internal
        view
        returns (uint256 budget)
    {
        if (availableBalance == 0) return 0;

        uint256 cap = isBuy ? maxOrderPerRoundA : maxOrderPerRoundB;
        if (cap > 0) {
            return availableBalance < cap ? availableBalance : cap;
        }

        return _getAutoRoundBudget(availableBalance, minOrder, length);
    }

    function _getAutoRoundBudget(uint256 availableBalance, uint256 minOrder, uint256 length)
        internal
        view
        returns (uint256 budget)
    {
        if (length == 0) return 0;

        uint256 maxSplit = length < 5 ? length : 5;
        for (uint256 split = maxSplit; split > 0; ) {
            uint256 candidateBudget = availableBalance / split;
            if (candidateBudget > 0) {
                uint256 validCount = 0;
                for (uint256 i = 0; i < length; ) {
                    uint256 depositAmount = (candidateBudget * orderConfigs[i].weight) / BPS;
                    if (depositAmount >= minOrder) {
                        unchecked {
                            ++validCount;
                        }
                    }
                    unchecked {
                        ++i;
                    }
                }
                if (validCount >= split) {
                    return candidateBudget;
                }
            }
            unchecked {
                --split;
            }
        }

        return 0;
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

    function _initializeOrderConfigs(uint24[] memory _weights) internal {
        uint256 length = _weights.length;
        for (uint256 i = 0; i < length; ) {
            if (_weights[i] > 0) {
                orderConfigs.push(OrderConfig(uint8(i), _weights[i]));
            }
            unchecked {
                ++i;
            }
        }
    }

    function _availableBalance(bool _isBuy) private view returns (uint256 availableAmount) {
        uint256 balance;
        uint256 undoAmount;
        if (_isBuy) {
            balance = assetA.balanceOf(address(this));
            undoAmount = undoStat.undo_assetA;
        } else {
            balance = assetB.balanceOf(address(this));
            undoAmount = undoStat.undo_assetB;
        }
        if (balance <= undoAmount) return 0;
        availableAmount = balance - undoAmount;
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

        for (uint8 z = 0; z < maxOrder; ) {
            epochOriginalBuyByZone[z] = 0;
            epochOriginalSellByZone[z] = 0;
            unchecked {
                ++z;
            }
        }
    }

    function _onlyForwarder() internal view {
        if (msg.sender != s_forwarderAddress) revert OnlyForwarder();
    }
}
