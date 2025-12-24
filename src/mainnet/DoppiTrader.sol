// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol"; 
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import "./DoppiCoreTypes.sol";
import "./DoppiTraderAdminView.sol";
// import "forge-std/console.sol";

contract DoppiTrader is DoppiTraderAdminView, ReentrancyGuard, AutomationCompatibleInterface, Initializable {
    using SafeERC20 for IERC20;
    
    bool private initialized;
    
    OrderConfig[] public orderConfigs;
    bool public useCustomConfig;
    UndoStat public undoStat;

    event BulkDeposited(address indexed trader, uint256 totalAmount, bool isBuy);
    event UnwindPerformed(address indexed trader, bool isBuy, uint256 amountIn, uint256 amountOut);

    error ArrayMismatch();
    error MaxLimit();
    error MustHundred();
    error ExceedMaxZone();
    error AlreadyInitialized();
    
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
        
        // // Prevent re-initialization
        if (initialized) revert AlreadyInitialized();
        initialized = true;

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
        impliedVol = IDoppiOffer(doppiCore.getDoppiOffer());
        traderDefaultDay = 1;
        maxOrder = 5;
        ratioLP = 5000;
        tolerance = 100;

        uint256 price = doppiLP.getPrice();
        uint256 lower = _getUnwindTargetPrice(price, 1, true);   
        uint256 upper = _getUnwindTargetPrice(price, 1, false);   
        lowerBound = lower;
        upperBound = upper;
    }

    function start(uint256 _amountA, uint256 _amountB) external onlyTrader nonReentrant {
        require(_amountA > 0 || _amountB > 0, "amount not specified");
        _updateForwarder();
        _processDeposit(_amountA, _amountB);
        _placeBulk(doppiLP.getPrice());
    }

    function placeOrders() external onlyTrader nonReentrant {
        _placeBulk(doppiLP.getPrice());
    }

    function stop() external onlyTrader nonReentrant {
        uint256 buyPosCount = doppiCore.getBuyPositionCount(address(this));
        uint256 sellPosCount = doppiCore.getSellPositionCount(address(this));
        require(buyPosCount == 0 && sellPosCount == 0, "active orders");

        _withdrawFromLP(doppiLP.balanceOf(address(this)));
        
        assetA.safeTransfer(msg.sender, assetA.balanceOf(address(this)));
        assetB.safeTransfer(msg.sender, assetB.balanceOf(address(this)));

        undoStat.undo_assetB = 0;
        undoStat.undo_assetA = 0;
        _removeMapping();
    }

    function emergencyWithdraw() external onlyTrader nonReentrant {
        require(doppiCore.isEmergency() && doppiCore.paused(), "only for emergency");

        doppiCore.emergencyWithdraw();
        assetA.safeTransfer(msg.sender, assetA.balanceOf(address(this)));
        assetB.safeTransfer(msg.sender, assetB.balanceOf(address(this)));

        undoStat.undo_assetB = 0;
        undoStat.undo_assetA = 0;
        _removeMapping();
    }

    function emergencyWithdrawLP() external onlyTrader nonReentrant {
        require(doppiRouter.isEmergency() && doppiRouter.paused(), "only for emergency in LP");

        IERC20(doppiLP).safeIncreaseAllowance(address(doppiRouter), doppiLP.balanceOf(address(this)));
        doppiRouter.emergencyWithdraw();

        assetA.safeTransfer(msg.sender, assetA.balanceOf(address(this)));
        assetB.safeTransfer(msg.sender, assetB.balanceOf(address(this)));
    }

    function setMultipleOrderConfigs(
        uint8[] calldata strikeZones, 
        uint24[] calldata weights
    ) external onlyTrader {

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

    function setUseCustomConfig(bool _useCustom) external onlyTrader {
        useCustomConfig = _useCustom;
    }

    function getOrderConfigs() external view returns (OrderConfig[] memory) {
        return orderConfigs;
    }

    function resetToDefaultConfig() external onlyTrader {
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

    function createUnwindPosition(uint256 _payout, uint256 _strikePrice, bool _isBuyUndo) external onlyDoppiCore {
        
        if(_strikePrice > upperBound){
            upperBound = _strikePrice;
        }else if (_strikePrice < lowerBound || lowerBound == 0){
            lowerBound = _strikePrice;
        }

        if(_isBuyUndo) {
            unWindBuy[_strikePrice] += _payout;
            undoStat.undo_assetB += _payout;
        }else{
            unWindSell[_strikePrice] += _payout;
            undoStat.undo_assetA += _payout;
        }        
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        
        if(s_forwarderAddress == address(0)) return (false, bytes(""));
        uint256 price = doppiLP.getPrice();
        
        uint256[] memory targetPricesBuy;
        uint256[] memory targetPricesSell;
        uint256 totalBuyAmountInB;
        uint256 totalSellAmountInA;

        (bool toBuy, bool toSell) = _shouldPlaceOrders(price);
        if(toBuy || toSell) return (true, abi.encode(false, false, targetPricesBuy, targetPricesSell, 0, 0, 0, toBuy, toSell));

        (targetPricesBuy, totalBuyAmountInB) =_checkUndoTrade(true, price);
        (targetPricesSell, totalSellAmountInA) =_checkUndoTrade(false, price);
        if (totalBuyAmountInB > 0 && totalSellAmountInA > 0) {
            (bool isNetBuy, uint256 netAmount) = _netoutBuySell(totalSellAmountInA, totalBuyAmountInB, price);
            if(netAmount > 0){
                return (true, abi.encode(true, isNetBuy, targetPricesBuy, targetPricesSell, netAmount, totalSellAmountInA, totalBuyAmountInB, false, false));
            }
        }

        if (totalBuyAmountInB > 0) {
            return (true, abi.encode(true, false, targetPricesBuy, targetPricesSell, totalBuyAmountInB, 0, totalBuyAmountInB, false, false));
        }
        
        if (totalSellAmountInA > 0) {
            return (true, abi.encode(true, true, targetPricesBuy, targetPricesSell, totalSellAmountInA, totalSellAmountInA, 0, false, false));
        }
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant onlyForwarder {
        
        if(s_forwarderAddress == address(0)) return;

        (bool performUnwind, bool isNetBuy, uint256[] memory targetPricesBuy, uint256[] memory targetPricesSell, uint256 totalAmount, uint256 totalSellAmountInA, uint256 totalBuyAmountInB, bool placeBuy, bool placeSell) = 
            abi.decode(performData, (bool, bool, uint256[], uint256[], uint256, uint256, uint256, bool, bool));

        uint256 currentPrice = doppiLP.getPrice();
        if (placeBuy || placeSell) {
            _handleOrderPlacement(placeBuy, placeSell, currentPrice);
        }

        if (performUnwind) {
            uint256 amountOut = doppiLP.swap(totalAmount, currentPrice, isNetBuy);
            _clearUnwindMap(targetPricesBuy, true, totalBuyAmountInB);
            _clearUnwindMap(targetPricesSell, false, totalSellAmountInA);  
            emit UnwindPerformed(address(this), isNetBuy, totalAmount, amountOut);
        }
    }

    function _updateForwarder() internal {
        uint256 upKeepId = doppiUpkeepManager.getUpkeepIdByBot(address(this));
        s_forwarderAddress = doppiUpkeepManager.getForwarder(upKeepId);
    }

    function _clearUnwindMap(uint256[] memory prices, bool isBuy, uint256 _payout) internal {
        uint256 length = prices.length;
        if (length == 0) return;
        
        mapping(uint256 => uint256) storage unWindMap = isBuy ? unWindBuy : unWindSell; 
        
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            delete unWindMap[prices[index]];
            unchecked { --i; }
        }
        if (isBuy) {
            undoStat.undo_assetB = undoStat.undo_assetB > _payout ? undoStat.undo_assetB - _payout : 0;
        } else {
            undoStat.undo_assetA = undoStat.undo_assetA > _payout ? undoStat.undo_assetA - _payout : 0;
        }
    }

    function _handleOrderPlacement(bool placeBuy, bool placeSell, uint256 price) internal {
        if (placeBuy && placeSell) {
            _placeBulk(price);
        } else if (placeBuy) { 
            _place_oneside(true, price);
        } else if (placeSell) {
            _place_oneside(false, price);
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
        uint256 priceDecimals = 10 ** doppiLP.getPriceDecimals();
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
        
        (uint256 minA, uint256 minB) = doppiCore.getMinOrder();
        uint256 length = orderConfigs.length;
        uint256 min = isBuy ? minA : minB;
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

    function _placeBulk(uint256 price) internal {
        (DepositParams[] memory buyDeposits, DualAssetOffer[] memory buyOffers, uint256 availableA) 
            = _prepareOrders(true, price);
        (DepositParams[] memory sellDeposits, DualAssetOffer[] memory sellOffers, uint256 availableB) 
            = _prepareOrders(false, price);
        
        if(buyDeposits.length > 0) _placeOrders(true, buyDeposits, buyOffers, availableA);
        if(sellDeposits.length > 0) _placeOrders(false, sellDeposits, sellOffers, availableB);
        
    }

    function _prepareOrders(bool isBuy, uint256 price) internal view returns (DepositParams[] memory deposits, DualAssetOffer[] memory offers, uint256 availableAsset) {
        uint256 length = orderConfigs.length;
        if (length == 0) return (deposits, offers, 0);
        
        availableAsset = _availableBalance(isBuy);
        if (availableAsset == 0) return (deposits, offers, 0);
        
        (uint256 minA, uint256 minB) = doppiCore.getMinOrder();
        uint256 min = isBuy ? minA : minB;
        
        // Count and prepare in single pass using assembly for array creation
        uint256 validCount = 0;
        
        // First, count valid orders
        for (uint256 i = 0; i < length; ) {
            uint256 depositAmount = (availableAsset * orderConfigs[i].weight) / 10000;
            if (depositAmount >= min) {
                unchecked { ++validCount; }
            }
            unchecked { ++i; }
        }
        
        if (validCount == 0) return (deposits, offers, 0);
        
        // Create arrays with exact size
        deposits = new DepositParams[](validCount);
        offers = new DualAssetOffer[](validCount);
        
        // Populate arrays
        uint256 count = 0;
        for (uint256 i = 0; i < length; ) {
            uint256 depositAmount = (availableAsset * orderConfigs[i].weight) / 10000;
            if (depositAmount >= min) {
                (deposits[count], offers[count]) = _prepareOrder(isBuy, depositAmount, orderConfigs[i], price);
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }
        
        return (deposits, offers, availableAsset);
    }

    function _prepareOrder(bool isBuy, uint256 depositAmount, OrderConfig memory _orderConfig, uint256 price) internal view returns (DepositParams memory deposit, DualAssetOffer memory offer) {
        offer = impliedVol.getSingleOffer(isBuy, traderDefaultDay, _orderConfig.strikeZone, price);
        deposit = DepositParams(depositAmount, _orderConfig.strikeZone, offer.strikePrice, traderDefaultDay, offer.apr, offer.expiry);
    }

    function _placeOrders(
        bool isBuy,
        DepositParams[] memory deposits, 
        DualAssetOffer[] memory offers,
        uint256 available
    ) internal returns (bool) {
        
        doppiCore.bulkDeposit(isBuy, deposits, offers, false);
        emit BulkDeposited(msg.sender, available, isBuy);
        return true;
    }

    function _place_oneside(bool isBuy, uint256 price) internal {
        (DepositParams[] memory deposits, DualAssetOffer[] memory offers, uint256 available) = _prepareOrders(isBuy, price);
        _placeOrders(isBuy, deposits, offers, available);
    }
    
    function _checkUndoTrade(bool _isBuy, uint256 _price) internal view 
        returns (
            uint256[] memory targetPrices, 
            uint256 totalAmount
        ) {
        
        mapping(uint256 => uint256) storage unwindMap = _isBuy ? unWindBuy : unWindSell; 
        
        uint256 round = _getLoopRound(_price, _isBuy);
        
        uint256[] memory tempTargetPrice = new uint256[](round);
        uint256 count = 0;
        // uint256 maxSwapInLocal = isBuy ? config.maxSwap : config.maxSwap * config.decimals / currentPrice;

        for (uint256 i = round; i > 0; ) {

            uint256 origStrikeprice = _getUnwindTargetPrice(_price, uint8(i), _isBuy);
            uint256 amount = unwindMap[origStrikeprice];
            // if (condition && totalAmount <= maxSwapInLocal) {
            if (amount > 0) {
                totalAmount += amount;                
                tempTargetPrice[count] = origStrikeprice;
                count++;
            }
            unchecked { --i; }
        }

        uint256 arrCount = count < round ? count : round;
        targetPrices = new uint256[](arrCount);
        
        for (uint256 j = 0; j < arrCount; ) {
            targetPrices[j] = tempTargetPrice[arrCount - 1 - j];
            unchecked { ++j; }
        }
    }

    function _removeMapping() internal {

        uint256 priceDecimals = 10 ** doppiLP.getPriceDecimals();
        uint256 priceGapWithDecimals = impliedVol.getPriceGapPerOffer() * priceDecimals;
        uint256 diff = upperBound - lowerBound;
        uint256 length = diff / priceGapWithDecimals + 1;

        for (uint256 i = length; i > 0 && lowerBound <= upperBound; ) {
            uint256 index = i - 1;
            delete unWindBuy[lowerBound];
            delete unWindSell[lowerBound];
            lowerBound += priceGapWithDecimals;
            unchecked { --i; }
        }
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
        uint256 acceptedAmount = doppiCore.acceptedDeposit(_isBuy);
        if (acceptedAmount < availableAmount) {
            availableAmount = acceptedAmount;
        }
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