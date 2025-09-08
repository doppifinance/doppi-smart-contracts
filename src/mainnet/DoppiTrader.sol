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

    DoppiCore public immutable doppiCore;
    IERC20 public immutable assetA;
    IERC20 public immutable assetB;
    IDoppiLiquidity public immutable doppiLP;
    IDoppiLiquidityRouter public immutable doppiRouter;
    DoppiConfig public doppiConfig;
    address public s_forwarderAddress;

    uint256 public defaultassetAAmount;
    uint256 public defaultassetBAmount;

    Trade[] public buy_undo_list;
    Trade[] public sell_undo_list;
    uint256 public undo_assetB;
    uint256 public undo_assetA;
    uint256 public buy_undo_profit;
    uint256 public sell_undo_profit;
    uint24[] public orderWeights;

    constructor(
        address _owner,
        IERC20 _assetA,
        IERC20 _assetB,
        IDoppiLiquidity _doppiLP,
        IDoppiLiquidityRouter _doppiRouter,
        DoppiCore _da,
        uint24[] memory _weights
    ) Ownable(_owner) {
        assetA = _assetA;
        assetB = _assetB;
        doppiLP = _doppiLP;
        doppiRouter = _doppiRouter;
        doppiCore = _da;
        orderWeights = _weights;
        _pause();
    }

    function start(uint256 _amountA, uint256 _amountB) external onlyOwner whenPaused {
        _unpause();
        assetA.safeTransferFrom(msg.sender, address(this), _amountA);
        assetB.safeTransferFrom(msg.sender, address(this), _amountB);
        defaultassetAAmount = _amountA;
        defaultassetBAmount = _amountB;
        uint256 assetAToLP = _amountA * doppiConfig.ratioLP() / 10000;
        uint256 assetBToLP = _amountB * doppiConfig.ratioLP() / 10000;
        _deposit(address(assetA), assetAToLP);
        _deposit(address(assetB), assetBToLP);
        
        _place_buys();
        _place_sells();
    }

    function stop() external onlyOwner whenPaused {
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

    function createUnwindPosition(uint256 _amount, uint256 _strikePrice, bool _isBuyUndo) external onlyDoppiCore {
        uint8 priceDecimals = doppiLP.getPriceDecimals();

        if (_isBuyUndo) {
            uint256 assetBAmount = _amount * (10 ** priceDecimals) / _strikePrice;
            buy_undo_list.push(Trade(assetBAmount, _amount, _strikePrice));
            undo_assetB += assetBAmount;
        } else {
            uint256 assetAAmount = _amount * _strikePrice / (10 ** priceDecimals);
            sell_undo_list.push(Trade(assetAAmount, _amount, _strikePrice));
            undo_assetA += assetAAmount;
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

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }

    function setWeight(uint24[] memory _weights) external onlyOwner {
        orderWeights = _weights;
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
            if(buyPosCount == 0 && sellPosCount == 0){
                return (true, abi.encode(false, price, 0, false, buyPosCount == 0, sellPosCount == 0));
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
        uint256 order_amt = assetA.balanceOf(address(this)) - undo_assetA;
        if (order_amt == 0) return false;
        order_amt = order_amt > defaultassetAAmount ? defaultassetAAmount : order_amt;
        assetA.safeIncreaseAllowance(address(doppiCore), order_amt);
        
        DoppiCore.DualAssetOffer[] memory offers = doppiCore.getBuyOffers(doppiConfig.DEFAULT_DAYS());
        uint256 length = offers.length > orderWeights.length? orderWeights.length : offers.length;
        DoppiCore.DepositParams[] memory deposits = new DoppiCore.DepositParams[](length);
        for (uint8 i = 0; i < length; ) {
            deposits[i] = DoppiCore.DepositParams(
                order_amt * orderWeights[i] / 10000,
                i,
                offers[i].strikePrice,
                doppiConfig.DEFAULT_DAYS(),
                offers[i].apr,
                offers[i].validUntilTimestamp
            );
            unchecked { ++i; }
        }
        doppiCore.bulkDepositBuys(deposits, offers);
        return true;
    }

    function _place_sells() internal returns (bool) {
        uint256 order_amt = assetB.balanceOf(address(this)) - undo_assetB;
        if (order_amt == 0) return false;
        order_amt = order_amt > defaultassetBAmount ? defaultassetBAmount : order_amt;
        assetB.safeIncreaseAllowance(address(doppiCore), order_amt);
        
        DoppiCore.DualAssetOffer[] memory offers = doppiCore.getSellOffers(doppiConfig.DEFAULT_DAYS());
        uint256 length = offers.length > orderWeights.length? orderWeights.length : offers.length;
        DoppiCore.DepositParams[] memory deposits = new DoppiCore.DepositParams[](length);
        
        for (uint8 i = 0; i < length; ) {
            deposits[i] = DoppiCore.DepositParams(
                order_amt * orderWeights[i] / 10000,
                i,
                offers[i].strikePrice,
                doppiConfig.DEFAULT_DAYS(),
                offers[i].apr,
                offers[i].validUntilTimestamp
            );
            unchecked { ++i; }
        }
        doppiCore.bulkDepositSells(deposits, offers);
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
        IERC20(_token).safeIncreaseAllowance(address(doppiRouter), _amount);
        return doppiRouter.deposit(_token, _amount);
    }

    function _withdrawFromLP(uint256 _shares) internal {
        IERC20(doppiLP).safeIncreaseAllowance(address(doppiRouter), _shares);
        doppiRouter.redeem(_shares);
    }

    function _performUnwind(bool _isBuy, Trade memory _trade, uint256 _price) internal {
        uint256 triggerPrice = _isBuy 
            ? _trade.origStrikePrice + (_trade.origStrikePrice * doppiConfig.tolerance() / 10000)
            : _trade.origStrikePrice - (_trade.origStrikePrice * doppiConfig.tolerance() / 10000);
            
        if ((_isBuy && _price >= triggerPrice) || (!_isBuy && _price <= triggerPrice)) {
            IERC20 token = _isBuy ? assetB : assetA;
            token.safeIncreaseAllowance(address(doppiLP), _trade.payoutAmount);
            uint256 amountOut = doppiLP.swap(_trade.payoutAmount, _price, !_isBuy);
            
            if (_isBuy) {
                buy_undo_profit += amountOut - _trade.origAmount;
                undo_assetB -= _trade.payoutAmount;
            } else {
                sell_undo_profit += amountOut - _trade.origAmount;
                undo_assetA -= _trade.payoutAmount;
            }
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