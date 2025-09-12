// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DoppiCore} from "./DoppiCore.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiLiquidityRouter} from "../Interface/IDoppiLiquidityRouter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {DoppiConfig} from "./DoppiConfig.sol";
import "forge-std/console.sol";

contract DoppiTrader is Ownable, Pausable, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct Trade {
        uint256 payoutAmount;
        uint256 origAmount;
        uint256 origStrikePrice;
    }
    struct OrderConfig {
        uint8 strikeZone;
        uint24 weight;
    }

    struct UndoStat {
        uint256 undo_assetB;
        uint256 undo_assetA;
    }

    DoppiCore public immutable doppiCore;
    IERC20 public immutable assetA;
    IERC20 public immutable assetB;
    IDoppiLiquidity public immutable doppiLP;
    IDoppiLiquidityRouter public immutable doppiRouter;
    DoppiConfig public doppiConfig;
    address public s_forwarderAddress;
    address public validTrader;
    uint32 public traderDefaultDay = 1;
    uint256 public minAssetAAmount;
    uint256 public minAssetBAmount;

    Trade[] public buy_undo_list;
    Trade[] public sell_undo_list;

    OrderConfig[] public orderConfigs;
    bool public useCustomConfig;
    UndoStat public undoStat;

    event BulkDeposited(address indexed trader, uint256 totalAmount, bool isBuy);
    event UnwindPerformed(address indexed trader, bool isBuy, uint256 amountOut, uint256 profit, address profitToken);

    constructor(
        address _trader,
        IERC20 _assetA,
        IERC20 _assetB,
        IDoppiLiquidity _doppiLP,
        IDoppiLiquidityRouter _doppiRouter,
        DoppiCore _da,
        uint24[] memory _weights
    ) Ownable(msg.sender) {
        assetA = _assetA;
        assetB = _assetB;
        doppiLP = _doppiLP;
        doppiRouter = _doppiRouter;
        doppiCore = _da;
        validTrader = _trader;
        doppiConfig = DoppiConfig(_doppiLP.getDoppiConfig());
        _pause();
        assetA.safeIncreaseAllowance(address(doppiCore), type(uint256).max);
        assetB.safeIncreaseAllowance(address(doppiCore), type(uint256).max);
        assetB.safeIncreaseAllowance(address(doppiRouter), type(uint256).max);
        assetA.safeIncreaseAllowance(address(doppiRouter), type(uint256).max);
        assetA.safeIncreaseAllowance(address(doppiLP), type(uint256).max);
        assetB.safeIncreaseAllowance(address(doppiLP), type(uint256).max);

        // Initialize with default weights
        _initializeOrderConfigs(_weights);
    }

    function start(uint256 _amountA, uint256 _amountB) external onlyTrader whenPaused {
        
        _unpause();
        assetA.safeTransferFrom(msg.sender, address(this), _amountA);
        assetB.safeTransferFrom(msg.sender, address(this), _amountB);

        minAssetAAmount = _amountA / 10;
        minAssetBAmount = _amountB / 10;

        uint256 assetAToLP = _amountA * doppiConfig.ratioLP() / 10000;
        uint256 assetBToLP = _amountB * doppiConfig.ratioLP() / 10000;
        _deposit(address(assetA), assetAToLP);
        _deposit(address(assetB), assetBToLP);
        
        _place_buys();
        _place_sells();
    }

    function stop() external onlyTrader whenPaused {
        uint256 buyPosCount = doppiCore.getBuyPositionCount(address(this));
        uint256 sellPosCount = doppiCore.getSellPositionCount(address(this));
        require(buyPosCount == 0 && sellPosCount == 0, "active orders");

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
        uint24 sum = _sumArray(weights);
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

    function get_buy_undos() external view returns (Trade[] memory) {
        if (buy_undo_list.length == 0) return new Trade[](0);
        return buy_undo_list;
    }

    function get_sell_undos() external view returns (Trade[] memory) {
        if (sell_undo_list.length == 0) return new Trade[](0);
        return sell_undo_list;
    }

    function get_buy_unrealized_PNL() external view returns (int256) {
        int256 pnl = 0;
        uint256 price = doppiLP.getPrice();
        uint8 priceDecimals = doppiLP.getPriceDecimals();
        uint256 length = buy_undo_list.length;
        
        for (uint256 i = 0; i < length; ) {
            uint256 currentValue = buy_undo_list[i].payoutAmount * price / (10 ** priceDecimals);
            pnl += int256(currentValue) - int256(buy_undo_list[i].origAmount);
            unchecked { ++i; }
        }
        return pnl;
    }

    function get_sell_unrealized_PNL() external view returns (int256) {
        int256 pnl = 0;
        uint256 price = doppiLP.getPrice();
        uint8 priceDecimals = doppiLP.getPriceDecimals();
        uint256 length = sell_undo_list.length;

        for (uint256 i = 0; i < length; ) {
            uint256 currentValue = sell_undo_list[i].payoutAmount * (10 ** priceDecimals) / price;
            pnl += int256(currentValue) - int256(sell_undo_list[i].origAmount);
            unchecked { ++i; }
        }

        return pnl;
    }

    function setPause() external onlyTrader {
        _pause();
    }

    function setUnPause() external onlyTrader {
        _unpause();
    }

    function setDefaultDay(uint32 _day) external onlyTrader {
        traderDefaultDay = _day;
    }

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        s_forwarderAddress = forwarderAddress;
    }

    function setDoppiConfig(DoppiConfig _doppiConfig) external onlyOwner {
        doppiConfig = _doppiConfig;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
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
        if(paused()) return;

        (bool performUnwind, uint256 price, uint256 index, 
        bool isBuyUndo, bool placeBuy, bool placeSell) = abi.decode(performData, (bool, uint256, uint256, bool, bool, bool));
        if(placeBuy) _place_buys();
        if (placeSell) _place_sells();
        
        if (performUnwind) {
            uint256 currentPrice = doppiLP.getPrice();
            uint256 priceChance = price * 10000 / currentPrice;
            if (priceChance > 10000 + doppiConfig.tolerance() || priceChance < 10000 - doppiConfig.tolerance()) {
                return;
            }
            _opportunity_bot_trader(currentPrice, index, isBuyUndo);
        }
    }

    function _opportunity_bot_trader(uint256 price, uint256 index, bool isBuyUndo) internal {
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

    function _place_buys() internal returns (bool) {
        
        uint256 availableAmount = _availableBalance(true);
        if (availableAmount == 0) return false;
        return _placeOrders(true, availableAmount);
    }

    function _place_sells() internal returns (bool) {

        uint256 availableAmount = _availableBalance(false);
        if (availableAmount == 0) return false;
        return _placeOrders(false, availableAmount);
    }

    function _placeOrders(bool isBuy, uint256 totalAmount) internal returns (bool) {
        uint256 length = orderConfigs.length;
        if (length == 0) return false;

        IERC20 token = isBuy ? assetA : assetB;
        
        DoppiCore.DepositParams[] memory deposits = new DoppiCore.DepositParams[](length);
        DoppiCore.DualAssetOffer[] memory offers = new DoppiCore.DualAssetOffer[](length);
        
        uint256 totalWeight = 10000;
        
        for (uint256 i = 0; i < length; ) {
            DoppiCore.DualAssetOffer memory offer = doppiCore.getOffer(
                isBuy, 
                traderDefaultDay, 
                orderConfigs[i].strikeZone
            );
            offers[i] = offer;
            uint256 depositAmount = (totalAmount * orderConfigs[i].weight) / totalWeight;
            deposits[i] = DoppiCore.DepositParams(
                depositAmount, // More precise calculation
                orderConfigs[i].strikeZone,
                offer.strikePrice,
                traderDefaultDay,
                offer.apr,
                offer.validUntilTimestamp
            );
            unchecked { ++i; }
        }
        
        if (isBuy) {
            doppiCore.bulkDepositBuys(deposits, offers);
        } else {
            doppiCore.bulkDepositSells(deposits, offers);
        }
        
        emit BulkDeposited(msg.sender, totalAmount, isBuy);
        return true;
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
            
        IERC20 token = _isBuy ? assetB : assetA;
         
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

    function _sumArray(uint24[] calldata arr) private pure returns(uint24) {
        uint24 i;
        uint24 sum = 0;
            
        for(i = 0; i < arr.length; i++)
            sum = sum + arr[i];
        return sum;
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

    modifier onlyTrader() {
        require(msg.sender == validTrader, "invalid trader");
        _;
    }
}