// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISwapRouter} from "../Interface/ISwapRouter.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {DoppiConfig} from "./DoppiConfig.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import "forge-std/console.sol";

contract DoppiLiquidity is ERC20, Ownable, Pausable, IDoppiLiquidity, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 public immutable assetA;
    IERC20 public immutable assetB;
    address public doppiCore;
    address public doppiTraderFactory;
    DoppiConfig public doppiConfig;
    mapping(address => bool) public validEntryPoints;
    address public s_forwarderAddress;

    mapping(uint256 => uint256) public amountToBuy;
    mapping(uint256 => uint256) public amountToSell;

    uint256[] public toBuyPrices;
    uint256[] public toSellPrices;

    event Swapped(address indexed trader, address assetIn, address assetOut, uint256 amountIn, uint256 amountOut, uint256 price, bool isDEX);
    event UnwindPerformed(bool isNetBuy, uint256 totalAmount, uint256 totalAmountOut);
    
    modifier onlyDoppiCore() {
        require(msg.sender == doppiCore || IDoppiTraderFactory(doppiTraderFactory).isTraderBot(msg.sender), "only doppicore or trader bot");
        _;
    }

    modifier onlyEntryPoints() {
        require(validEntryPoints[msg.sender], "Not valid entry");
        _;
    }

    constructor(string memory _name, string memory _symbol, IERC20 _assetA, IERC20 _assetB)
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        assetA = _assetA;
        assetB = _assetB;
    }

    function settle(uint256 _amountIn, uint256 _price, bool _isBuy) external onlyDoppiCore returns (uint256) {
        return _swap(_amountIn, _price, _isBuy, 0);
    }

    function swap(uint256 _amountIn, uint256 _price, bool _isBuy) external onlyDoppiCore returns (uint256) {
        uint256 fee = _amountIn * doppiConfig.liquidityFee() / 1_000_000;
        return _swap(_amountIn, _price, _isBuy, fee);
    }

    function hedgeSwap(uint256 _amountIn, uint256 _price, bool _isBuy)
        external
        onlyDoppiCore
        returns (uint256 amountOut, uint256 tradedPrice)
    {
        if ((_isBuy ? assetA : assetB).balanceOf(address(this)) < _amountIn) return (0, 0);

        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(doppiConfig.chainLinkFeed());

        if (_isBuy) {  
            amountOut = _swapPancake(_amountIn, _amountIn * (10 ** priceDecimals) / _price, true);
            tradedPrice = _amountIn * (10 ** priceDecimals) / amountOut;
        } else {
            amountOut = _swapPancake(_amountIn, _amountIn * _price / (10 ** priceDecimals), false);
            tradedPrice = amountOut * (10 ** priceDecimals) / _amountIn;
        }
    }

    function transfer(IERC20 token, uint256 amount, address recipient) external onlyDoppiCore {
        token.safeTransfer(recipient, amount);
    }

    function assetRatio() external view returns (uint256 ratioA, uint256 ratioB) {
        uint256 price = DALiquidityLib.getPrice(doppiConfig.chainLinkFeed());
        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(doppiConfig.chainLinkFeed());
        uint256 assetBInAValue = assetB.balanceOf(address(this)) * price / (10 ** priceDecimals);
        uint256 assetAvalue = assetA.balanceOf(address(this));
        ratioA = assetAvalue * 1e18 / (assetBInAValue + assetAvalue);
        ratioB = 1e18 - ratioA;
    }

    function totalAssetsInAssetA() public view override returns (uint256) {
        uint256 price = DALiquidityLib.getPrice(doppiConfig.chainLinkFeed());
        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(doppiConfig.chainLinkFeed());
        return assetA.balanceOf(address(this)) + assetB.balanceOf(address(this)) * price / (10 ** priceDecimals);
    }

    function totalAssetsInAssetB() public view override returns (uint256) {
        uint256 price = DALiquidityLib.getPrice(doppiConfig.chainLinkFeed());
        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(doppiConfig.chainLinkFeed());
        return assetB.balanceOf(address(this)) + assetA.balanceOf(address(this)) * (10 ** priceDecimals) / price;
    }

    function getDoppiConfig() external view returns (address) {
        return address(doppiConfig);
    }

    function getPrice() external view returns (uint256) {
        return DALiquidityLib.getPrice(doppiConfig.chainLinkFeed());
    }

    function getPriceDecimals() external view returns (uint8) {
        return DALiquidityLib.getPriceDecimals(doppiConfig.chainLinkFeed());
    }

    function getToBuyPricesLength() external view returns (uint256) {
        return toBuyPrices.length;
    }

    function getToSellPricesLength() external view returns (uint256) {
        return toSellPrices.length;
    }

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        s_forwarderAddress = forwarderAddress;
    }

    function setDoppiCore(address _doppiCore) external onlyOwner {
        doppiCore = _doppiCore;
    }

    function setDoppiConfig(DoppiConfig _doppiConfig) external onlyOwner {
        doppiConfig = _doppiConfig;
    }

    function setDoppiTraderFactory(address _traderFactory) external onlyOwner {
        doppiTraderFactory = _traderFactory;
    }

    function setEntryPoint(address entryPoint, bool isValid) external onlyOwner {
        validEntryPoints[entryPoint] = isValid;
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }

    function approveEntryPoint(address entryPoint, address token) external onlyOwner {
        require(validEntryPoints[entryPoint], "Invalid entry");
        IERC20(token).approve(entryPoint, type(uint256).max);
    }

    function approveRouter() external onlyOwner {
        assetA.approve(doppiConfig.router(), type(uint256).max);
        assetB.approve(doppiConfig.router(), type(uint256).max);
    }

    function mintShares(address to, uint256 amount) external onlyEntryPoints {
        _mint(to, amount);
    }

    function burnShares(address from, uint256 amount) external onlyEntryPoints {
        _burn(from, amount);
    }

    function spendAllowance(address owner, address spender, uint256 amount) external onlyEntryPoints {
        _spendAllowance(owner, spender, amount);
    }

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if(paused()) return (false, bytes(""));

        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(doppiConfig.chainLinkFeed());
        uint256 currentPrice = DALiquidityLib.getPrice(doppiConfig.chainLinkFeed());

        (uint256[] memory buyindexes, uint256 totalBuyAmount, uint256 totalBuyAmountOut) = 
            _getAccumulatedBuyPrices(currentPrice, priceDecimals);
        (uint256[] memory sellindexes, uint256 totalSellAmount, uint256 totalSellAmountOut) = 
            _getAccumulatedSellPrices(currentPrice, priceDecimals);
        
        if (buyindexes.length > 0 && sellindexes.length > 0) {
            (bool isNetBuy, uint256 netAmount, uint256 netAmountOut) = 
                _netoutBuySell(totalSellAmount, totalSellAmountOut, totalBuyAmount, totalBuyAmountOut);
            
            if (_canSwapPancake(netAmount, netAmountOut, isNetBuy)) {
                return (true, abi.encode(isNetBuy, buyindexes, sellindexes, netAmount, netAmountOut));
            }
        }

        if (totalBuyAmount > 0 && _canSwapPancake(totalBuyAmount, totalBuyAmountOut, true)) {
            return (true, abi.encode(true, buyindexes, sellindexes, totalBuyAmount, totalBuyAmountOut));
        }
        
        if (totalSellAmount > 0 && _canSwapPancake(totalSellAmount, totalSellAmountOut, false)) {
            return (true, abi.encode(false, buyindexes, sellindexes, totalSellAmount, totalSellAmountOut));
        }

        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external override onlyForwarder {
        
        if(paused()) return;
        (bool isNetBuy, uint256[] memory buyindexes, uint256[] memory sellindexes, uint256 totalAmount, uint256 totalAmountOut) = 
            abi.decode(performData, (bool, uint256[], uint256[], uint256, uint256));
        
        uint out = _swapPancake(totalAmount, totalAmountOut, isNetBuy);
        _clearBuyOrders(buyindexes);
        _clearSellOrders(sellindexes);

        emit UnwindPerformed(isNetBuy, totalAmount, out);
    }

    function canSwapPancake(uint256 _amount, uint256 _amountOutQuote, bool _isBuy) external view returns (bool) {
        if (_amount == 0 || _amountOutQuote == 0) return false;

        address tokenIn = _isBuy ? address(assetA) : address(assetB);
        address tokenOut = _isBuy ? address(assetB) : address(assetA);
        
        if (IERC20(tokenIn).balanceOf(address(this)) < _amount) return false;

        bytes memory quoteData = abi.encodeWithSelector(
            IQuoterV2.quoteExactInputSingle.selector,
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: _amount,
                fee: doppiConfig.poolFee(),
                sqrtPriceLimitX96: 0
            })
        );

        (bool success, bytes memory result) = doppiConfig.quoter().staticcall(quoteData);
        
        if (success && result.length >= 32) {
            (uint256 amountOut,,,) = abi.decode(result, (uint256, uint160, uint32, uint256));
            uint256 minRequired = _amountOutQuote * (10000 - doppiConfig.slippage()) / 10000;
            return amountOut >= minRequired;
        }

        return false;
    }

    function _canSwapPancake(uint256 amountIn, uint256 amountOut, bool isBuy) internal view returns (bool) {
        if (amountIn == 0) return false;
        
        try this.canSwapPancake(amountIn, amountOut, isBuy) returns (bool canSwap) {
            return canSwap;
        } catch {
            return false;
        }
    }

    function _netoutBuySell(uint256 _totalSellAmount, uint256 _totalSellAmountOut, uint256 _totalBuyAmount, uint256 _totalBuyAmountOut) 
        internal pure returns (bool isNetBuy, uint256 netSellOrBuy, uint256 netSellOrBuyAmountOut) 
    {
        if(_totalSellAmount > _totalBuyAmountOut){
            isNetBuy = false;
            netSellOrBuy = _totalSellAmount - _totalBuyAmountOut;
            netSellOrBuyAmountOut = _totalSellAmountOut - _totalBuyAmount;
        } else {
            isNetBuy = true;
            netSellOrBuy = _totalBuyAmountOut - _totalSellAmount;
            netSellOrBuyAmountOut = _totalBuyAmount - _totalSellAmountOut;
        }
    }

    function _clearBuyOrders(uint256[] memory indexes) internal {
        uint256 length = indexes.length;
        if(length == 0) return;
        
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            delete amountToBuy[toBuyPrices[indexes[index]]];
            DALiquidityLib.sortedRemove(toBuyPrices, indexes[index]);
            unchecked { --i; }
        }
    }

    function _clearSellOrders(uint256[] memory indexes) internal {
        uint256 length = indexes.length;
        if(length == 0) return;
        
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            delete amountToSell[toSellPrices[indexes[index]]];
            DALiquidityLib.sortedRemove(toSellPrices, indexes[index]);
            unchecked { --i; }
        }
    }

    function _getAccumulatedBuyPrices(uint256 currentPrice, uint8 priceDecimals) internal view returns (
        uint256[] memory _indexes, uint256 totalBuyAmount, uint256 totalBuyAmountOut) 
    {
        uint256 buyPricesLength = toBuyPrices.length;
        if(buyPricesLength == 0) return(new uint256[](0), 0, 0);

        uint256 count = 0;
        for (uint256 i = buyPricesLength; i > 0; ) {
            uint256 price = toBuyPrices[i - 1];
            if (amountToBuy[price] > 0 && currentPrice < price) {
                count++;
            }
            unchecked { --i; }
        }
        
        _indexes = new uint256[](count);
        totalBuyAmount = 0;
        totalBuyAmountOut = 0;
        
        for (uint256 i = buyPricesLength; i > 0; ) {
            uint256 idx = i - 1;
            uint256 buyPrice = toBuyPrices[idx];
            if (amountToBuy[buyPrice] > 0 && currentPrice < buyPrice) {
                uint256 buyAmount = amountToBuy[buyPrice];
                totalBuyAmount += buyAmount;
                totalBuyAmountOut += buyAmount * (10 ** priceDecimals) / currentPrice;
                _indexes[count - 1] = idx;
                count--;
            }
            unchecked { --i; }
        }
    }

    function _getAccumulatedSellPrices(uint256 currentPrice, uint8 priceDecimals) internal view returns (
        uint256[] memory _indexes, uint256 totalSellAmount, uint256 totalSellAmountOut) 
    {
        uint256 sellPricesLength = toSellPrices.length;
        if(sellPricesLength == 0) return(new uint256[](0), 0, 0);
        
        uint256 count = 0;
        for (uint256 i = sellPricesLength; i > 0; ) {
            uint256 price = toSellPrices[i - 1];
            if (amountToSell[price] > 0 && currentPrice > price) {
                count++;
            }
            unchecked { --i; }
        }
        
        _indexes = new uint256[](count);
        totalSellAmount = 0;
        totalSellAmountOut = 0;
        
        for (uint256 i = sellPricesLength; i > 0; ) {
            uint256 idx = i - 1;
            uint256 sellPrice = toSellPrices[idx];
            if (amountToSell[sellPrice] > 0 && currentPrice > sellPrice) {
                uint256 sellAmount = amountToSell[sellPrice];
                totalSellAmount += sellAmount;
                totalSellAmountOut += sellAmount * currentPrice / (10 ** priceDecimals);
                _indexes[count - 1] = idx;
                count--;
            }
            unchecked { --i; }
        }
    }

    function _swapExactInputV3(uint256 _amount, address _fromToken, address _toToken, address _recipient, uint256 amountOutQuote)
        internal
        returns (uint256)
    {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _fromToken,
            tokenOut: _toToken,
            fee: doppiConfig.poolFee(),
            recipient: _recipient,
            amountIn: _amount,
            amountOutMinimum: amountOutQuote * (10000 - doppiConfig.slippage()) / 10000,
            sqrtPriceLimitX96: 0
        });
        return ISwapRouter(doppiConfig.router()).exactInputSingle(params);
    }

    function _swap(
        uint256 _amountIn,
        uint256 _price,
        bool _isBuy,
        uint256 _fee 
    ) internal returns (uint256) {
        uint256 price = DALiquidityLib.getPrice(doppiConfig.chainLinkFeed());
        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(doppiConfig.chainLinkFeed());
        require(_price == price, "Price mismatch");

        IERC20 assetIn = _isBuy ? assetA : assetB;
        IERC20 assetOut = _isBuy ? assetB : assetA;

        assetIn.safeTransferFrom(msg.sender, address(this), _amountIn);

        uint256 amountInAfterfee = _amountIn - _fee;
        uint256 amountOut = _isBuy
            ? (amountInAfterfee) * (10 ** priceDecimals) / _price
            : (amountInAfterfee) * _price / (10 ** priceDecimals);

        uint256 balance = assetOut.balanceOf(address(this));
        bool isDEX = false;
        uint256 tradedPrice = _price;
        if(amountOut > balance){
            isDEX = true;
            amountOut = _swapExactInputV3(amountInAfterfee, address(assetIn), address(assetOut), msg.sender, amountOut);
            tradedPrice = _isBuy
                ? amountInAfterfee * (10 ** priceDecimals) / amountOut 
                : amountOut * (10 ** priceDecimals) / amountInAfterfee;
        } else {
            assetOut.safeTransfer(msg.sender, amountOut);
            uint256 targetPrice = _isBuy
                ? _price * (1_000_000 - doppiConfig.swapMargin()) / 1_000_000
                : _price * (1_000_000 + doppiConfig.swapMargin()) / 1_000_000;

            if (_isBuy) {
                (bool exists, uint256 index) = DALiquidityLib.find(toBuyPrices, targetPrice);
                amountToBuy[targetPrice] += _amountIn;
                if (!exists) DALiquidityLib.sortedInsert(toBuyPrices, index, targetPrice);
            } else {
                (bool exists, uint256 index) = DALiquidityLib.find(toSellPrices, targetPrice);
                amountToSell[targetPrice] += _amountIn;
                if (!exists) DALiquidityLib.sortedInsert(toSellPrices, index, targetPrice);
            }
        }

        emit Swapped(msg.sender, address(assetIn), address(assetOut), _amountIn, amountOut, tradedPrice, isDEX);
        return amountOut;
    }

    function _swapPancake(uint256 _amount, uint256 _amountOutQuote, bool _isBuy) internal returns (uint256 shares){
        if (_isBuy) {
            shares = _swapExactInputV3(_amount, address(assetA), address(assetB), address(this), _amountOutQuote);
        } else {
            shares = _swapExactInputV3(_amount, address(assetB), address(assetA), address(this), _amountOutQuote);
        }
    }
    
    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "invalid forwarder");
        _;
    }
}