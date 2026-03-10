// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDoppiCore} from "../Interface/IDoppiCore.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiOffer} from "../Interface/IDoppiOffer.sol";
import {IDoppiUpkeepManager} from "../Interface/IDoppiUpkeepManager.sol";
import {IDoppiLiquidityRouter} from "../Interface/IDoppiLiquidityRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./DoppiCoreTypes.sol";
// import "forge-std/console.sol";


abstract contract DoppiTraderAdminView is Ownable {
    
    IERC20 public assetA;
    IERC20 public assetB;
    IDoppiLiquidity public doppiLP;
    IDoppiCore public doppiCore;
    IDoppiUpkeepManager public doppiUpkeepManager;
    IDoppiLiquidityRouter public doppiRouter;
    IDoppiOffer public impliedVol;

    mapping(uint256 => uint256) public unWindBuy;
    mapping(uint256 => uint256) public unWindSell;

    address public validTrader;
    address public s_forwarderAddress;
    uint8 public traderDefaultDay;
    uint24 public maxOrder;
    uint32 public ratioLP;
    uint256 public upperBound;
    uint256 public lowerBound;
    uint256 public maxSwap;
    uint8 public unwindGapMultiplier;

    
    function getTotalBalancesInLP() external view returns (uint256 totalAssetA, uint256 totalAssetB) {
        uint256 totalAssetLP = doppiLP.totalAssetsInAssetA();
        (uint256 ratioA, ) = doppiLP.assetRatio();        
        totalAssetA = totalAssetLP * ratioA / 1e18;
        totalAssetB = totalAssetLP - totalAssetA;
    }

    function getTotalBalances() external view returns (uint256 totalAssetA, uint256 totalAssetB, uint256 price) {
        
        price = doppiLP.getPrice();
        
        totalAssetA = assetA.balanceOf(address(this));
        totalAssetB = assetB.balanceOf(address(this));
        
        DualAssetPosition[] memory buyPositions = doppiCore.get_positions_buy(address(this));
        uint256 length = buyPositions.length;
        for (uint256 i = 0; i < length; ) {
            totalAssetA += buyPositions[i].amount;
            unchecked { ++i; }
        }
        DualAssetPosition[] memory sellPositions = doppiCore.get_positions_sell(address(this));
        length = sellPositions.length;
        for (uint256 i = 0; i < length; ) {
            totalAssetB += sellPositions[i].amount;
            unchecked { ++i; }
        }
    }

    function get_unrealized_PNL() external view returns (int256 pnl) {
        uint256 price = doppiLP.getPrice();
        uint256 round = _getLoopRound(price, true);   
        int256 pnlprofit = _calcPnL(price, round, true);  
        round = _getLoopRound(price, false);   
        int256 pnlloss = _calcPnL(price, round, false);  
        pnl = pnlprofit + pnlloss;  
    }

    function setDefaultDay(uint8 _day) external onlyOwner {

        bool valid;
        uint8[] memory supportDays = doppiCore.supportDays();
        for (uint8 x = 0; x < supportDays.length; ) {
            if(supportDays[x] == _day){
                valid = true;
                break;
            }
        }
        if(valid){
            traderDefaultDay = _day;
        }
    }

    function setMaxOrder(uint24 _maxOrder) external onlyTrader {
        maxOrder = _maxOrder;
    }

    function setMaxSwap(uint256 _maxSwap) external onlyOwner {
        maxSwap = _maxSwap;
    }

    function setUnwindGapMultiplier(uint8 _multiplier) external onlyOwner {
        unwindGapMultiplier = _multiplier;
    }

    function setForwarderAddress(address forwarderAddress) external onlyUpkeepOrTrader {
        s_forwarderAddress = forwarderAddress;
    }

    function setRatioLP(uint32 _ratioLP) external onlyOwner {
        ratioLP = _ratioLP;
    }

    function getUnwindInfo(bool isBuy, uint256 strikePrice) external view returns (uint256) {
        return isBuy ? unWindBuy[strikePrice] : unWindSell[strikePrice];
    }

    function _updateBound() internal {

        uint256 priceDecimals = 10 ** doppiLP.getPriceDecimals();
        uint256 gap = impliedVol.getPriceGapPerOffer() * priceDecimals;

        // ------------------ UPDATE LOWER BOUND ------------------
        uint256 i = lowerBound;
        while (true) {
            if (unWindBuy[i] != 0 || unWindSell[i] != 0) {
                // Found first valid strike
                lowerBound = i;
                break;
            }
            // move upward
            i += gap;

            // no valid strike left
            if (i > upperBound) {
                _resetBound();
                return;
            }
        }

        // ------------------ UPDATE UPPER BOUND ------------------
        i = upperBound;
        while (true) {
            if (unWindBuy[i] != 0 || unWindSell[i] != 0) {
                upperBound = i;
                break;
            }
            // guard underflow
            if (i < gap) break;
            i -= gap;

            if (i < lowerBound) {
                _resetBound();
                return;
            }
        }
    }

    function _getLoopRound(uint256 _price, bool _isBuy) internal view returns (uint256 round) {

        uint256 firstPrice = _getUnwindTargetPrice(_price, 1, _isBuy);
        uint256 priceDecimals = 10 ** doppiLP.getPriceDecimals();
        uint256 priceGapWithDecimals = impliedVol.getPriceGapPerOffer() * priceDecimals;
        
        uint256 diff;
        if(_isBuy){
            diff = firstPrice > lowerBound ? firstPrice - lowerBound : 0;
        }else{
            diff = upperBound > firstPrice ? upperBound - firstPrice : 0;
        }
        round = diff / priceGapWithDecimals + 1;
    }

    function _calcPnL(uint256 price, uint256 round, bool isBuy) 
        internal view returns (int256 pnl) {
        
        uint256 decimals = 10 ** doppiLP.getPriceDecimals();
        
        for (uint256 i = round; i > 0; ) {
            uint256 origStrikeprice = _getUnwindTargetPrice(price, uint8(i), isBuy);
            uint256 amountOutBuy = unWindBuy[origStrikeprice];
            uint256 amountOutSell = unWindSell[origStrikeprice];
            if(amountOutBuy > 0){
                uint256 currentValueInB = amountOutBuy * price / decimals;
                uint256 origValueInB = amountOutBuy * origStrikeprice / decimals;
                pnl += int256(currentValueInB) - int256(origValueInB);
            }else{
                if(amountOutSell > 0){
                    uint256 currentValueInB = amountOutSell * decimals / price;
                    uint256 origValueInB = amountOutSell * decimals / origStrikeprice;
                    pnl += int256(currentValueInB) - int256(origValueInB);
                }
            }
            unchecked { --i; }
        }
    }

    function _getUnwindTargetPrice(uint256 _price, uint8 _zone, bool _isBuy) internal view returns (uint256) {
        
        uint256 priceDecimals = 10 ** doppiLP.getPriceDecimals();
        uint256 priceGapWithDecimals = impliedVol.getPriceGapPerOffer() * priceDecimals;
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * (_zone - 1)) : _price + (priceGapWithDecimals * _zone);
    }

    function _resetBound() internal {
        uint256 price = doppiLP.getPrice();
        lowerBound = _getUnwindTargetPrice(price, 1, true);
        upperBound = _getUnwindTargetPrice(price, 1, false);
    }

    modifier onlyTrader() {
        require(msg.sender == validTrader, "invalid trader");
        _;
    }

    modifier onlyUpkeepOrTrader() {
        require(
            msg.sender == address(doppiUpkeepManager) || msg.sender == validTrader, "invalid trader or doppiUpkeepManager");
        _;
    }

}
