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
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "forge-std/console.sol";

contract DoppiTrader is Ownable, Pausable, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct Trade {
        uint256 payoutAmount; // 97,750
        uint256 origAmount; // 1 BTC
        uint256 origStrikePrice; // 97,750
    }

    DoppiCore public doppiCore;
    IERC20 public assetA;
    IERC20 public assetB;
    IDoppiLiquidity public doppiLP;
    IDoppiLiquidityRouter public doppiRouter;
    address public s_forwarderAddress;

    uint256 public defaultassetAAmount;
    uint256 public defaultassetBAmount;

    Trade[] public buy_undo_list; // already bought BTC, now need to sell for profit
    Trade[] public sell_undo_list; // already sold BTC, now need to buy back for profit
    uint32 public price_tolerance = 100;
    uint32 public ratioLP = 5000;
    uint256 public undo_assetB;
    uint256 public undo_assetA;
    uint256 public ratio_assetB;
    uint256 public ratio_assetA;
    uint256 public buy_undo_profit;
    uint256 public sell_undo_profit;
    uint24[] public orderWeights;
    uint32 public DEFAULT_DAYS = 1;

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

    function pauseTrades() external onlyOwner {
        _pause();
    }

    function start(uint256 _amountA, uint256 _amountB) external onlyOwner whenPaused {
        _unpause();
        IERC20(assetA).safeTransferFrom(msg.sender, address(this), _amountA);
        IERC20(assetB).safeTransferFrom(msg.sender, address(this), _amountB);
        defaultassetAAmount = _amountA;
        defaultassetBAmount = _amountB;
        uint256 assetAToLP = _amountA.mulDiv(ratioLP, 10000);
        uint256 assetBToLP = _amountB.mulDiv(ratioLP, 10000);
        uint256 shareA = _deposit(address(assetA), assetAToLP);
        uint256 shareB = _deposit(address(assetB), assetBToLP);
        uint256 total = shareA + shareB;
        ratio_assetA = shareA * 10000 / total;
        ratio_assetB = 10000 - ratio_assetA;
        _place_buys();
        _place_sells();
    }

    function stop() external onlyOwner whenPaused {
        uint256 buyPosCount = doppiCore.getBuyPositionCount(address(this));
        uint256 sellPosCount = doppiCore.getSellPositionCount(address(this));
        require(buyPosCount == 0 && sellPosCount == 0, "active order exist");

        uint256 totalBal = doppiLP.balanceOf(address(this));
        uint256 shareA = totalBal * ratio_assetA / 10000;

        _withdrawFromLP(address(assetA), shareA);
        _withdrawFromLP(address(assetB), totalBal - shareA);
        IERC20(assetA).safeTransfer(msg.sender, assetA.balanceOf(address(this)));
        IERC20(assetB).safeTransfer(msg.sender, assetB.balanceOf(address(this)));

        // clean undo array
        delete buy_undo_list;
        delete sell_undo_list;
    }

    function createUnwindPosition(uint256 _amount, uint256 _strikePrice, bool _isBuyUndo) external onlyDualAsset {
        uint8 priceDecimals = doppiLP.getPriceDecimals();

        if (_isBuyUndo) {
            uint256 assetBAmount = _amount.mulDiv(10 ** priceDecimals, _strikePrice);
            buy_undo_list.push(Trade(assetBAmount, _amount, _strikePrice));
            undo_assetB += assetBAmount;
        } else {
            uint256 assetAAmount = _amount.mulDiv(_strikePrice, 10 ** priceDecimals);
            sell_undo_list.push(Trade(assetAAmount, _amount, _strikePrice));
            undo_assetA += assetAAmount;
        }
    }

    function opportunity_bot_trader(uint256 price, uint256 index, bool isBuyUndo) public {
        if (isBuyUndo) {
            _performUnwind(isBuyUndo, buy_undo_list[index], price);
            buy_undo_list[index] = buy_undo_list[buy_undo_list.length - 1];
            buy_undo_list.pop();
        } else {
            _performUnwind(isBuyUndo, sell_undo_list[index], price);
            sell_undo_list[index] = sell_undo_list[sell_undo_list.length - 1];
            sell_undo_list.pop();
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
        for (uint256 i = 0; i < buy_undo_list.length; i++) {
            uint256 currentValue = buy_undo_list[i].payoutAmount.mulDiv(price, 10 ** priceDecimals);
            pnl += int256(currentValue) - int256(buy_undo_list[i].origAmount); // assetA
        }
        return pnl;
    }

    function get_sell_unrealized_PNL() external view returns (int256) {
        int256 pnl = 0;
        uint256 price = doppiLP.getPrice();
        uint8 priceDecimals = doppiLP.getPriceDecimals();

        for (uint256 i = 0; i < sell_undo_list.length; i++) {
            uint256 currentValue = sell_undo_list[i].payoutAmount.mulDiv(10 ** priceDecimals, price);
            pnl += int256(currentValue) - int256(sell_undo_list[i].origAmount); // assetB
        }

        return pnl;
    }

    function setWeight(uint24[] memory _weights) external onlyOwner {
        orderWeights = _weights;
    }

    /// @notice Set the address that `performUpkeep` is called from
    /// @dev Only callable by the owner
    /// @param forwarderAddress the address to set
    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        s_forwarderAddress = forwarderAddress;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256 price = doppiLP.getPrice();
        
        if (!paused()) {
            // place new buy order
            uint256 buyPosCount = doppiCore.getBuyPositionCount(address(this));
            uint256 sellPosCount = doppiCore.getSellPositionCount(address(this));
            if(buyPosCount == 0 && sellPosCount == 0){
                return (true, abi.encode(false, price, 0, false, buyPosCount == 0, sellPosCount == 0));
            }
        }

        (upkeepNeeded, performData) = _checkUndoTrade(true, price);
            
        if (upkeepNeeded) {
            return (true, performData);
        }

        (upkeepNeeded, performData) = _checkUndoTrade(false, price);
        if (upkeepNeeded) {
            return (true, performData);
        }

        
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external override onlyForwarder {
        (bool performUnwind, uint256 price, uint256 index, 
        bool isBuyUndo, bool placeBuy, bool placeSell) = abi.decode(performData, (bool, uint256, uint256, bool, bool, bool));
        
        if(placeBuy){
            _place_buys();
        }
        if (placeSell) {
            _place_sells();
        }
        if (performUnwind) {
            uint256 currentPrice = doppiLP.getPrice();
            uint256 priceChance = price.mulDiv(10000, currentPrice);
            if (priceChance > 10000 + price_tolerance || priceChance < 10000 - price_tolerance) {
                return; // price change outside tolerance
            }
            opportunity_bot_trader(currentPrice, index, isBuyUndo);
        }
    }

    // internal function
    function _place_buys() public returns (bool) {
        uint256 order_amt = assetA.balanceOf(address(this)) - undo_assetA;
        if (order_amt == 0) return false;
        order_amt = order_amt > defaultassetAAmount ? defaultassetAAmount : order_amt;
        assetA.approve(address(doppiCore), order_amt);
        DoppiCore.DualAssetOffer[] memory offers = doppiCore.getBuyOffers(DEFAULT_DAYS);

        DoppiCore.DepositParams[] memory deposits = new DoppiCore.DepositParams[](offers.length);
        for (uint8 i = 0; i < offers.length; i++) {
            deposits[i] = DoppiCore.DepositParams(
                order_amt.mulDiv(orderWeights[i], 10000),
                i,
                offers[i].strikePrice,
                DEFAULT_DAYS,
                offers[i].apr,
                offers[i].validUntilTimestamp
            );
        }
        doppiCore.bulkDepositBuys(deposits, offers);
        return true;
    }

    function _place_sells() public returns (bool) {
        uint256 order_amt = assetB.balanceOf(address(this)) - undo_assetB;
        if (order_amt == 0) return false;
        order_amt = order_amt > defaultassetBAmount ? defaultassetBAmount : order_amt;
        assetB.approve(address(doppiCore), order_amt);
        DoppiCore.DualAssetOffer[] memory offers = doppiCore.getSellOffers(DEFAULT_DAYS);
        DoppiCore.DepositParams[] memory deposits = new DoppiCore.DepositParams[](offers.length);
        for (uint8 i = 0; i < offers.length; i++) {
            deposits[i] = DoppiCore.DepositParams(
                order_amt.mulDiv(orderWeights[i], 10000),
                i,
                offers[i].strikePrice,
                DEFAULT_DAYS,
                offers[i].apr,
                offers[i].validUntilTimestamp
            );
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
        for (uint256 i = 0; i < undo_length; i++) {
            uint256 iteration_index = undo_length - i - 1;
            uint oriStrikePrice = _isBuy ? buy_undo_list[iteration_index].origStrikePrice : sell_undo_list[iteration_index].origStrikePrice;
            uint256 triggerPrice = oriStrikePrice - oriStrikePrice.mulDiv(price_tolerance, 10000);
            
            if(_isBuy && _price >= triggerPrice || !_isBuy && _price <= triggerPrice){
                return (true, abi.encode(true, _price, iteration_index, _isBuy, false, false));
            }
        }
    }

    function _deposit(address _token, uint256 _amount) internal returns (uint256 shares) {
        IERC20(_token).safeIncreaseAllowance(address(doppiRouter), _amount);
        return doppiRouter.deposit(_token, _amount);
    }

    function _withdrawFromLP(address _token, uint256 _shares) internal {
        doppiRouter.redeem(_token, _shares);
    }

    function _performUnwind(bool _isBuy, Trade memory _trade, uint256 _price) internal {

        uint256 triggerPrice = _isBuy ? _trade.origStrikePrice + _trade.origStrikePrice.mulDiv(price_tolerance, 10000) : _trade.origStrikePrice - _trade.origStrikePrice.mulDiv(price_tolerance, 10000);
            
        if (_isBuy && _price >= triggerPrice) {
            // undo trade
            assetB.safeIncreaseAllowance(address(doppiLP), _trade.payoutAmount);
            uint256 amountOut = doppiLP.swap(_trade.payoutAmount, _price, !_isBuy);
            // profit assetA
            buy_undo_profit += amountOut - _trade.origAmount;
            undo_assetB -= _trade.payoutAmount;            
        }
        if (!_isBuy && _price <= triggerPrice) {
            // undo trade
            assetA.safeIncreaseAllowance(address(doppiLP), _trade.payoutAmount);
            uint256 amountOut = doppiLP.swap(_trade.payoutAmount, _price, !_isBuy);
            // profit assetA            
            sell_undo_profit += amountOut - _trade.origAmount;
            undo_assetA -= _trade.payoutAmount;
        }
    }
    
    modifier onlyDualAsset() {
        require(msg.sender == address(doppiCore), "only Dual Asset");
        _;
    }

    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "This address does not have permission to call performUpkeep");
        _;
    }
}
