// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapRouter} from "../Interface/ISwapRouter.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiCore} from "../Interface/IDoppiCore.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import "./DoppiLiquidityTypes.sol";
import {ERC20 as SoladyERC20} from "solady/tokens/ERC20.sol";
import {Ownable as SoladyOwnable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
// import "forge-std/console.sol";

contract DoppiLiquidity is SoladyERC20, SoladyOwnable, Pausable, IDoppiLiquidity, AutomationCompatibleInterface, ReentrancyGuard {
    using SafeTransferLib for address;
    using Math for uint256;

    struct StrikeNode {
        uint256 prev;
        uint256 next;
        bool active;
    }

    Config public config;
    uint16 public constant BASIS_POINTS = 10000;
    address public assetA;
    address public assetB;
    address public doppiCore;
    
    mapping(address => bool) public allowedTraderFactories;
    mapping(address => bool) private traderFactoryListed;
    address[] private traderFactoryList;
    address public doppiLiquidityRouter;
    mapping(address => bool) public validEntryPoints;
    bool public entryPointsLocked;
    address public s_forwarderAddress;
    string private _tokenName;
    string private _tokenSymbol;
    mapping(uint256 => uint256) public amountToBuy;
    mapping(uint256 => uint256) public amountToSell;
    mapping(uint256 => StrikeNode) internal buyStrikeNodes;
    mapping(uint256 => StrikeNode) internal sellStrikeNodes;
    uint256 internal buyHead;
    uint256 internal buyTail;
    uint256 internal sellHead;
    uint256 internal sellTail;
    uint256 internal activeBuyStrikeCount;
    uint256 internal activeSellStrikeCount;
    


    event Swapped(address indexed trader, address assetIn, address assetOut, uint256 amountIn, uint256 amountOut, uint256 price);
    event UnwindPerformed(bool isNetBuy, uint256 totalAmount, uint256 totalAmountOut);
    event EntryPointSet(address indexed entryPoint, bool isValid);
    event EntryPointsLocked();
    event TraderFactoryAllowed(address indexed traderFactory, bool allowed);
    event EmergencyRedeemed(address indexed owner, address indexed receiver, uint256 shares, uint256 amountA, uint256 amountB);

    modifier onlyDoppiCore() {
        require(msg.sender == doppiCore, "only doppicore");
        _;
    }

    modifier onlySwapCaller() {
        require(msg.sender == doppiCore || _isTraderBotCaller(msg.sender), "only doppicore or trader bot");
        _;
    }

    modifier onlyEntryPoints() {
        require(validEntryPoints[msg.sender], "Not valid entry");
        _;
    }

    constructor(string memory _name, string memory _symbol, address _assetA, address _assetB) {
        _initializeLiquidity(_name, _symbol, _assetA, _assetB, msg.sender);
    }

    function _initializeLiquidity(
        string memory _name,
        string memory _symbol,
        address _assetA,
        address _assetB,
        address initialOwner
    ) internal {
        _tokenName = _name;
        _tokenSymbol = _symbol;
        assetA = _assetA;
        assetB = _assetB;
        _initializeOwner(initialOwner);
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function interestGet(
        address _interestToken,
        uint256 interest,
        uint256 price,
        bool isBuy
    ) external nonReentrant onlyDoppiCore {

        uint256 interestbal = _interestToken.balanceOf(address(this));
        if(interestbal > interest){
            _interestToken.safeTransfer(msg.sender, interest);
        }else{
            // swap interest in dex 
            uint256 diff = interest - interestbal;
            address assetIn = _interestToken == address(assetA) ? address(assetB) : address(assetA);
            uint256 amountInInterest = isBuy
                ? (diff * config.decimals) / price
                : (diff * price) / config.decimals;

            _swapExactOutputV3(diff, assetIn, _interestToken, address(this), amountInInterest); 
            uint256 balInt = _interestToken.balanceOf(address(this));
            uint256 interestTosend = balInt > interest ? interest : balInt;
            _interestToken.safeTransfer(msg.sender, interestTosend);
        }   
    }

    function settle(uint256 _amountIn, uint256 _payout, uint256 _price, bool _isBuy) external nonReentrant onlyDoppiCore returns (uint256) {
        address assetIn = _isBuy ? assetA : assetB;
        address assetOut = _isBuy ? assetB : assetA;

        assetIn.safeTransferFrom(msg.sender, address(this), _amountIn);
        uint256 balance = assetOut.balanceOf(address(this));
        if(_payout > balance){
            uint256 diff = _payout - balance;
            uint256 newAmountIn = _isBuy ? (diff * _price) / config.decimals : (diff * config.decimals) / _price;
            _swapExactOutputV3(diff, assetIn, assetOut, address(this), newAmountIn); 
            assetOut.safeTransfer(msg.sender, _payout);
        } else {
            assetOut.safeTransfer(msg.sender, _payout);
            _updateUnwindTarget(_amountIn, _price, _isBuy);
        }
        return _payout;
    }

    function swap(uint256 _amountIn, uint256 _price, bool _isBuy) external nonReentrant onlySwapCaller returns (uint256) {
        uint256 fee = _amountIn * config.liquidityFee / 1_000_000;
        return _swap(_amountIn, _price, _isBuy, fee, false);
    }

    function _isTraderBotCaller(address caller) internal view returns (bool) {
        uint256 length = traderFactoryList.length;
        for (uint256 i = 0; i < length; ) {
            address factory = traderFactoryList[i];
            if (allowedTraderFactories[factory] && _isBotFromFactory(factory, caller)) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _isBotFromFactory(address factory, address caller) internal view returns (bool) {
        if (factory == address(0) || factory.code.length == 0) return false;
        try IDoppiTraderFactory(factory).isTraderBot(caller) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function assetRatio() external view returns (uint256 ratioA, uint256 ratioB) {
        uint256 price = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
        if (price == 0) return (0, 0);
        uint256 assetBInAValue = assetB.balanceOf(address(this)) * price / config.decimals;
        uint256 assetAvalue = assetA.balanceOf(address(this));
        uint256 total = assetBInAValue + assetAvalue;
        ratioA = total > 0 ? assetAvalue * 1e27 / total : 0;
        ratioB = total > 0 ? 1e27 - ratioA : 0;
    }

    function totalAssetsInAssetA() public view override returns (uint256) {
        uint256 price = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
        if (price == 0) return 0;
        return assetA.balanceOf(address(this)) + assetB.balanceOf(address(this)) * price / config.decimals;
    }

    function totalAssetsInAssetB() public view override returns (uint256) {
        uint256 price = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
        if (price == 0) return 0;
        return assetB.balanceOf(address(this)) + assetA.balanceOf(address(this)) * config.decimals / price;
    }

    function getPrice() external view returns (uint256) {
        return DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
    }

    function getPriceDecimals() external view returns (uint8) {
        return config.priceDecimals;
    }

    function getMaxDepositAmount(bool isBuy) public view returns (uint256) {
        uint256 poolSize = isBuy ? assetA.balanceOf(address(this)) : assetB.balanceOf(address(this));
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

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        require(forwarderAddress != address(0), "zero forwarder");
        s_forwarderAddress = forwarderAddress;
    }

    function setDoppiLiquidityRouter(address _router) external onlyOwner {
        doppiLiquidityRouter = _router;
    }

    function setDoppiCore(address _doppiCore) external onlyOwner {
        doppiCore = _doppiCore;
    }

    function setConfig(ConfigParam memory _config) external onlyOwner {

        require(_config.maxDepositPercentage <= 50000, "Max deposit too high"); // Max 5x of LP capacity
        require(_config.liquidityFee <= 5000, "liquidity fee too high"); // Max 0.5%
        require(_config.priceDecimals > 0, "Invalid price decimals");
        require(_config.priceGap > 0, "Invalid price gap");
        require(_config.unwindGapMultiplier > 0, "Invalid unwind multiplier");
        
        config.priceDecimals = _config.priceDecimals;
        config.decimals = 10 ** config.priceDecimals;
        config.chainLinkFeed = AggregatorV3Interface(_config.chainLinkFeed);
        config.router = _config.router;
        config.poolFee = _config.poolFee;
        config.slippage = _config.slippage;
        config.liquidityFee = _config.liquidityFee;
        config.v3Pool = _config.v3Pool;
        config.twapDuration = _config.twapDuration;
        config.maxDepositPercentage = _config.maxDepositPercentage;
        config.maxDelay = _config.maxDelay;
        config.maxSwap = _config.maxSwap;
        config.priceGap = _config.priceGap;
        config.unwindGapMultiplier = _config.unwindGapMultiplier;
    }

    function setDoppiTraderFactory(address _traderFactory) external onlyOwner {
        _setTraderFactoryAllowed(_traderFactory, true);
    }

    function setTraderFactoryAllowed(address _traderFactory, bool _allowed) external onlyOwner {
        _setTraderFactoryAllowed(_traderFactory, _allowed);
    }

    function _setTraderFactoryAllowed(address _traderFactory, bool _allowed) internal {
        if (_traderFactory == address(0)) return;
        if (!traderFactoryListed[_traderFactory]) {
            traderFactoryList.push(_traderFactory);
            traderFactoryListed[_traderFactory] = true;
        }
        allowedTraderFactories[_traderFactory] = _allowed;
        emit TraderFactoryAllowed(_traderFactory, _allowed);
    }

    function setEntryPoint(address entryPoint, bool isValid) external onlyOwner {
        require(!entryPointsLocked, "entry points locked");
        validEntryPoints[entryPoint] = isValid;
        if (isValid) {
            assetA.safeApprove(entryPoint, type(uint256).max);
            assetB.safeApprove(entryPoint, type(uint256).max);
        } else {
            assetA.safeApprove(entryPoint, 0);  // revoke stale approval
            assetB.safeApprove(entryPoint, 0);
        }
        emit EntryPointSet(entryPoint, isValid);
    }

    function lockEntryPoints() external onlyOwner {
        require(!entryPointsLocked, "already locked");
        entryPointsLocked = true;
        emit EntryPointsLocked();
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }

    function approveRouter() external onlyOwner {
        assetA.safeApprove(config.router, type(uint256).max);
        assetB.safeApprove(config.router, type(uint256).max);
    }

    function mintShares(address to, uint256 amount) external onlyEntryPoints {
        _mint(to, amount);
    }

    function burnShares(address from, uint256 amount) external onlyEntryPoints {
        _burn(from, amount);
    }

    function emergencyRedeemShares(
        address owner,
        uint256 shares,
        address receiver
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        require(msg.sender == doppiLiquidityRouter, "only router");
        require(receiver != address(0), "zero receiver");
        require(shares > 0, "zero shares");

        uint256 totalShares = totalSupply();
        require(totalShares > 0, "zero supply");

        uint256 balA = assetA.balanceOf(address(this));
        uint256 balB = assetB.balanceOf(address(this));
        amountA = (balA * shares) / totalShares;
        amountB = (balB * shares) / totalShares;

        _burn(owner, shares);

        if (amountA > 0) {
            assetA.safeTransfer(receiver, amountA);
        }
        if (amountB > 0) {
            assetB.safeTransfer(receiver, amountB);
        }

        emit EmergencyRedeemed(owner, receiver, shares, amountA, amountB);
    }

    function spendAllowance(address owner, address spender, uint256 amount) external onlyEntryPoints {
        _spendAllowance(owner, spender, amount);
    }

    function getLowerUpperBound() public view returns (uint256 lower, uint256 upper) {
        return _getLowerUpperBound();
    }

    function getBalances(address user) public view returns (uint256 assetABal, uint256 assetBBal) {
        
        (uint256 ratioA, uint256 ratioB) = this.assetRatio();  
        uint256 totalAssetA = totalAssetsInAssetA() * ratioA / 1e27;
        uint256 totalAssetB = totalAssetsInAssetB() * ratioB / 1e27;
        uint256 userShare = balanceOf(user);
        uint256 totalShares = totalSupply();
        assetABal = totalShares > 0 ? (totalAssetA * userShare) / totalShares : 0;
        assetBBal = totalShares > 0 ? (totalAssetB * userShare) / totalShares : 0;

    }

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if(paused()) return (false, bytes(""));

        uint256 currentPrice = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
        if(currentPrice == 0) return (false, bytes(""));

        (uint256[] memory buyindexes, uint256 totalBuyAmount) = _getAccumulatedPrices(currentPrice, true);
        (uint256[] memory sellindexes, uint256 totalSellAmount) = _getAccumulatedPrices(currentPrice, false);
        
        if (totalBuyAmount > 0 || totalSellAmount > 0) {
            (bool isNetBuy, uint256 netAmount) = _netoutBuySell(totalSellAmount, totalBuyAmount, currentPrice);
            return (true, abi.encode(isNetBuy, buyindexes, sellindexes, netAmount, totalBuyAmount, totalSellAmount));
        }

        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external override onlyForwarder {
        
        if(paused()) return;
        (bool isNetBuy, uint256[] memory buyindexes, uint256[] memory sellindexes, uint256 totalAmount, uint256 totalBuyAmount, uint256 totalSellAmount) = 
            abi.decode(performData, (bool, uint256[], uint256[], uint256, uint256, uint256));
        
        uint256 bal = isNetBuy ? assetA.balanceOf(address(this)) : assetB.balanceOf(address(this));
        if(bal >= totalAmount && totalAmount > 0){
            uint256 totalAmountOut;
            uint256 currentPrice = DALiquidityLib.getPriceWithFallback(config.chainLinkFeed, config.v3Pool, config.twapDuration, config.maxDelay);
            if(currentPrice == 0) return;
            
            if (isNetBuy) {
                totalAmountOut = totalAmount * config.decimals / currentPrice;
            } else {
                totalAmountOut = totalAmount * currentPrice / config.decimals;
            }        
            uint256 out = _swapPancake(totalAmount, totalAmountOut, isNetBuy);
            emit UnwindPerformed(isNetBuy, totalAmount, out);
        }
        _clearOrders(buyindexes, true, totalBuyAmount);
        _clearOrders(sellindexes, false, totalSellAmount);
    }

    function cleanUpUnwind(uint256 toClearAmountBuy, uint256 toClearAmountSell) external onlyLiquidityRouterOrOwner {
        _getRemovingPrices(toClearAmountBuy, toClearAmountSell);
    }
        

    function getUnwindInfo(bool isBuy, uint256 strikePrice) external view returns (uint256) {
        return isBuy ? amountToBuy[strikePrice] : amountToSell[strikePrice];
    }

    function _netoutBuySell(uint256 _totalSellAmount, uint256 _totalBuyAmount, uint256 currentPrice) 
        internal view returns (bool isNetBuy, uint256 netSellOrBuy) 
    {
        uint256 totalAmountOutBuy = _totalBuyAmount * config.decimals / currentPrice;
        uint256 totalAmountOutSell = _totalSellAmount * currentPrice / config.decimals;
        
        if(_totalSellAmount > totalAmountOutBuy){
            isNetBuy = false;
            netSellOrBuy = _totalSellAmount - totalAmountOutBuy;
            // check if balance available asset B
        } else if(_totalBuyAmount > totalAmountOutSell){
            isNetBuy = true;
            netSellOrBuy = _totalBuyAmount - totalAmountOutSell;
            // check if balance available asset A
        }
    }

    function _clearOrders(uint256[] memory prices, bool isBuy, uint256 totalUnwind) internal {
        uint256 length = prices.length;
        if (length == 0) return;

        mapping(uint256 => uint256) storage amountMap = isBuy ? amountToBuy : amountToSell;
        uint256 reduced = totalUnwind;

        for (uint256 i = length; i > 0 && reduced > 0; ) {
            reduced = _deductFromBucket(amountMap, prices[i - 1], reduced);
            _syncStrikeState(prices[i - 1], isBuy);
            unchecked { --i; }
        }
    }

    function _getRemovingPrices(
        uint256 removeAmountBuy,
        uint256 removeAmountSell
    ) internal {
        if (removeAmountBuy > 0) {
            uint256 price = buyTail;
            while (price != 0 && removeAmountBuy > 0) {
                uint256 prevStrike = buyStrikeNodes[price].prev;
                removeAmountBuy = _deductFromBucket(amountToBuy, price, removeAmountBuy);
                _syncStrikeState(price, true);
                price = prevStrike;
            }
        }

        if (removeAmountSell > 0) {
            uint256 price = sellHead;
            while (price != 0 && removeAmountSell > 0) {
                uint256 nextStrike = sellStrikeNodes[price].next;
                removeAmountSell = _deductFromBucket(amountToSell, price, removeAmountSell);
                _syncStrikeState(price, false);
                price = nextStrike;
            }
        }
    }

    /// @dev Shared inner helper: deducts `removeAmount` from one price-slot in `amountMap`.
    /// Deletes the slot when fully consumed. Returns the remaining amount to deduct.
    function _deductFromBucket(
        mapping(uint256 => uint256) storage amountMap,
        uint256 price,
        uint256 removeAmount
    ) private returns (uint256 remaining) {
        uint256 slot = amountMap[price];
        if (removeAmount >= slot) {
            delete amountMap[price];
            remaining = removeAmount - slot;
        } else {
            amountMap[price] = slot - removeAmount;
            remaining = 0;
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
        mapping(uint256 => StrikeNode) storage strikeNodes = isBuy ? buyStrikeNodes : sellStrikeNodes;
        
        uint256 round = isBuy ? activeBuyStrikeCount : activeSellStrikeCount;
        if(round == 0) {
            targetPrices = new uint256[](0);
            return (targetPrices, 0);
        }
        uint256[] memory tempTargetPrice = new uint256[](round);
        uint256 count = 0;
        uint256 maxSwapInLocal = isBuy ? config.maxSwap : config.maxSwap * config.decimals / currentPrice;
        
        // bool ascending = isBuy != unwind;
        uint256 strikeprice = isBuy ? buyTail : sellHead; 
        
        while (strikeprice != 0) {
            uint256 nextStrike = isBuy ? strikeNodes[strikeprice].prev : strikeNodes[strikeprice].next;
            
            uint256 amount = amountMap[strikeprice];
            if(totalAmount >= maxSwapInLocal){
                break;
            }
            uint256 totalAmountPost = totalAmount + amount;
            uint256 unwindAmount = totalAmountPost > maxSwapInLocal ? amount - (totalAmountPost - maxSwapInLocal) : amount;
            
            bool condition = isBuy 
                ? (amount > 0 && currentPrice < strikeprice)
                : (amount > 0 && currentPrice > strikeprice);
            
            if (condition && (totalAmount + unwindAmount) <= maxSwapInLocal) {
                totalAmount += unwindAmount;  
                tempTargetPrice[count] = strikeprice;
                count++;
            }
            strikeprice = nextStrike;
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
            amountOutMinimum: amountOutQuote.mulDiv(10000 - config.slippage, 10000),
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
        
        address assetIn = _isBuy ? assetA : assetB;
        address assetOut = _isBuy ? assetB : assetA;

        assetIn.safeTransferFrom(msg.sender, address(this), _amountIn);

        uint256 amountInAfterfee = _amountIn - _fee;
        uint256 amountOut = _isBuy
            ? (amountInAfterfee * config.decimals) / _price
            : (amountInAfterfee * _price) / config.decimals;
        
        uint256 tradedPrice;    
        if(exact){
            uint256 actualAmountIn = _swapExactOutputV3(amountOut, address(assetIn), address(assetOut), msg.sender, _amountIn); 
            if(amountOut > 0){
                tradedPrice = _isBuy
                    ? (actualAmountIn * config.decimals) / amountOut 
                    : (amountOut * config.decimals) / actualAmountIn;
            }
        } else {
            amountOut = _swapExactInputV3(amountInAfterfee, address(assetIn), address(assetOut), msg.sender, amountOut);
            if(amountOut > 0){
                tradedPrice = _isBuy
                    ? (amountInAfterfee * config.decimals) / amountOut 
                    : (amountOut * config.decimals) / amountInAfterfee;
            }
            
        }
        emit Swapped(msg.sender, address(assetIn), address(assetOut), _amountIn, amountOut, tradedPrice);
        return amountOut;
    }

    function _swapPancake(uint256 _amount, uint256 _amountOutQuote, bool _isBuy) internal returns (uint256 shares){
        if (_isBuy) {
            shares = _swapExactInputV3(_amount, assetA, assetB, address(this), _amountOutQuote);
        } else {
            shares = _swapExactInputV3(_amount, assetB, assetA, address(this), _amountOutQuote);
        }
    }

    function _getUnwindTargetPrice(uint256 _price, uint8 _zone, bool _isBuy) internal view returns (uint256) {
        uint256 priceGapWithDecimals = config.priceGap * config.decimals;
        require(priceGapWithDecimals > 0, "Invalid price gap");
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * (_zone - 1)) : _price + (priceGapWithDecimals * _zone);
    }

    function _updateUnwindTarget(uint256 _amountIn, uint256 _price, bool _isBuy) internal {
        
        uint256 targetPrice = _getUnwindTargetPrice(_price, config.unwindGapMultiplier, _isBuy);
        if (_isBuy) {
            amountToBuy[targetPrice] += _amountIn;
        } else {
            amountToSell[targetPrice] += _amountIn;
        }
        _syncStrikeState(targetPrice, _isBuy);
        
    }

    function _syncStrikeState(uint256 strikePrice, bool isBuy) internal {
        
        uint256 unwindAmount = isBuy ? amountToBuy[strikePrice] : amountToSell[strikePrice];
        bool shouldBeActive = unwindAmount > 0;
        if (isBuy) {
            if (shouldBeActive) {
                _activateStrikeNode(buyStrikeNodes, strikePrice, true);
            } else {
                _deactivateStrikeNode(buyStrikeNodes, strikePrice, true);
            }
        } else {
            if (shouldBeActive) {
                _activateStrikeNode(sellStrikeNodes, strikePrice, false);
            } else {
                _deactivateStrikeNode(sellStrikeNodes, strikePrice, false);
            }
        }
    }

    function _activateStrikeNode(
        mapping(uint256 => StrikeNode) storage strikeNodes,
        uint256 strikePrice,
        bool isBuySide
    ) internal {
        StrikeNode storage node = strikeNodes[strikePrice];
        if (node.active) return;

        node.active = true;
        if (isBuySide) {
            unchecked { ++activeBuyStrikeCount; }
        } else {
            unchecked { ++activeSellStrikeCount; }
        }

        uint256 head = isBuySide ? buyHead : sellHead;
        uint256 tail = isBuySide ? buyTail : sellTail;

        if (head == 0) {
            if (isBuySide) {
                buyHead = strikePrice;
                buyTail = strikePrice;
            } else {
                sellHead = strikePrice;
                sellTail = strikePrice;
            }
            return;
        }

        if (strikePrice <= head) {
            node.next = head;
            strikeNodes[head].prev = strikePrice;
            if (isBuySide) buyHead = strikePrice;
            else sellHead = strikePrice;
            return;
        }

        if (strikePrice >= tail) {
            node.prev = tail;
            strikeNodes[tail].next = strikePrice;
            if (isBuySide) buyTail = strikePrice;
            else sellTail = strikePrice;
            return;
        }

        uint256 current = head;
        while (current != 0 && current < strikePrice) {
            current = strikeNodes[current].next;
        }

        uint256 prevNode = strikeNodes[current].prev;
        node.prev = prevNode;
        node.next = current;
        strikeNodes[prevNode].next = strikePrice;
        strikeNodes[current].prev = strikePrice;
    }

    function _deactivateStrikeNode(
        mapping(uint256 => StrikeNode) storage strikeNodes,
        uint256 strikePrice,
        bool isBuySide
    ) internal {
        StrikeNode storage node = strikeNodes[strikePrice];
        
        if (!node.active) return;

        uint256 prevNode = node.prev;
        uint256 nextNode = node.next;

        if (prevNode != 0) {
            strikeNodes[prevNode].next = nextNode;
        } else if (isBuySide) {
            buyHead = nextNode;
        } else {
            sellHead = nextNode;
        }

        if (nextNode != 0) {
            strikeNodes[nextNode].prev = prevNode;
        } else if (isBuySide) {
            buyTail = prevNode;
        } else {
            sellTail = prevNode;
        }

        delete strikeNodes[strikePrice];
        if (isBuySide) {
            if (activeBuyStrikeCount > 0) {
                unchecked { --activeBuyStrikeCount; }
            }
        } else {
            if (activeSellStrikeCount > 0) {
                unchecked { --activeSellStrikeCount; }
            }
        }
    }

    function _getLowerUpperBound() internal view returns (uint256 lower, uint256 upper) {
        
        lower = buyHead == 0
            ? sellHead
            : sellHead == 0
                ? buyHead
                : (buyHead < sellHead ? buyHead : sellHead);

        upper = buyTail > sellTail ? buyTail : sellTail;
        return (lower, upper);
    }


    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "invalid forwarder");
        _;
    }

    modifier onlyLiquidityRouterOrOwner() {
        require(
            msg.sender == doppiLiquidityRouter || msg.sender == owner(),
            "only router or owner"
        );
        _;
    }
}