// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol"; 
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import "./DoppiTraderTypes.sol";
import "./DoppiTraderAdminView.sol";
// import "forge-std/console.sol"; // removed: debug-only import, not for production
import {IDoppiUpkeepManager, TopUpInfo} from "../Interface/IDoppiUpkeepManager.sol";

contract DoppiTrader is DoppiTraderAdminView, ReentrancyGuard, AutomationCompatibleInterface, Initializable {
    using SafeERC20 for IERC20;
    
    OrderConfig[] public orderConfigs;
    bool public useCustomConfig;
    UndoStat public undoStat;

    event BulkDeposited(address indexed trader, uint256 totalAmount, bool isBuy);
    event UnwindPerformed(address indexed trader, bool isBuy, uint256 amountIn, uint256 amountOut);

    error ArrayMismatch();
    error MaxLimit();
    error MustHundred();
    error ExceedMaxZone();
    error NotEmergency();
    error AmountNotSpecified();
    error AmountMustGreaterThanUpkeep();
    error ActiveOrders();
    error OnlyForwarder();
    error OnlyDoppiCore();
    error NoEnoughBalance();


    constructor() Ownable(msg.sender) {
    }

    // Remove the constructor and replace with initialize function
    function initialize(
        address _trader,
        IERC20 _assetA,
        IERC20 _assetB,
        address _doppiLP,
        address _doppiRouter,
        address _da,
        address _doppiUpKeepManager,
        uint24[] memory _weights
    ) external initializer {
        
        // Move constructor logic here
        assetA = _assetA;
        assetB = _assetB;
        doppiLP = IDoppiLiquidity(_doppiLP);
        doppiRouter = IDoppiLiquidityRouter(_doppiRouter);
        doppiCore = IDoppiCore(_da);
        validTrader = _trader;
        _transferOwnership(msg.sender); 

        // Batch approvals
        address[] memory tokens = new address[](3);
        tokens[0] = _da;
        tokens[1] = _doppiRouter;
        tokens[2] = _doppiLP;
        for (uint256 i = 0; i < tokens.length; i++) {
            assetA.safeIncreaseAllowance(tokens[i], type(uint256).max);
            assetB.safeIncreaseAllowance(tokens[i], type(uint256).max);
        }
        // Initialize with default weights
        _initializeOrderConfigs(_weights);
        doppiUpkeepManager = IDoppiUpkeepManager(_doppiUpKeepManager);
        impliedVol = doppiCore.doppiOffer();
        traderDefaultDay = 1;
        maxOrder = 5;
        ratioLP = 5000;
        maxSwap = 200000 ether;
        unwindGapMultiplier = 1;
        priceDecimals = 10 ** doppiLP.getPriceDecimals();
    }

    function start(uint256 _amountA, uint256 _amountB) external nonReentrant {
        
        _onlyTrader();
        if(_amountA == 0 && _amountB == 0) revert AmountNotSpecified();

        uint256 forUpkeep;
        bool shouldInsertNewBot = doppiUpkeepManager.shouldInsertNew(address(this));
        if(shouldInsertNewBot) {
            forUpkeep = doppiUpkeepManager.getDefault_Amount();
            if(_amountA <= forUpkeep) revert AmountMustGreaterThanUpkeep();
            _amountA = _amountA - forUpkeep;
        }
        _processDeposit(_amountA, _amountB);
        _placeBulk();
        
        if(shouldInsertNewBot && forUpkeep > 0){
            assetA.safeTransferFrom(msg.sender, address(doppiUpkeepManager), forUpkeep);
            doppiUpkeepManager.insertNewBot(msg.sender, address(this));
        }
        
    }

    function placeOrders() external nonReentrant {
        _onlyTrader();
        uint256 price = doppiLP.getPrice();
        (bool toBuy, bool toSell) = _shouldPlaceOrders(price);
        if(!toBuy && !toSell) revert NoEnoughBalance();
        _placeBulk();
    }

    function stop() external nonReentrant {
        _onlyTrader();
        uint256 buyPosCount = doppiCore.getBuyPositionCount(address(this));
        uint256 sellPosCount = doppiCore.getSellPositionCount(address(this));
        if (buyPosCount > 0 || sellPosCount > 0) revert ActiveOrders();

        uint256 maxShares = doppiRouter.getWithdrawableAmount(address(this));
        _withdrawFromLP(maxShares);
        
        uint256 balanceA = assetA.balanceOf(address(this));
        uint256 balanceB = assetB.balanceOf(address(this));
        if(balanceA > 0) {
            assetA.safeTransfer(msg.sender, assetA.balanceOf(address(this)));
        }
        if(balanceB > 0) {
            assetB.safeTransfer(msg.sender, assetB.balanceOf(address(this)));
        }
        undoStat.undo_assetB = 0;
        undoStat.undo_assetA = 0;
        _removeMapping();
    }

    function emergencyWithdraw() external nonReentrant {
        _onlyTrader();
        if (!doppiRouter.isEmergency() || !doppiRouter.paused()) revert NotEmergency();
        // make sure no active orders
        uint256 buyPosCount = doppiCore.getBuyPositionCount(address(this));
        uint256 sellPosCount = doppiCore.getSellPositionCount(address(this));
        if (buyPosCount > 0 || sellPosCount > 0) revert ActiveOrders();

        IERC20(doppiLP).safeIncreaseAllowance(address(doppiRouter), doppiLP.balanceOf(address(this)));
        doppiRouter.emergencyWithdraw();

        assetA.safeTransfer(msg.sender, assetA.balanceOf(address(this)));
        assetB.safeTransfer(msg.sender, assetB.balanceOf(address(this)));
        
        undoStat.undo_assetB = 0;
        undoStat.undo_assetA = 0;
        _removeMapping();
    }

    function setMultipleOrderConfigs(
        uint8[] calldata strikeZones, 
        uint24[] calldata weights
    ) external {
        _onlyTrader();
        if(strikeZones.length != weights.length) revert ArrayMismatch();
        if(strikeZones.length > maxOrder 
            && weights.length > maxOrder
        ) revert MaxLimit();
        
        uint24 sum = DALiquidityLib.sumArray(weights);
        if(sum != 10000) revert MustHundred();
        
        delete orderConfigs;
        for (uint256 i = 0; i < weights.length; i++) {
            if(strikeZones[i] > maxOrder) revert ExceedMaxZone();
            orderConfigs.push(OrderConfig(strikeZones[i], weights[i]));
        }
    }

    function setUseCustomConfig(bool _useCustom) external {
        _onlyTrader();
        useCustomConfig = _useCustom;
    }

    function getOrderConfigs() external view returns (OrderConfig[] memory) {
        return orderConfigs;
    }

    function resetToDefaultConfig() external {
        _onlyTrader();
        delete orderConfigs;
        uint24[] memory defaultWeights = new uint24[](maxOrder);
        uint24 equalWeight = uint24(10000 / maxOrder);
        uint24 total = 0;
        
        for (uint8 i = 0; i < maxOrder - 1; i++) {
            defaultWeights[i] = equalWeight;
            total += equalWeight;
        }
        defaultWeights[maxOrder - 1] = 10000 - total;
        _initializeOrderConfigs(defaultWeights);
        useCustomConfig = false;
    }

    function createUnwindPosition(uint256 _payout, uint256 _strikePrice, bool _isBuyUndo) external nonReentrant {
        
        _onlyDoppiCore();

        if(_isBuyUndo) {
            unWindBuy[_strikePrice] += _payout;
            undoStat.undo_assetB += _payout;
        }else{
            unWindSell[_strikePrice] += _payout;
            undoStat.undo_assetA += _payout;
        }        
        _syncStrikeState(_strikePrice, _isBuyUndo);
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        
        if(s_forwarderAddress == address(0)) return (false, bytes(""));
        if(paused()) return (false, bytes(""));

        uint256 price = doppiLP.getPrice();
        
        uint256[] memory targetPricesBuy;
        uint256[] memory targetPricesSell;
        uint256 totalBuyAmountInB;
        uint256 totalSellAmountInA;
        bool toTopUp;
        
        (bool toBuy, bool toSell) = _shouldPlaceOrders(price);
        if(toBuy || toSell) return (true, abi.encode(false, false, targetPricesBuy, targetPricesSell, 0, 0, 0, toBuy, toSell, false));

        (targetPricesBuy, totalBuyAmountInB) =_checkUndoTrade(true, price);
        (targetPricesSell, totalSellAmountInA) =_checkUndoTrade(false, price);
        
        if (totalBuyAmountInB > 0 || totalSellAmountInA > 0) {
            (bool isNetBuy, uint256 netAmount) = _netoutBuySell(totalSellAmountInA, totalBuyAmountInB, price);
            if(netAmount > 0){
                return (true, abi.encode(true, isNetBuy, targetPricesBuy, targetPricesSell, netAmount, totalSellAmountInA, totalBuyAmountInB, false, false, false));
            }
        }
        (toTopUp) = _shouldTopupUpkeep();
        if(toTopUp) {
            return (true, abi.encode(false, false, targetPricesBuy, targetPricesSell, 0, 0, 0, false, false, true));
        }
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant {
        
        _onlyForwarder();
        (bool performUnwind, bool isNetBuy, uint256[] memory targetPricesBuy, uint256[] memory targetPricesSell, uint256 totalAmount, uint256 totalSellAmountInA, uint256 totalBuyAmountInB, bool placeBuy, bool placeSell, bool toTopUp) = 
            abi.decode(performData, (bool, bool, uint256[], uint256[], uint256, uint256, uint256, bool, bool, bool));

        uint256 currentPrice = doppiLP.getPrice();
        if (placeBuy || placeSell) {
            _handleOrderPlacement(placeBuy, placeSell);
            return;
        }

        if (performUnwind) {
            uint256 amountOut = doppiLP.swap(totalAmount, currentPrice, isNetBuy);
            _clearUnwindMap(targetPricesBuy, true, totalBuyAmountInB);
            _clearUnwindMap(targetPricesSell, false, totalSellAmountInA);  
            emit UnwindPerformed(address(this), isNetBuy, totalAmount, amountOut);
        }
        if(toTopUp) {
            _processTopUp();
            return;
        }
    }

    function _clearUnwindMap(uint256[] memory prices, bool isBuy, uint256 totalpayout) internal {
        uint256 length = prices.length;
        if (length == 0) return;
        
        mapping(uint256 => uint256) storage unWindMap = isBuy ? unWindBuy : unWindSell; 
        uint256 reduced = totalpayout;
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            uint256 unwind = unWindMap[prices[index]];
            if(reduced >= unwind){
                delete unWindMap[prices[index]];
                reduced -= unwind;
            }else{
                unWindMap[prices[index]] = reduced;
            }
            _syncStrikeState(prices[index], isBuy);
            unchecked { --i; }
        }
        if (isBuy) {
            undoStat.undo_assetB = undoStat.undo_assetB > totalpayout ? undoStat.undo_assetB - totalpayout : 0;
        } else {
            undoStat.undo_assetA = undoStat.undo_assetA > totalpayout ? undoStat.undo_assetA - totalpayout : 0;
        }
    }

    function _handleOrderPlacement(bool placeBuy, bool placeSell) internal {
        if (placeBuy && placeSell) {
            _placeBulk();
        } else if (placeBuy) {
            _place_oneside(true);
        } else if (placeSell) {
            _place_oneside(false);
        }
    }

    function _shouldTopupUpkeep() internal view returns (bool topUp) {
        uint256 upkeepId = doppiUpkeepManager.getUpkeepIdByBot(address(this));
        if(upkeepId == 0) {
            return false;
        }
        (, topUp) = doppiUpkeepManager.shouldTopUpkeep(upkeepId);
    }

    function _processTopUp() internal {
        uint256 upkeepId = doppiUpkeepManager.getUpkeepIdByBot(address(this));
        (TopUpInfo memory topUpInfo, ) = doppiUpkeepManager.shouldTopUpkeep(upkeepId);
        assetA.safeTransferFrom(validTrader, address(this), topUpInfo.totalInfundToken);
        assetA.safeTransfer(address(doppiUpkeepManager), topUpInfo.totalInfundToken);
        doppiUpkeepManager.performTopUpkeep(upkeepId);
    }


    function _shouldPlaceOrders(uint256 price) internal view returns (bool toBuy, bool toSell) {
        if(doppiCore.paused()) return (false, false); 
        
        uint256 buyPosCount = doppiCore.getBuyPositionCount(address(this));
        uint256 sellPosCount = doppiCore.getSellPositionCount(address(this));
        uint256 availableA = _availableBalance(true);
        uint256 availableB = _availableBalance(false);
        // Early returns if no available balance or existing positions
        if (buyPosCount > 0 && sellPosCount > 0) return (false, false);
        if (availableA == 0 && availableB == 0) return (false, false);

        DualAssetOffer memory offerBuy = impliedVol.getSingleOffer(true, traderDefaultDay, 0, price);
        DualAssetOffer memory offerSell = impliedVol.getSingleOffer(false, traderDefaultDay, 0, price);
        if(offerBuy.apr == 0 && offerSell.apr == 0) return (false, false);

        bool hasValidBuyOrder = false;
        bool hasValidSellOrder = false;
        
        if (buyPosCount == 0 && availableA > 0 && offerBuy.apr > 0) {
            hasValidBuyOrder = _hasValidOrderConfig(true, availableA);
        }
        if (sellPosCount == 0 && availableB > 0 && offerSell.apr > 0) {
            hasValidSellOrder = _hasValidOrderConfig(false, availableB);
        }
        return (hasValidBuyOrder, hasValidSellOrder);
    }

    function _netoutBuySell(uint256 _totalSellAmountInA, uint256 _totalBuyAmountInB, uint256 currentPrice) 
        internal view returns (bool isNetBuy, uint256 netSellOrBuy) 
    {
        uint256 totalAmountOutInA = _totalBuyAmountInB * currentPrice / priceDecimals;
        uint256 totalAmountOutInB = _totalSellAmountInA * priceDecimals / currentPrice;
        
        if(_totalSellAmountInA > totalAmountOutInA){
            isNetBuy = true;
            netSellOrBuy = _totalSellAmountInA - totalAmountOutInA;
        } else if(_totalBuyAmountInB > totalAmountOutInB){
            isNetBuy = false;
            netSellOrBuy = _totalBuyAmountInB - totalAmountOutInB;
        }
    }

    function _hasValidOrderConfig(bool isBuy, uint256 availableAmount) private view returns (bool) {
        
        uint256 length = orderConfigs.length;
        uint256 min = isBuy ? doppiCore.minOrderA() : doppiCore.minOrderB();
        for (uint256 i = 0; i < length; ) {
            uint256 depositAmount = (availableAmount * orderConfigs[i].weight) / 10000;
            if (depositAmount >= min) {
                return true;
            }
            unchecked { ++i; }
        }
        return false;
    }

    function _processDeposit(uint256 _amountA, uint256 _amountB) internal {
        if(_amountA > 0) _transferAndDeposit(assetA, _amountA);
        if(_amountB > 0) _transferAndDeposit(assetB, _amountB);
    }

    function _transferAndDeposit(IERC20 token, uint256 amount) internal {
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 toLP = amount * ratioLP / 10000;
        _deposit(address(token), toLP);
    }

    function _placeBulk() internal {
        (BulkDepositParam[] memory buyParams, uint256 availableA) = _prepareOrders(true);
        (BulkDepositParam[] memory sellParams, uint256 availableB) = _prepareOrders(false);
        if (buyParams.length > 0) _placeOrders(true, buyParams, availableA);
        if (sellParams.length > 0) _placeOrders(false, sellParams, availableB);
    }

    function _prepareOrders(bool isBuy) internal view returns (BulkDepositParam[] memory params, uint256 availableAsset) {
        uint256 length = orderConfigs.length;
        if (length == 0) return (params, 0);

        availableAsset = _availableBalance(isBuy);
        if (availableAsset == 0) return (params, 0);

        uint256 min = isBuy ? doppiCore.minOrderA() : doppiCore.minOrderB();
        uint256 validCount = 0;

        for (uint256 i = 0; i < length; ) {
            uint256 depositAmount = (availableAsset * orderConfigs[i].weight) / 10000;
            if (depositAmount >= min) {
                unchecked { ++validCount; }
            }
            unchecked { ++i; }
        }

        if (validCount == 0) return (params, 0);

        // Create array with exact size
        params = new BulkDepositParam[](validCount);

        // Populate array
        uint256 count = 0;
        for (uint256 i = 0; i < validCount; ) {
            uint256 depositAmount = (availableAsset * orderConfigs[i].weight) / 10000;
            params[count] = _prepareOrder(depositAmount, orderConfigs[i]);
            unchecked { ++count; }
            unchecked { ++i; }
        }

        return (params, availableAsset);
    }

    function _prepareOrder(uint256 depositAmount, OrderConfig memory _orderConfig) internal view returns (BulkDepositParam memory param) {
        param = BulkDepositParam(depositAmount, _orderConfig.strikeZone, traderDefaultDay);
    }

    function _placeOrders(bool isBuy, BulkDepositParam[] memory params, uint256 available) internal returns (bool) {
        doppiCore.bulkDeposit(isBuy, params, available);
        emit BulkDeposited(msg.sender, available, isBuy);
        return true;
    }

    function _place_oneside(bool isBuy) internal {
        (BulkDepositParam[] memory params, uint256 available) = _prepareOrders(isBuy);
        _placeOrders(isBuy, params, available);
    }
    
    function _checkUndoTrade(bool _isBuy, uint256 _price) internal view 
        returns (
            uint256[] memory targetPrices, 
            uint256 totalAmount
        ) {
        
        mapping(uint256 => uint256) storage unwindMap = _isBuy ? unWindBuy : unWindSell; 
        mapping(uint256 => StrikeNode) storage strikeNodes = _isBuy ? buyStrikeNodes : sellStrikeNodes;
        
        uint256 round = _isBuy ? activeBuyStrikeCount : activeSellStrikeCount;
        if (round == 0) {
            targetPrices = new uint256[](0);
            return (targetPrices, 0);
        }
        uint256[] memory tempTargetPrice = new uint256[](round);
        uint256 count = 0;
        uint256 priceGap = impliedVol.getPriceGapPerOffer();
        uint256 priceGapWithDecimals = priceGap * priceDecimals;
        uint256 sPrice = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        uint256 unwindGap = priceGapWithDecimals * unwindGapMultiplier;
        uint256 unwindSellStrike = sPrice + (2 * priceGapWithDecimals) + unwindGap;
        uint256 unwindBuyStrike = sPrice - priceGapWithDecimals > unwindGap
            ? sPrice - priceGapWithDecimals - unwindGap
            : 0;
        uint256 maxSwapInLocal = maxSwap;
        if (_isBuy) {
            maxSwapInLocal = (maxSwap * priceDecimals) / _price;
        }

        uint256 strikePrice = _isBuy ? buyHead : sellTail;
        while (strikePrice != 0) {
            uint256 nextStrike = _isBuy ? strikeNodes[strikePrice].next : strikeNodes[strikePrice].prev;
            uint256 amount = unwindMap[strikePrice];
            if(totalAmount >= maxSwapInLocal){
                break;
            }
            uint256 remaining = maxSwapInLocal > totalAmount ? maxSwapInLocal - totalAmount : 0;
            uint256 unwindAmount = amount > remaining ? remaining : amount;
            uint256 newTotal = totalAmount + unwindAmount;
            bool canUnwind = _isBuy
                ? (strikePrice <= unwindBuyStrike)
                : (strikePrice >= unwindSellStrike);

            if (canUnwind && amount > 0 && newTotal <= maxSwapInLocal) {
                totalAmount = newTotal;              
                tempTargetPrice[count] = strikePrice;
                count++;
            }
            strikePrice = nextStrike;
        }

        uint256 arrCount = count < round ? count : round;
        targetPrices = new uint256[](arrCount);        
        for (uint256 j = 0; j < arrCount; ) {
            targetPrices[j] = tempTargetPrice[arrCount - 1 - j];
            unchecked { ++j; }
        }
    }

    function _removeMapping() internal {
        uint256 strikePrice = buyHead;
        while (strikePrice != 0) {
            uint256 nextStrike = buyStrikeNodes[strikePrice].next;
            delete unWindBuy[strikePrice];
            delete buyStrikeNodes[strikePrice];
            strikePrice = nextStrike;
        }

        strikePrice = sellHead;
        while (strikePrice != 0) {
            uint256 nextStrike = sellStrikeNodes[strikePrice].next;
            delete unWindSell[strikePrice];
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

    function _deposit(address _token, uint256 _amount) internal returns (uint256 shares) {
        return doppiRouter.deposit(_token, _amount);
    }

    function _withdrawFromLP(uint256 _shares) internal {
        IERC20(doppiLP).safeIncreaseAllowance(address(doppiRouter), _shares);
        doppiRouter.redeem(_shares);
    }

    function _initializeOrderConfigs(uint24[] memory _weights) internal {
        uint256 length = _weights.length;
        for (uint8 i = 0; i < length; ) {
            orderConfigs.push(OrderConfig(i, _weights[i]));
            unchecked { ++i; }
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
        if (balance <= undoAmount) {
            return 0;
        }
        availableAmount = balance - undoAmount;
    }
    
    function _onlyDoppiCore() internal view {
        if(msg.sender != address(doppiCore)) revert OnlyDoppiCore();
    }

    function _onlyForwarder() internal view {
        if (msg.sender != s_forwarderAddress) revert OnlyForwarder();
    }
}