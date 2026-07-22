// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol"; 
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import "./DoppiTraderTypes.sol";
import "./DoppiTraderAdminView.sol";
// import "forge-std/console.sol"; // removed: debug-only import, not for production

contract DoppiTrader is DoppiTraderAdminView, ReentrancyGuard, AutomationCompatibleInterface, Initializable {
    using SafeERC20 for IERC20;
    OrderConfig[] public orderConfigs;
    UndoStat public undoStat;

    event BulkDeposited(address indexed trader, uint256 totalAmount, bool isBuy);
    event UnwindPerformed(address indexed trader, bool isBuy, uint256 amountIn, uint256 amountOut);

    error ArrayMismatch();
    error MaxLimit();
    error MustHundred();
    error ExceedMaxZone();
    error NotEmergency();
    error AmountNotSpecified();
    error ActiveOrders();
    error OnlyForwarder();
    error OnlyDoppiCore();
    error NoEnoughBalance();
    error InvalidPrice();


    constructor() Ownable(msg.sender) {
    }

    // Remove the constructor and replace with initialize function
    function initialize(
        address _trader,
        IERC20 _assetA,
        IERC20 _assetB,
        address _doppiLP,
        address _doppiRouter,
        address _doppiCore,
        uint24[] memory _weights
    ) external initializer {
        
        // Move constructor logic here
        assetA = _assetA;
        assetB = _assetB;
        doppiLP = IDoppiLiquidity(_doppiLP);
        doppiRouter = IDoppiLiquidityRouter(_doppiRouter);
        doppiCore = IDoppiCore(_doppiCore);
        validTrader = _trader;
        _transferOwnership(msg.sender); 

        // Batch approvals
        address[] memory tokens = new address[](3);
        tokens[0] = _doppiCore;
        tokens[1] = _doppiRouter;
        tokens[2] = _doppiLP;
        for (uint256 i = 0; i < tokens.length; i++) {
            assetA.safeIncreaseAllowance(tokens[i], type(uint256).max);
            assetB.safeIncreaseAllowance(tokens[i], type(uint256).max);
        }
        // Initialize with default weights
        _initializeOrderConfigs(_weights);
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

        uint256 price = doppiLP.getPrice();
        if(price == 0) revert InvalidPrice();

        uint256 currentValueInA = totalUnits == 0 ? 0 : _getTotalValueInA(price);
        uint256 currentValueInB = totalUnitsB == 0 ? 0 : _getTotalValueInB(price);

        if (_amountA > 0) assetA.safeTransferFrom(msg.sender, address(this), _amountA);
        if (_amountB > 0) assetB.safeTransferFrom(msg.sender, address(this), _amountB);

        (uint256 finalAmountA, uint256 finalAmountB) = _performTopUp(_amountA, _amountB);

        uint256 depositValueInA = finalAmountA;
        uint256 depositValueInB = finalAmountB;
        if (finalAmountA > 0) {
            depositValueInB += finalAmountA * priceDecimals / price;
        }
        if (finalAmountB > 0) {
            depositValueInA += finalAmountB * price / priceDecimals;
        }
        _updateUnitAndCostBasis(depositValueInA, currentValueInA, true);

        _updateUnitAndCostBasis(depositValueInB, currentValueInB, false);

        _processDeposit(finalAmountA, finalAmountB);
        _placeBulk();
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
        totalUnits = 0;
        costBasis = 0;
        totalUnitsB = 0;
        costBasisB = 0;
        _removeMapping();
    }

    function emergencyWithdraw() external nonReentrant {
        _onlyTrader();
        if (!doppiRouter.isEmergency() || !doppiRouter.paused()) revert NotEmergency();
        // make sure no active orders
        uint256 buyPosCount = doppiCore.getBuyPositionCount(address(this));
        uint256 sellPosCount = doppiCore.getSellPositionCount(address(this));
        if (buyPosCount > 0 || sellPosCount > 0) revert ActiveOrders();

        IERC20(address(doppiLP)).safeIncreaseAllowance(address(doppiRouter), IERC20(address(doppiLP)).balanceOf(address(this)));
        doppiRouter.emergencyWithdraw();

        assetA.safeTransfer(msg.sender, assetA.balanceOf(address(this)));
        assetB.safeTransfer(msg.sender, assetB.balanceOf(address(this)));
        
        undoStat.undo_assetB = 0;
        undoStat.undo_assetA = 0;
        totalUnits = 0;
        costBasis = 0;
        totalUnitsB = 0;
        costBasisB = 0;
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

    function getOrderConfigs() external view returns (OrderConfig[] memory) {
        return orderConfigs;
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
        
        (bool toBuy, bool toSell) = _shouldPlaceOrders(price);
        if(toBuy || toSell) return (true, abi.encode(false, false, targetPricesBuy, targetPricesSell, 0, 0, 0, toBuy, toSell));

        (targetPricesBuy, totalBuyAmountInB) =_checkUndoTrade(true, price);
        (targetPricesSell, totalSellAmountInA) =_checkUndoTrade(false, price);
        
        if (totalBuyAmountInB > 0 || totalSellAmountInA > 0) {
            (bool isNetBuy, uint256 netAmount) = _netoutBuySell(totalSellAmountInA, totalBuyAmountInB, price);
            if(netAmount > 0){
                return (true, abi.encode(true, isNetBuy, targetPricesBuy, targetPricesSell, netAmount, totalSellAmountInA, totalBuyAmountInB, false, false));
            }
        }
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant {
        
        _onlyForwarder();
        (bool performUnwind, bool isNetBuy, uint256[] memory targetPricesBuy, uint256[] memory targetPricesSell, uint256 totalAmount, uint256 totalSellAmountInA, uint256 totalBuyAmountInB, bool placeBuy, bool placeSell) = 
            abi.decode(performData, (bool, bool, uint256[], uint256[], uint256, uint256, uint256, bool, bool));

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
                unWindMap[prices[index]] = unwind - reduced;
                reduced = 0;
            }
            _syncStrikeState(prices[index], isBuy);
            if (reduced == 0) break;
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
        uint256 configLength = orderConfigs.length;
        
        if (buyPosCount == 0 && availableA > 0 && offerBuy.apr > 0) {
            hasValidBuyOrder = _hasValidOrderConfig(
                true,
                _getRoundBudget(true, availableA, doppiCore.minOrderA(), configLength)
            );
        }
        if (sellPosCount == 0 && availableB > 0 && offerSell.apr > 0) {
            hasValidSellOrder = _hasValidOrderConfig(
                false,
                _getRoundBudget(false, availableB, doppiCore.minOrderB(), configLength)
            );
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

        uint256 availableBalance = _availableBalance(isBuy);
        if (availableBalance == 0) return (params, 0);

        uint256 min = isBuy ? doppiCore.minOrderA() : doppiCore.minOrderB();
        availableAsset = _getRoundBudget(isBuy, availableBalance, min, length);
        if (availableAsset == 0) return (params, 0);
        
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
        for (uint256 i = 0; i < length; ) {
            uint256 depositAmount = (availableAsset * orderConfigs[i].weight) / 10000;
            if (depositAmount >= min) {
                params[count] = _prepareOrder(depositAmount, orderConfigs[i]);
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }

        return (params, availableAsset);
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
                    uint256 depositAmount = (candidateBudget * orderConfigs[i].weight) / 10000;
                    if (depositAmount >= minOrder) {
                        unchecked { ++validCount; }
                    }
                    unchecked { ++i; }
                }
                if (validCount >= split) {
                    return candidateBudget;
                }
            }
            unchecked { --split; }
        }

        return 0;
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
        IERC20(address(doppiLP)).safeIncreaseAllowance(address(doppiRouter), _shares);
        doppiRouter.redeem(_shares);
    }

    function _initializeOrderConfigs(uint24[] memory _weights) internal {
        uint256 length = _weights.length;

        for (uint256 i = length; i > 0; ) {
            unchecked { --i; }
            if(_weights[i] > 0) {
                orderConfigs.push(OrderConfig(uint8(i), _weights[i]));
            }
        }
    }

    function _updateUnitAndCostBasis(uint256 depositValue, uint256 currentValue, bool isAssetA) internal {
        if (depositValue == 0) return;

        uint256 units = isAssetA ? totalUnits : totalUnitsB;
        if (units == 0) {
            units = depositValue;
        } else if (currentValue > 0) {
            units += depositValue * units / currentValue;
        }

        if (isAssetA) {
            totalUnits = units;
            costBasis += depositValue;
        } else {
            totalUnitsB = units;
            costBasisB += depositValue;
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