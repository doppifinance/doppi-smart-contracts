// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISwapRouter} from "../Interface/ISwapRouter.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiCore} from "../Interface/IDoppiCore.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import "./DoppiLiquidityTypes.sol";
import "./DoppiCoreTypes.sol";
// import "forge-std/console.sol";

contract DoppiLiquidity is ERC20, Ownable, Pausable, IDoppiLiquidity, AutomationCompatibleInterface, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    Config public config;
    uint16 public constant BASIS_POINTS = 10000;
    IERC20 public immutable assetA;
    IERC20 public immutable assetB;
    address public doppiCore;
    address public doppiTraderFactory;
    mapping(address => bool) public validEntryPoints;
    address public s_forwarderAddress;
    mapping(uint256 => uint256) public amountToBuy;
    mapping(uint256 => uint256) public amountToSell;
    uint256 public upperBound;
    uint256 public lowerBound;


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

    function interestUnwindHedge(
        address _interestToken,
        uint256 interest,
        uint256 swappedHedgeAmount,
        uint256 price,
        bool isBuy
    ) external nonReentrant onlyDoppiCore returns (uint256 hedgeOut, uint256 hedgeTradedPrice) {
        
        IERC20 interestToken = IERC20(_interestToken);
        uint256 interestbal = interestToken.balanceOf(address(this));
        if(interestbal > interest){
            interestToken.safeTransfer(msg.sender, interest);
        }else{
            // swap interest in dex 
            uint256 diff = interest - interestbal;
            address assetIn = _interestToken == address(assetA) ? address(assetB) : address(assetA);
            uint256 amountInInterest = isBuy
                ? (diff * config.decimals) / price
                : (diff * price) / config.decimals;

            _swapExactOutputV3(diff, assetIn, address(interestToken), address(this), amountInInterest); 
            uint256 balInt = interestToken.balanceOf(address(this));
            uint256 interestTosend = balInt > interest ? interest : balInt;
            interestToken.safeTransfer(msg.sender, interestTosend);
        }   
        // after interest sent, unwind hedge in doppilp
        if(swappedHedgeAmount > 0){
            (hedgeOut, hedgeTradedPrice) = _hedgeSwap(swappedHedgeAmount, price, isBuy);
        }
    }

    function settle(uint256 _amountIn, uint256 _payout, uint256 _price, bool _isBuy) external nonReentrant onlyDoppiCore returns (uint256) {
        IERC20 assetIn = _isBuy ? assetA : assetB;
        IERC20 assetOut = _isBuy ? assetB : assetA;

        assetIn.safeTransferFrom(msg.sender, address(this), _amountIn);
        uint256 balance = assetOut.balanceOf(address(this));
        if(_payout > balance){
            uint256 diff = _payout - balance;
            uint256 newAmountIn = _isBuy ? (diff * _price) / config.decimals : (diff * config.decimals) / _price;
            _swapExactOutputV3(diff, address(assetIn), address(assetOut), address(this), newAmountIn); 
            assetOut.safeTransfer(msg.sender, _payout);
        } else {
            assetOut.safeTransfer(msg.sender, _payout);
            _updateUnwindTarget(_amountIn, _price, _isBuy);
        }
        return _payout;
    }

    function swap(uint256 _amountIn, uint256 _price, bool _isBuy) external nonReentrant onlyDoppiCore returns (uint256) {
        uint256 fee = _amountIn * config.liquidityFee / 1_000_000;
        return _swap(_amountIn, _price, _isBuy, fee, false);
    }

    function hedgeSwap(uint256 _amountIn, uint256 _price, bool _isBuy)
        external
        nonReentrant
        onlyDoppiCore
        returns (uint256 amountOut, uint256 tradedPrice)
    {
        return _hedgeSwap(_amountIn, _price, _isBuy);
    }

    function assetRatio() external view returns (uint256 ratioA, uint256 ratioB) {
        uint256 price = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
        uint256 assetBInAValue = assetB.balanceOf(address(this)) * price / config.decimals;
        uint256 assetAvalue = assetA.balanceOf(address(this));
        uint256 total = assetBInAValue + assetAvalue;
        ratioA = total > 0 ? assetAvalue * 1e18 / total : 0;
        ratioB = total > 0 ? 1e18 - ratioA : 0;
    }

    function totalAssetsInAssetA() public view override returns (uint256) {
        uint256 price = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
        return assetA.balanceOf(address(this)) + assetB.balanceOf(address(this)) * price / config.decimals;
    }

    function totalAssetsInAssetB() public view override returns (uint256) {
        uint256 price = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
        return assetB.balanceOf(address(this)) + assetA.balanceOf(address(this)) * config.decimals / price;
    }

    function getPrice() external view returns (uint256) {
        return DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
    }

    function getPriceDecimals() external view returns (uint8) {
        return config.priceDecimals;
    }

    function getMaxDepositAmount(bool isBuy) public view returns (uint256) {
        uint256 poolSize = isBuy ? totalAssetsInAssetA() : totalAssetsInAssetB();
        return (poolSize * config.maxDepositPercentage) / BASIS_POINTS;
    }

    function getPoolCapacityInfo(bool isBuy) external view returns (
        uint256 currentDeposits,
        uint256 maxDepositAmount,
        uint256 availableCapacity
    ) {
        currentDeposits = IDoppiCore(doppiCore).getCurrentDeposits(isBuy);
        maxDepositAmount = getMaxDepositAmount(isBuy);
        availableCapacity = maxDepositAmount > currentDeposits ? maxDepositAmount - currentDeposits : 0;
    }

    function getMaxDepositForUser(bool isBuy, uint256 desiredAmount) external view returns (uint256) {
        uint256 availableCapacity = getMaxDepositAmount(isBuy) - IDoppiCore(doppiCore).getCurrentDeposits(isBuy);
        return desiredAmount > availableCapacity ? availableCapacity : desiredAmount;
    }

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        s_forwarderAddress = forwarderAddress;
    }

    function setDoppiCore(address _doppiCore) external onlyOwner {
        doppiCore = _doppiCore;
    }

    function setConfig(ConfigParam memory _config) external onlyOwner {

        require(_config.maxDepositPercentage <= 50000, "Max deposit too high"); // Max 5x of LP capacity
        require(_config.swapMargin <= 20000, "Swap margin too high"); // Max 2%
        require(_config.liquidityFee <= 5000, "liquidity fee too high"); // Max 0.5%
        
        config.priceDecimals = _config.priceDecimals;
        config.decimals = 10 ** config.priceDecimals;
        config.chainLinkFeed = AggregatorV3Interface(_config.chainLinkFeed);
        config.router = _config.router;
        config.quoter = _config.quoter;
        config.poolFee = _config.poolFee;
        config.slippage = _config.slippage;
        config.liquidityFee = _config.liquidityFee;
        config.swapMargin = _config.swapMargin;
        config.v3Pool = _config.v3Pool;
        config.twapDuration = _config.twapDuration;
        config.maxDepositPercentage = _config.maxDepositPercentage;
        config.maxDelay = _config.maxDelay;
        config.maxSwap = _config.maxSwap;
    }

    function setDoppiTraderFactory(address _traderFactory) external onlyOwner {
        doppiTraderFactory = _traderFactory;
    }

    function setEntryPoint(address entryPoint, bool isValid) external onlyOwner {
        validEntryPoints[entryPoint] = isValid;
         if (isValid) {
            assetA.approve(entryPoint, type(uint256).max);
            assetB.approve(entryPoint, type(uint256).max);
        }
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
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

        uint256 currentPrice = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
        (uint256[] memory buyindexes, uint256 totalBuyAmount) = _getAccumulatedPrices(currentPrice, true);
        (uint256[] memory sellindexes, uint256 totalSellAmount) = _getAccumulatedPrices(currentPrice, false);
        
        if (totalBuyAmount > 0 && totalSellAmount > 0) {
            (bool isNetBuy, uint256 netAmount) = _netoutBuySell(totalSellAmount, totalBuyAmount, currentPrice);
            if(netAmount > 0){
                return (true, abi.encode(isNetBuy, buyindexes, sellindexes, netAmount));
            }
        }

        if (totalBuyAmount > 0) {
            return (true, abi.encode(true, buyindexes, sellindexes, totalBuyAmount));
        }
        
        if (totalSellAmount > 0) {
            return (true, abi.encode(false, buyindexes, sellindexes, totalSellAmount));
        }

        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external override onlyForwarder {
        
        if(paused()) return;
        (bool isNetBuy, uint256[] memory buyindexes, uint256[] memory sellindexes, uint256 totalAmount) = 
            abi.decode(performData, (bool, uint256[], uint256[], uint256));
        
        uint256 totalAmountOut;
        uint256 currentPrice = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
        if (isNetBuy) {
            totalAmountOut = totalAmount * config.decimals / currentPrice;
        } else {
            totalAmountOut = totalAmount * currentPrice / config.decimals;
        }        
        uint256 out = _swapPancake(totalAmount, totalAmountOut, isNetBuy);
        _clearOrders(buyindexes, true);
        _clearOrders(sellindexes, false);

        emit UnwindPerformed(isNetBuy, totalAmount, out);
    }

    function _hedgeSwap(uint256 _amountIn, uint256 _price, bool _isBuy) internal returns (uint256 amountOut, uint256 tradedPrice) {
    
        uint256 bal = (_isBuy ? assetA : assetB).balanceOf(address(this));
        _amountIn = bal < _amountIn ? bal : _amountIn;
        if(_amountIn == 0) return (0, 0);
        if (_isBuy) {  
            amountOut = _swapPancake(_amountIn, _amountIn * config.decimals / _price, true);
            tradedPrice = _amountIn * config.decimals / amountOut;
        } else {
            amountOut = _swapPancake(_amountIn, _amountIn * _price / config.decimals, false);
            tradedPrice = amountOut * config.decimals / _amountIn;
        }
    }

    function _netoutBuySell(uint256 _totalSellAmount, uint256 _totalBuyAmount, uint256 currentPrice) 
        internal view returns (bool isNetBuy, uint256 netSellOrBuy) 
    {
        uint256 totalAmountOutBuy = _totalBuyAmount * config.decimals / currentPrice;
        uint256 totalAmountOutSell = _totalSellAmount * currentPrice / config.decimals;
        
        if(_totalSellAmount > totalAmountOutBuy){
            isNetBuy = false;
            netSellOrBuy = _totalSellAmount - totalAmountOutBuy;
        } else if(_totalBuyAmount > totalAmountOutSell){
            isNetBuy = true;
            netSellOrBuy = _totalBuyAmount - totalAmountOutSell;
        }
    }

    function _clearOrders(uint256[] memory prices, bool isBuy) internal {
        uint256 length = prices.length;
        if (length == 0) return;
        
        mapping(uint256 => uint256) storage amountMap = isBuy ? amountToBuy : amountToSell; // ← This MUST be storage
        
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            delete amountMap[prices[index]];
            unchecked { --i; }
        }
    }

    function _getAccumulatedPrices(
        uint256 currentPrice, 
        bool isBuy
    ) internal view returns (
        uint256[] memory targetPrices, 
        uint256 totalAmount
    ) {
        mapping(uint256 => uint256) storage amountMap = isBuy ? amountToBuy : amountToSell;
        
        uint256 round = _getLoopRound(currentPrice, isBuy);
        uint256[] memory tempTargetPrice = new uint256[](round);
        uint256 count = 0;
        uint256 maxSwapInLocal = isBuy ? config.maxSwap : config.maxSwap * config.decimals / currentPrice;

        for (uint256 i = round; i > 0; ) {

            uint256 price = _getUnwindTargetPrice(currentPrice, uint8(i), !isBuy);
            uint256 amount = amountMap[price];
            bool condition = isBuy 
                ? (amount > 0 && currentPrice < price)
                : (amount > 0 && currentPrice > price);
            
            if (condition && totalAmount <= maxSwapInLocal) {
                totalAmount += amount;                
                tempTargetPrice[count] = price;
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

    function _swapExactOutputV3(uint256 _amountOutAssetB, address _fromToken, address _toToken, address _recipient, uint256 amountIn)
        internal
        returns (uint256 result)
    {
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: _fromToken,
            tokenOut: _toToken,
            fee: config.poolFee,
            recipient: _recipient,
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
        uint256 price = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
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
            assetOut.safeTransfer(msg.sender, amountOut);
            _updateUnwindTarget(_amountIn, _price, _isBuy);
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

    function _getUnwindTargetPrice(uint256 _price, uint8 _zone, bool _isBuy) internal view returns (uint256) {
        uint256 priceGapWithDecimals = 500 * config.decimals;
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * (_zone - 1)) : _price + (priceGapWithDecimals * _zone);
    }

    function _updateUnwindTarget(uint256 _amountIn, uint256 _price, bool _isBuy) internal {
        uint256 targetPrice = _getUnwindTargetPrice(_price, 1, _isBuy);

        if(targetPrice > upperBound){
            upperBound = targetPrice;
        }else if (targetPrice < lowerBound || lowerBound == 0){
            lowerBound = targetPrice;
        }
        if (_isBuy) {
            amountToBuy[targetPrice] += _amountIn;
        } else {
            amountToSell[targetPrice] += _amountIn;
        }
    }

    function _getLoopRound(uint256 _price, bool _isBuy) internal view returns (uint256 round) {

        uint256 firstPrice = _getUnwindTargetPrice(_price, 1, !_isBuy);
        uint256 priceGapWithDecimals = 500 * config.decimals;
        
        uint256 diff;
        if(_isBuy){
            diff = upperBound > firstPrice ? upperBound - firstPrice : 0;
        }else{
            diff = firstPrice > lowerBound ? firstPrice - lowerBound : 0;
        }
        round = diff / priceGapWithDecimals + 1;
    }

    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "invalid forwarder");
        _;
    }
}