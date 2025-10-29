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
import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import "forge-std/console.sol";

contract DoppiLiquidity is ERC20, Ownable, Pausable, IDoppiLiquidity, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct Config {
        AggregatorV3Interface chainLinkFeed; 
        address router; 
        address quoter; 
        uint24 poolFee;  
        uint24 slippage; 
        uint24 liquidityFee; 
        uint32 swapMargin; 
        uint8 priceDecimals;
        uint256 decimals;
        address v3Pool; 
        uint32 twapDuration;
    }

    Config public config;
    uint256 public UPKEEPS_PER_CHECK = 5; // Process 5 upkeeps per check
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
        return _swap(_amountIn, _price, _isBuy, 0, true);
    }

    function swap(uint256 _amountIn, uint256 _price, bool _isBuy) external onlyDoppiCore returns (uint256) {
        uint256 fee = _amountIn * config.liquidityFee / 1_000_000;
        return _swap(_amountIn, _price, _isBuy, fee, false);
    }

    function hedgeSwap(uint256 _amountIn, uint256 _price, bool _isBuy)
        external
        onlyDoppiCore
        returns (uint256 amountOut, uint256 tradedPrice)
    {
        if ((_isBuy ? assetA : assetB).balanceOf(address(this)) < _amountIn) return (0, 0);

        if (_isBuy) {  
            amountOut = _swapPancake(_amountIn, _amountIn * config.decimals / _price, true);
            tradedPrice = _amountIn * config.decimals / amountOut;
        } else {
            amountOut = _swapPancake(_amountIn, _amountIn * _price / config.decimals, false);
            tradedPrice = amountOut * config.decimals / _amountIn;
        }
    }

    function transfer(IERC20 token, uint256 amount, address recipient) external onlyDoppiCore {
        token.safeTransfer(recipient, amount);
    }

    function assetRatio() external view returns (uint256 ratioA, uint256 ratioB) {
        uint256 price = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration);
        uint256 assetBInAValue = assetB.balanceOf(address(this)) * price / config.decimals;
        uint256 assetAvalue = assetA.balanceOf(address(this));
        uint256 total = assetBInAValue + assetAvalue;
        ratioA = total > 0 ? assetAvalue * 1e18 / total : 0;
        ratioB = total > 0 ? 1e18 - ratioA : 0;
    }

    function totalAssetsInAssetA() public view override returns (uint256) {
        uint256 price = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration);
        return assetA.balanceOf(address(this)) + assetB.balanceOf(address(this)) * price / config.decimals;
    }

    function totalAssetsInAssetB() public view override returns (uint256) {
        uint256 price = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration);
        return assetB.balanceOf(address(this)) + assetA.balanceOf(address(this)) * config.decimals / price;
    }

    function getDoppiConfig() external view returns (address) {
        return address(doppiConfig);
    }

    function getPrice() external view returns (uint256) {
        return DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration);
    }

    function getPriceDecimals() external view returns (uint8) {
        return config.priceDecimals;
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

    function setUpkeeps_per_check(uint24 _percheck) external onlyOwner {
        UPKEEPS_PER_CHECK = _percheck;
    }

    /// Copy from doppiconfig to local for gas optimization
    function setDoppiConfig(DoppiConfig _doppiConfig) external onlyOwner {
        doppiConfig = _doppiConfig;
        config.priceDecimals = DALiquidityLib.getPriceDecimals(_doppiConfig.chainLinkFeed());
        config.decimals = 10 ** config.priceDecimals;
        config.chainLinkFeed = AggregatorV3Interface(_doppiConfig.chainLinkFeed());
        config.router = _doppiConfig.router();
        config.quoter = _doppiConfig.quoter();
        config.poolFee = _doppiConfig.poolFee();
        config.slippage = _doppiConfig.slippage();
        config.liquidityFee = _doppiConfig.liquidityFee();
        config.swapMargin = _doppiConfig.swapMargin();
        config.v3Pool = _doppiConfig.pancakeV3Pool();
        config.twapDuration = _doppiConfig.twapDuration();
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
        assetA.approve(config.router, type(uint256).max);
        assetB.approve(config.router, type(uint256).max);
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

        uint256 currentPrice = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration);

        (uint256[] memory buyindexes, uint256 totalBuyAmount, uint256 totalBuyAmountOut) = 
            _getAccumulatedPrices(currentPrice, true);
        (uint256[] memory sellindexes, uint256 totalSellAmount, uint256 totalSellAmountOut) = 
            _getAccumulatedPrices(currentPrice, false);
        
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
        _clearOrders(buyindexes, true);
        _clearOrders(sellindexes, false);

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
                fee: config.poolFee,
                sqrtPriceLimitX96: 0
            })
        );

        (bool success, bytes memory result) = config.quoter.staticcall(quoteData);
        
        if (success && result.length >= 32) {
            (uint256 amountOut,,,) = abi.decode(result, (uint256, uint160, uint32, uint256));
            uint256 minRequired = _amountOutQuote * (10000 - config.slippage) / 10000;
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

    function _clearOrders(uint256[] memory indexes, bool isBuy) internal {
        uint256 length = indexes.length;
        if (length == 0) return;
        
        uint256[] storage priceArray = isBuy ? toBuyPrices : toSellPrices;
        mapping(uint256 => uint256) storage amountMap = isBuy ? amountToBuy : amountToSell; // ← This MUST be storage
        
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            delete amountMap[priceArray[indexes[index]]]; // ← This modifies storage
            DALiquidityLib.sortedRemove(priceArray, indexes[index]);
            unchecked { --i; }
        }
    }

    function _getAccumulatedPrices(
        uint256 currentPrice, 
        bool isBuy
    ) internal view returns (
        uint256[] memory _indexes, 
        uint256 totalAmount, 
        uint256 totalAmountOut
    ) {
        uint256[] storage priceArray = isBuy ? toBuyPrices : toSellPrices;
        mapping(uint256 => uint256) storage amountMap = isBuy ? amountToBuy : amountToSell;
        
        uint256 pricesLength = priceArray.length;
        if (pricesLength == 0) return (new uint256[](0), 0, 0);
        
        uint256[] memory tempIndexes = new uint256[](UPKEEPS_PER_CHECK);
        uint256 count = 0;
        totalAmount = 0;
        totalAmountOut = 0;
        
        for (uint256 i = pricesLength; i > 0 && count < UPKEEPS_PER_CHECK; ) {
            uint256 idx = i - 1;
            uint256 price = priceArray[idx];
            uint256 amount = amountMap[price];
            
            bool condition = isBuy 
                ? (amount > 0 && currentPrice < price)
                : (amount > 0 && currentPrice > price);
            
            if (condition) {
                totalAmount += amount;
                
                if (isBuy) {
                    totalAmountOut += amount * config.decimals / currentPrice;
                } else {
                    totalAmountOut += amount * currentPrice / config.decimals;
                }
                
                tempIndexes[count] = idx;
                count++;
            }
            unchecked { --i; }
        }

        uint256 arrCount = count < UPKEEPS_PER_CHECK ? count : UPKEEPS_PER_CHECK;
        _indexes = new uint256[](arrCount);
        
        for (uint256 j = 0; j < arrCount; ) {
            _indexes[j] = tempIndexes[arrCount - 1 - j];
            unchecked { ++j; }
        }
    }

     function _swapExactOutputV3(uint256 _amountOutAssetB, address _fromToken, address _toToken, address _recipient, uint256 amountIn)
        internal
        returns (uint256 result)
    {
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: _fromToken,
            tokenOut: _toToken,
            fee: config.poolFee,
            recipient: _recipient,
            deadline: block.timestamp + 300, 
            amountOut: _amountOutAssetB,
            amountInMaximum: amountIn.mulDiv(10000 + config.slippage, 10000),
            sqrtPriceLimitX96: 0 // no price limit
        });

        return ISwapRouter(config.router).exactOutputSingle(params);
    }

    function _swapExactInputV3(uint256 _amount, address _fromToken, address _toToken, address _recipient, uint256 amountOutQuote)
        internal
        returns (uint256)
    {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _fromToken,
            tokenOut: _toToken,
            fee: config.poolFee,
            recipient: _recipient,
            amountIn: _amount,
            amountOutMinimum: amountOutQuote * (10000 - config.slippage) / 10000,
            sqrtPriceLimitX96: 0
        });
        return ISwapRouter(config.router).exactInputSingle(params);
    }

    function _swap(
        uint256 _amountIn,
        uint256 _price,
        bool _isBuy,
        uint256 _fee,
        bool exact
    ) internal returns (uint256) {
        
        require(_amountIn > _fee, "Insufficient amount after fee");
        uint256 price = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration);
        require(_price == price, "Price mismatch");

        IERC20 assetIn = _isBuy ? assetA : assetB;
        IERC20 assetOut = _isBuy ? assetB : assetA;

        assetIn.safeTransferFrom(msg.sender, address(this), _amountIn);

        uint256 amountInAfterfee = _amountIn - _fee;
        uint256 amountOut = _isBuy
            ? (amountInAfterfee * config.decimals) / _price
            : (amountInAfterfee * _price) / config.decimals;

        uint256 balance = assetOut.balanceOf(address(this));
        bool isDEX = false;
        uint256 tradedPrice = _price;
        if(amountOut > balance){
            isDEX = true;
            
            if(exact){
                uint256 actualAmountIn = _swapExactOutputV3(amountOut, address(assetIn), address(assetOut), msg.sender, _amountIn); 
                tradedPrice = _isBuy
                    ? (actualAmountIn * config.decimals) / amountOut 
                    : (amountOut * config.decimals) / actualAmountIn;
            } else {
                amountOut = _swapExactInputV3(amountInAfterfee, address(assetIn), address(assetOut), msg.sender, amountOut);
                tradedPrice = _isBuy
                    ? (amountInAfterfee * config.decimals) / amountOut 
                    : (amountOut * config.decimals) / amountInAfterfee;
            }
            
        } else {

            uint256 swapMargin = config.swapMargin;
            uint256 base = 1_000_000;

            assetOut.safeTransfer(msg.sender, amountOut);
            uint256 targetPrice = _isBuy
                ? (_price * (base - swapMargin)) / base
                : (_price * (base + swapMargin)) / base;

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