// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol"; 
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDoppiOffer} from "../Interface/IDoppiOffer.sol";
import {IDoppiUpkeepManager} from "../Interface/IDoppiUpkeepManager.sol";
import {IDoppiLiquidityRouter} from "../Interface/IDoppiLiquidityRouter.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import "./DoppiCoreTypes.sol";
import "./DoppiTraderAdminView.sol";
// import "forge-std/console.sol";

contract DoppiTrader is DoppiTraderAdminView, ReentrancyGuard, AutomationCompatibleInterface, Initializable {
    using SafeERC20 for IERC20;
    
    bool private initialized;
    IDoppiUpkeepManager public doppiUpkeepManager;
    IDoppiLiquidityRouter public doppiRouter;
    IDoppiOffer public impliedVol;
    uint256 public minAssetAAmount;
    uint256 public minAssetBAmount;

    OrderConfig[] public orderConfigs;
    bool public useCustomConfig;
    UndoStat public undoStat;

    event BulkDeposited(address indexed trader, uint256 totalAmount, bool isBuy);
    event UnwindPerformed(address indexed trader, bool isBuy, uint256 amountOut, uint256 profit, address profitToken);

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
        doppiConfig = DoppiConfig(doppiLP.getDoppiConfig());
        _transferOwnership(msg.sender); // Transfer ownership to the trader

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
        minAssetAAmount = doppiConfig.minimal_assetA();
        minAssetBAmount = doppiConfig.minimal_assetB();
        doppiUpkeepManager = IDoppiUpkeepManager(doppiConfig.doppiUpKeepManager());
        impliedVol = IDoppiOffer(doppiConfig.doppiOffer());
        traderDefaultDay = 1;
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

        delete buy_undo_list;
        delete sell_undo_list;
    }

    function emergencyWithdraw() external onlyTrader nonReentrant {
        require(doppiCore.isEmergency() && doppiCore.paused(), "only for emergency");

        doppiCore.emergencyWithdraw();
        assetA.safeTransfer(msg.sender, assetA.balanceOf(address(this)));
        assetB.safeTransfer(msg.sender, assetB.balanceOf(address(this)));

        delete buy_undo_list;
        delete sell_undo_list;
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
        if(strikeZones.length > doppiConfig.MAX_ORDER() 
            && weights.length > doppiConfig.MAX_ORDER()
        ) revert MaxLimit();
        
        uint24 sum = DALiquidityLib.sumArray(weights);
        if(sum != 10000) revert MustHundred();
        
        delete orderConfigs;
        for (uint256 i = 0; i < weights.length; i++) {
            if(strikeZones[i] > doppiConfig.MAX_ORDER()) revert ExceedMaxZone();
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
        uint24[] memory defaultWeights = new uint24[](doppiConfig.MAX_ORDER());
        uint24 equalWeight = uint24(10000 / doppiConfig.MAX_ORDER());
        uint24 total = 0;
        
        for (uint8 i = 0; i < doppiConfig.MAX_ORDER() - 1; i++) {
            defaultWeights[i] = equalWeight;
            total += equalWeight;
        }
        defaultWeights[doppiConfig.MAX_ORDER() - 1] = 10000 - total;
        _initializeOrderConfigs(defaultWeights);
        useCustomConfig = false;
    }

    function createUnwindPosition(uint256 _amount, uint256 _strikePrice, bool _isBuyUndo) external onlyDoppiCore {
        uint8 priceDecimals = doppiLP.getPriceDecimals();
        uint256 assetAmount = _isBuyUndo 
            ? _amount * (10 ** priceDecimals) / _strikePrice
            : _amount * _strikePrice / (10 ** priceDecimals);

        if (_isBuyUndo) {
            buy_undo_list.push(Trade(assetAmount, _amount, _strikePrice));
            undoStat.undo_assetB += assetAmount;
        } else {
            sell_undo_list.push(Trade(assetAmount, _amount, _strikePrice));
            undoStat.undo_assetA += assetAmount;
        }
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        
        if(s_forwarderAddress == address(0)) return (false, bytes(""));
        uint256 price = doppiLP.getPrice();
        
        (bool toBuy, bool toSell) = _shouldPlaceOrders();
        if(toBuy || toSell) return (true, abi.encode(false, price, 0, false, toBuy, toSell));

        (upkeepNeeded, performData) = _checkUndoTrade(true, price);
        if (upkeepNeeded) return (true, performData);
        _checkUndoTrade(false, price);
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant onlyForwarder {
        
        if(s_forwarderAddress == address(0)) return;

        (bool performUnwind, uint256 price, uint256 index, 
        bool isBuyUndo, bool placeBuy, bool placeSell) = abi.decode(performData, (bool, uint256, uint256, bool, bool, bool));
        
        uint256 currentPrice = doppiLP.getPrice();

        if (placeBuy || placeSell) {
            _handleOrderPlacement(placeBuy, placeSell, currentPrice);
        }
        if (performUnwind && _isWithinTolerance(currentPrice, price)) {
            _unwind_bot_trader(currentPrice, index, isBuyUndo);
        }
    }

    function _updateForwarder() internal {
        uint256 upKeepId = doppiUpkeepManager.getUpkeepIdByBot(address(this));
        s_forwarderAddress = doppiUpkeepManager.getForwarder(upKeepId);
    }

    function _isWithinTolerance(uint256 currentPrice, uint256 referencePrice) internal view returns (bool) {
        uint256 tolerance = doppiConfig.tolerance();
        uint256 priceRatio = (currentPrice * 10000) / referencePrice;
        return priceRatio > (10000 - tolerance) && priceRatio < (10000 + tolerance);
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

    function _shouldPlaceOrders() internal view returns (bool toBuy, bool toSell) {
        if(doppiCore.paused()) return (false, false); 
        uint256 buyPosCount = doppiCore.getBuyPositionCount(address(this));
        uint256 sellPosCount = doppiCore.getSellPositionCount(address(this));
        toBuy = buyPosCount == 0 && _availableBalance(true) > 0;
        toSell = sellPosCount == 0 && _availableBalance(false) > 0;
    }

    function _processDeposit(uint256 _amountA, uint256 _amountB) internal {
        if(_amountA > 0) _transferAndDeposit(assetA, _amountA);
        if(_amountB > 0) _transferAndDeposit(assetB, _amountB);
    }

    function _transferAndDeposit(IERC20 token, uint256 amount) internal {
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 toLP = amount * doppiConfig.ratioLP() / 10000;
        _deposit(address(token), toLP);
    }

    function _unwind_bot_trader(uint256 price, uint256 index, bool isBuyUndo) internal {
        Trade[] storage undoList = isBuyUndo ? buy_undo_list : sell_undo_list;
        _performUnwind(isBuyUndo, undoList[index], price);
        
        uint256 lastIndex = undoList.length - 1;
        if (index != lastIndex) {
            undoList[index] = undoList[lastIndex];
        }
        undoList.pop();
    }

    function _placeBulk(uint256 price) internal {
        (DepositParams[] memory buyDeposits, DualAssetOffer[] memory buyOffers) 
            = _prepareOrders(true, price);
        (DepositParams[] memory sellDeposits, DualAssetOffer[] memory sellOffers) 
            = _prepareOrders(false, price);
        
        if(buyDeposits.length > 0) _placeOrders(true, buyDeposits, buyOffers);
        if(sellDeposits.length > 0) _placeOrders(false, sellDeposits, sellOffers);
        
    }

    function _prepareOrders(bool isBuy, uint256 price) internal view returns (DepositParams[] memory deposits, DualAssetOffer[] memory offers) {
        uint256 length = orderConfigs.length;
        if (length == 0) return (deposits, offers);
        
        uint256 availableAsset = _availableBalance(isBuy);
        if (availableAsset == 0) return (deposits, offers);
        
        deposits = new DepositParams[](length);
        offers = new DualAssetOffer[](length);
        for (uint256 i = 0; i < length; ) {
            (deposits[i], offers[i]) = _prepareOrder(isBuy, availableAsset, orderConfigs[i], price);
            unchecked { ++i; }
        }
    }

    function _prepareOrder(bool isBuy, uint256 totalamount, OrderConfig memory _orderConfig, uint256 price) internal view returns (DepositParams memory deposit, DualAssetOffer memory offer) {
        offer = impliedVol.getSingleOffer(isBuy, traderDefaultDay, _orderConfig.strikeZone, price);
        uint256 depositAmount = (totalamount * _orderConfig.weight) / 10000;
        deposit = DepositParams(depositAmount, _orderConfig.strikeZone, offer.strikePrice, traderDefaultDay, offer.apr, offer.expiry);
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

    function _place_oneside(bool isBuy, uint256 price) internal {
        (DepositParams[] memory deposits, DualAssetOffer[] memory offers) = _prepareOrders(isBuy, price);
        _placeOrders(isBuy, deposits, offers);
    }
    
    function _checkUndoTrade(bool _isBuy, uint256 _price) internal view returns (bool upkeepNeeded, bytes memory performData) {
        Trade[] storage undoList = _isBuy ? buy_undo_list : sell_undo_list;
        uint256 undo_length = undoList.length;
        for (uint256 i = 0; i < undo_length; ) {
            uint256 iteration_index = undo_length - i - 1;
            uint256 triggerPrice = undoList[iteration_index].origStrikePrice - (undoList[iteration_index].origStrikePrice * doppiConfig.tolerance() / 10000);
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
            uint256 profit = amountOut >= _trade.origAmount ? amountOut - _trade.origAmount : 0;

            if (_isBuy) {
                undoStat.undo_assetB -= _trade.payoutAmount;
            } else {
                undoStat.undo_assetA -= _trade.payoutAmount;
            }
            emit UnwindPerformed(address(this), _isBuy, amountOut, profit, _isBuy ? address(assetA) : address(assetB));
        }
    }

    function _initializeOrderConfigs(uint24[] memory _weights) internal {
        uint256 length = _weights.length;
        for (uint8 i = 0; i < length; ) {
            orderConfigs.push(OrderConfig(i, _weights[i]));
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