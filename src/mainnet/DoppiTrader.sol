// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IImpliedVol} from "../Interface/IImpliedVol.sol";
import {IDoppiUpkeepManager} from "../Interface/IDoppiUpkeepManager.sol";
import {IDoppiLiquidityRouter} from "../Interface/IDoppiLiquidityRouter.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import "./DoppiCoreTypes.sol";
import "./DoppiTraderAdminView.sol";
import "forge-std/console.sol";

contract DoppiTrader is DoppiTraderAdminView, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    
    IDoppiUpkeepManager public immutable doppiUpkeepManager;
    IDoppiLiquidityRouter public immutable doppiRouter;
    IImpliedVol public immutable impliedVol;
    uint256 public minAssetAAmount;
    uint256 public minAssetBAmount;
    uint32 private nextBulkId = 1; 
    mapping(uint32 => HedgeBulkTrade) public hedgeBulkTrade; 

    OrderConfig[] public orderConfigs;
    bool public useCustomConfig;
    UndoStat public undoStat;

    event BulkDeposited(address indexed trader, uint256 totalAmount, bool isBuy);
    event UnwindPerformed(address indexed trader, bool isBuy, uint256 amountOut, uint256 profit, address profitToken);
    event BulkHedgeSettled(uint256 bulkId, bool isProfit, uint256 profitLoss, address profitToken);

    constructor(
        address _trader,
        IERC20 _assetA,
        IERC20 _assetB,
        address _doppiLP,
        address _doppiRouter,
        address _da,
        uint24[] memory _weights
    ) Ownable(msg.sender) {
        assetA = _assetA;
        assetB = _assetB;
        doppiLP = IDoppiLiquidity(_doppiLP);
        doppiRouter = IDoppiLiquidityRouter(_doppiRouter);
        doppiCore = IDoppiCore(_da);
        validTrader = _trader;
        doppiConfig = DoppiConfig(doppiLP.getDoppiConfig());
        _pause();
        assetA.safeIncreaseAllowance(_da, type(uint256).max);
        assetB.safeIncreaseAllowance(_da, type(uint256).max);
        assetB.safeIncreaseAllowance(_doppiRouter, type(uint256).max);
        assetA.safeIncreaseAllowance(_doppiRouter, type(uint256).max);
        assetA.safeIncreaseAllowance(_doppiLP, type(uint256).max);
        assetB.safeIncreaseAllowance(_doppiLP, type(uint256).max);

        // Initialize with default weights
        _initializeOrderConfigs(_weights);
        minAssetAAmount = doppiConfig.minimal_assetA();
        minAssetBAmount = doppiConfig.minimal_assetB();
        doppiUpkeepManager = IDoppiUpkeepManager(doppiConfig.doppiUpKeepManager());
        impliedVol = IImpliedVol(doppiConfig.impliedVol());
    }

    function start(uint256 _amountA, uint256 _amountB) external onlyTrader whenPaused {
        
        _updateForwarder();
        _unpause();
        if(_amountA > 0){
            assetA.safeTransferFrom(msg.sender, address(this), _amountA);
            uint256 assetAToLP = _amountA * doppiConfig.ratioLP() / 10000;
            _deposit(address(assetA), assetAToLP);
        } 
        
        if(_amountB > 0){
            assetB.safeTransferFrom(msg.sender, address(this), _amountB);
            uint256 assetBToLP = _amountB * doppiConfig.ratioLP() / 10000;
            _deposit(address(assetB), assetBToLP);
        } 
        _placeBulk();
    }

    function stop() external onlyTrader whenPaused {
        uint256 buyPosCount = doppiCore.getBuyPositionCount(address(this));
        uint256 sellPosCount = doppiCore.getSellPositionCount(address(this));
        require(buyPosCount == 0 && sellPosCount == 0, "active orders");

        uint256 price = doppiLP.getPrice();
        _closeHedge(price);

        uint256 totalBal = doppiLP.balanceOf(address(this));
        _withdrawFromLP(totalBal);
        
        assetA.safeTransfer(msg.sender, assetA.balanceOf(address(this)));
        assetB.safeTransfer(msg.sender, assetB.balanceOf(address(this)));

        delete buy_undo_list;
        delete sell_undo_list;
    }

    function setMultipleOrderConfigs(
        uint8[] calldata strikeZones, 
        uint24[] calldata weights
    ) external onlyTrader {
        require(
            strikeZones.length == weights.length, 
            "Array length mismatch"
        );
        require(
            strikeZones.length <= doppiConfig.MAX_ORDER() && weights.length <= doppiConfig.MAX_ORDER(), 
            "not more than max"
        );
        uint24 sum = DALiquidityLib.sumArray(weights);
        require(sum == 10000, "sum must equal 100%");

        delete orderConfigs;
        for (uint256 i = 0; i < weights.length; i++) {
            require(strikeZones[i] < doppiConfig.MAX_ORDER(), "not more than max zone");
            orderConfigs.push(OrderConfig({
                strikeZone: strikeZones[i],
                weight: weights[i]
            }));
        }
    }

    function setUseCustomConfig(bool _useCustom) external onlyTrader {
        useCustomConfig = _useCustom;
    }

    function getOrderConfigs() external view returns (OrderConfig[] memory) {
        return orderConfigs;
    }

    function resetToDefaultConfig() external onlyTrader {
        delete orderConfigs;
        // Reinitialize with default equal weights
        uint24[] memory defaultWeights = new uint24[](doppiConfig.MAX_ORDER());
        uint24 total = 0;
        for (uint8 i = 0; i < doppiConfig.MAX_ORDER() - 1; i++) {
            uint24 weight = 10000 / doppiConfig.MAX_ORDER();
            defaultWeights[i] = weight;
            total += weight;
        }
        defaultWeights[doppiConfig.MAX_ORDER() - 1] = 10000 - total;
        _initializeOrderConfigs(defaultWeights);
        
        useCustomConfig = false;
    }

    function createUnwindPosition(uint256 _amount, uint256 _strikePrice, bool _isBuyUndo) external onlyDoppiCore {
        uint8 priceDecimals = doppiLP.getPriceDecimals();

        if (_isBuyUndo) {
            uint256 assetBAmount = _amount * (10 ** priceDecimals) / _strikePrice;
            buy_undo_list.push(Trade(assetBAmount, _amount, _strikePrice));
            undoStat.undo_assetB += assetBAmount;
        } else {
            uint256 assetAAmount = _amount * _strikePrice / (10 ** priceDecimals);
            sell_undo_list.push(Trade(assetAAmount, _amount, _strikePrice));
            undoStat.undo_assetA += assetAAmount;
        }
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        
        if(s_forwarderAddress == address(0)) return (false, bytes(""));

        uint256 price = doppiLP.getPrice();
        
        if (!paused()) {
            uint256 buyPosCount = doppiCore.getBuyPositionCount(address(this));
            uint256 sellPosCount = doppiCore.getSellPositionCount(address(this));
            bool toBuy = buyPosCount == 0 && _availableBalance(true) > 0;
            bool toSell = sellPosCount == 0 && _availableBalance(false) > 0;
            
            if(toBuy || toSell){
                return (true, abi.encode(false, price, 0, false, toBuy, toSell));
            }
        }

        (upkeepNeeded, performData) = _checkUndoTrade(true, price);
        if (upkeepNeeded) return (true, performData);

        (upkeepNeeded, performData) = _checkUndoTrade(false, price);
        if (upkeepNeeded) return (true, performData);

        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external override onlyForwarder {
        
        if(s_forwarderAddress == address(0)) return;
        if(paused()) return;

        (bool performUnwind, uint256 price, uint256 index, 
        bool isBuyUndo, bool placeBuy, bool placeSell) = abi.decode(performData, (bool, uint256, uint256, bool, bool, bool));
        
        uint256 currentPrice = doppiLP.getPrice();
            
        if (placeBuy || placeSell) {
            _closeHedge(currentPrice);

            if (placeBuy && placeSell) {
                _placeBulk();
            } else if (placeBuy) { 
                _place_buys();
            } else if (placeSell) {
                _place_sells();
            }
        }   
        
        // Handle unwind operation
        if (performUnwind) {
            uint256 tolerance = doppiConfig.tolerance();
            uint256 lowerBound = 10000 - tolerance;
            uint256 upperBound = 10000 + tolerance;
            
            uint256 priceRatio = (currentPrice * 10000) / price;
            
            if (priceRatio > lowerBound && priceRatio < upperBound) {
                _unwind_bot_trader(currentPrice, index, isBuyUndo);
            }
        }
    }

    function _updateForwarder() internal {
        uint256 upKeepId = doppiUpkeepManager.getUpkeepIdByBot(address(this));
        s_forwarderAddress = doppiUpkeepManager.getForwarder(upKeepId);
    }

    function _unwind_bot_trader(uint256 price, uint256 index, bool isBuyUndo) internal {
        if (isBuyUndo) {
            _performUnwind(isBuyUndo, buy_undo_list[index], price);
            uint256 lastIndex = buy_undo_list.length - 1;
            if (index != lastIndex) {
                buy_undo_list[index] = buy_undo_list[lastIndex];
            }
            buy_undo_list.pop();
        } else {
            _performUnwind(isBuyUndo, sell_undo_list[index], price);
            uint256 lastIndex = sell_undo_list.length - 1;
            if (index != lastIndex) {
                sell_undo_list[index] = sell_undo_list[lastIndex];
            }
            sell_undo_list.pop();
        }
    }

    function _placeBulk() internal {
        (
            DepositParams[] memory buyDeposits,
            DualAssetOffer[] memory buyOffers,
            uint256 amountInHedgeAssetB,
            uint256 hedgeAmountA
        ) = _prepareOrders(true);
        
        (
            DepositParams[] memory sellDeposits,
            DualAssetOffer[] memory sellOffers,
            uint256 amountInHedgeAssetA,
            uint256 hedgeAmountB
        ) = _prepareOrders(false);
        
        _placeOrders(true, buyDeposits, buyOffers);
        _placeOrders(false, sellDeposits, sellOffers);
        
        (bool isNetBuy, uint256 netAmount)  
            = DALiquidityLib.netoutBuySell(amountInHedgeAssetB, hedgeAmountA, amountInHedgeAssetA, hedgeAmountB);

        if ((isNetBuy ? assetA : assetB).balanceOf(address(doppiLP)) < netAmount) return;
        
        uint256 price = buyOffers.length > 0 ? buyOffers[0].price : sellOffers[0].price;
        _openHedge(netAmount, price, isNetBuy);

    }

    function _openHedge(uint256 netAmount, uint256 _price, bool isNetBuy) internal {
        
        (uint256 swappedHedgeAmount, uint256 hedgePrice) = doppiCore.bulkHedge(netAmount, _price, isNetBuy);
        hedgeBulkTrade[nextBulkId] = HedgeBulkTrade(
            netAmount,
            swappedHedgeAmount,
            hedgePrice,
            isNetBuy
        );
        unchecked { nextBulkId++; }
    }

    function _closeHedge(uint256 _price) internal {
        uint32 bulkId = nextBulkId - 1;
        HedgeBulkTrade storage p = hedgeBulkTrade[bulkId];
        
        // Early return if no hedge to close
        uint256 swappedHedgeAmount = p.swappedHedgeAmount;
        if (swappedHedgeAmount == 0) {
            return;
        }
        
        // Perform hedge swap
        (uint256 hedgeOut, ) = doppiLP.hedgeSwap(swappedHedgeAmount, _price, !p.isNetBuy);
        
        // Calculate profit/loss
        uint256 hedgeAmountInHedgeToken = p.hedgeAmountInHedgeToken;
        bool isProfit = hedgeOut > hedgeAmountInHedgeToken;
        uint256 profitOrLoss = isProfit 
            ? hedgeOut - hedgeAmountInHedgeToken 
            : hedgeAmountInHedgeToken - hedgeOut;
        
        // Cache token address
        address profitOrLossToken = p.isNetBuy ? address(assetA) : address(assetB);
        
        // Reset storage values
        p.swappedHedgeAmount = 0;
        p.hedgeAmountInHedgeToken = 0;
        p.hedgePrice = 0;
        
        emit BulkHedgeSettled(bulkId, isProfit, profitOrLoss, profitOrLossToken);
    }

    function _hedgeAmount(uint256 _amount, uint256 _delta, uint256 _price, bool isBuy) internal view returns (uint256 amountInHedgeAsset, uint256 hedgeAmount) {
        uint256 priceDecimals = doppiLP.getPriceDecimals();
        hedgeAmount = _amount * _delta / 10000;
        amountInHedgeAsset = isBuy ? hedgeAmount * (10 ** priceDecimals) / _price : hedgeAmount * _price / (10 ** priceDecimals);
    }

    function _prepareOrders(bool isBuy) internal view returns 
        (
            DepositParams[] memory deposits,
            DualAssetOffer[] memory offers,
            uint256 amountInHedgeAssetB,
            uint256 hedgeAmountA
        ){

        uint256 length = orderConfigs.length;
        if (length == 0) return (deposits, offers, 0, 0);
        
        uint256 availableAsset = _availableBalance(isBuy);
        if (availableAsset == 0) return (deposits, offers, 0, 0);
        
        deposits = new DepositParams[](length);
        offers = new DualAssetOffer[](length);
        for (uint256 i = 0; i < length; ) {
            (DepositParams memory deposit,
                DualAssetOffer memory offer) = _prepareOrder(isBuy, availableAsset, orderConfigs[i]);
            deposits[i] = deposit;
            offers[i] = offer;

            (uint256 amtInHedgeAssetB, uint256 hAmountA) = 
                    _hedgeAmount(deposit.amount, offer.delta, offer.price, isBuy);

            amountInHedgeAssetB += amtInHedgeAssetB;
            hedgeAmountA += hAmountA;

            unchecked { ++i; }
        }
    }

    function _prepareOrder(bool isBuy, uint256 totalamount, OrderConfig memory _orderConfig) internal view returns (
            DepositParams memory deposit,
            DualAssetOffer memory offer )
    {
        uint256 totalWeight = 10000;
        offer = impliedVol.getOffer(isBuy, traderDefaultDay, _orderConfig.strikeZone);

        uint256 depositAmount = (totalamount * _orderConfig.weight) / totalWeight;
        deposit = DepositParams(
            depositAmount, 
            _orderConfig.strikeZone,
            offer.strikePrice,
            traderDefaultDay,
            offer.apr,
            offer.validUntilTimestamp
        );
    }

    function _placeOrders(
        bool isBuy,
        DepositParams[] memory deposits, 
        DualAssetOffer[] memory offers) internal returns (bool) {
        
        uint256 availableAmount = _availableBalance(isBuy);

        doppiCore.bulkDeposit(isBuy, deposits, offers, false);
        
        emit BulkDeposited(msg.sender, availableAmount, isBuy);
        return true;
    }

    function _place_buys() internal {
        ( 
            DepositParams[] memory buyDeposits,
            DualAssetOffer[] memory buyOffers,
            uint256 amountInHedgeAsset,
        ) = _prepareOrders(true);

        _placeOrders(true, buyDeposits, buyOffers);

        // place hedge in bulk
        if (assetB.balanceOf(address(doppiLP)) < amountInHedgeAsset) return;
        
        uint256 price = buyOffers[0].price;
        _openHedge(amountInHedgeAsset, price, false);

    }

    function _place_sells() internal {
        ( 
            DepositParams[] memory sellDeposits,
            DualAssetOffer[] memory sellOffers,
            uint256 amountInHedgeAsset,
        ) = _prepareOrders(false);

        _placeOrders(false, sellDeposits, sellOffers);

        if (assetA.balanceOf(address(doppiLP)) < amountInHedgeAsset) return;
        
        uint256 price = sellOffers[0].price;
        _openHedge(amountInHedgeAsset, price, true);       
    }
    
    function _checkUndoTrade(bool _isBuy, uint256 _price)
        internal
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 undo_length = _isBuy ? buy_undo_list.length : sell_undo_list.length;
        for (uint256 i = 0; i < undo_length; ) {
            uint256 iteration_index = undo_length - i - 1;
            uint256 oriStrikePrice = _isBuy ? buy_undo_list[iteration_index].origStrikePrice : sell_undo_list[iteration_index].origStrikePrice;
            uint256 triggerPrice = oriStrikePrice - (oriStrikePrice * doppiConfig.tolerance() / 10000);
            
            if((_isBuy && _price >= triggerPrice) || (!_isBuy && _price <= triggerPrice)) {
                return (true, abi.encode(true, _price, iteration_index, _isBuy, false, false));
            }
            unchecked { ++i; }
        }
        return (false, bytes(""));
    }

    function _deposit(address _token, uint256 _amount) internal returns (uint256 shares) {
        return doppiRouter.deposit(_token, _amount);
    }

    function _withdrawFromLP(uint256 _shares) internal {
        IERC20(doppiLP).safeIncreaseAllowance(address(doppiRouter), _shares);
        doppiRouter.redeem(_shares);
    }

    function _performUnwind(bool _isBuy, Trade memory _trade, uint256 _price) internal {
        
        uint256 tol = doppiConfig.tolerance();
        uint256 triggerPrice = _isBuy 
            ? _trade.origStrikePrice + (_trade.origStrikePrice * tol / 10000)
            : _trade.origStrikePrice - (_trade.origStrikePrice * tol / 10000);
            
        if ((_isBuy && _price >= triggerPrice) || (!_isBuy && _price <= triggerPrice)) {
            uint256 amountOut = doppiLP.swap(_trade.payoutAmount, _price, !_isBuy);
            uint256 profit;
            unchecked { profit = amountOut >= _trade.origAmount ? amountOut - _trade.origAmount : 0; }

            if (_isBuy) {
                undoStat.undo_assetB -= _trade.payoutAmount;
                emit UnwindPerformed(address(this), _isBuy, amountOut, profit, address(assetA));
            } else {
                undoStat.undo_assetA -= _trade.payoutAmount;
                emit UnwindPerformed(address(this), _isBuy, amountOut, profit, address(assetB));
            }
        }
    }

    function _initializeOrderConfigs(uint24[] memory _weights) internal {
        
        // Initialize buy order configs for all 5 strike zones
        uint256 length = _weights.length;
        for (uint8 i = 0; i < length; ) {
            orderConfigs.push(OrderConfig({
                strikeZone: i,
                weight: _weights[i]
            }));
            unchecked { ++i; }
        }
    }

    function _availableBalance(bool _isBuy) private view returns (uint256 availableAmount) {
        
        availableAmount = _isBuy ? assetA.balanceOf(address(this)) : assetB.balanceOf(address(this));
        availableAmount = availableAmount > (_isBuy ? undoStat.undo_assetA : undoStat.undo_assetB) ? availableAmount - (_isBuy ? undoStat.undo_assetA : undoStat.undo_assetB) : 0;
        availableAmount = availableAmount > (_isBuy ? minAssetAAmount : minAssetBAmount) ? availableAmount : 0;
    }
    
    
    modifier onlyDoppiCore() {
        require(msg.sender == address(doppiCore), "only doppicore");
        _;
    }

    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "invalid forwarder");
        _;
    }

}