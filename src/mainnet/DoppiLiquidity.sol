// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20, IERC20Metadata, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import {ISwapRouter} from "../Interface/ISwapRouter.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiTraderFactory} from "../Interface/IDoppiTraderFactory.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "forge-std/console.sol";
// features: Vault, Chainlink Price, Pancake Price, Swap with pancake, arbitrage with pancake, Swap with own liquidity pool

contract DoppiLiquidity is ERC20, Ownable, IDoppiLiquidity, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 public assetA;
    IERC20 public assetB;
    AggregatorV3Interface public chainLinkFeed = AggregatorV3Interface(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
    address public router = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address public quoter = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address public doppiCore;
    address public doppiTraderFactory;
    address public treasury;
    address public pancakeV3Pool = 0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4;
    uint32 public twapDuration = 10;
    uint24 public poolFee = 500;
    uint24 public slippage = 100;
    uint24 public liquidityFee = 1000;
    uint32 public swapMargin = 10000; // 1%
    mapping(address => bool) public validEntryPoints;
    address public s_forwarderAddress;

    // price to amount mapping
    mapping(uint256 => uint256) public amountToBuy;
    mapping(uint256 => uint256) public amountToSell;

    // sorted arrays for prices, ascending order
    uint256[] public toBuyPrices;
    uint256[] public toSellPrices;

    modifier onlyDoppiContract() {
        require(
            msg.sender == doppiCore || IDoppiTraderFactory(doppiTraderFactory).isTraderBot(msg.sender),
            "Not privileged"
        );
        _;
    }

    modifier onlyEntryPoints() {
        require(validEntryPoints[msg.sender], "Not a valid entry point");
        _;
    }

    constructor(string memory _name, string memory _symbol, IERC20 _assetA, IERC20 _assetB, address _treasury)
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        assetA = _assetA;
        assetB = _assetB;
        treasury = _treasury;
    }

    

    function settle(uint256 _amountIn, uint256 _price, bool _isBuy) external onlyDoppiContract returns (uint256) {
        
        if(_isBuy){
            return _settle_buy(_amountIn, _price, _isBuy);
        }else{
            return _settle_sell(_amountIn, _price, _isBuy);
        }
    }

    function swap(uint256 _amountIn, uint256 _price, bool _isBuy) external onlyDoppiContract returns (uint256) {
        
        uint256 fee = _amountIn.mulDiv(liquidityFee, 1_000_000);
        return _swap(_amountIn, _price, _isBuy, fee);
    }

    function hedgeSwap(uint256 _amountIn, uint256 _price, bool _isBuy)
        external
        onlyDoppiContract
        returns (uint256 amountOut, uint256 tradedPrice)
    {

        if ((_isBuy ? assetA : assetB).balanceOf(address(this)) < _amountIn) return (0, 0);

        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(chainLinkFeed);

        if (_isBuy) {  
            amountOut  = _swapPancake(_amountIn, _amountIn.mulDiv(10 ** priceDecimals, _price), true);
            tradedPrice = _amountIn.mulDiv(10 ** priceDecimals, amountOut);
        } else {
            amountOut  = _swapPancake(_amountIn, _amountIn.mulDiv(_price, 10 ** priceDecimals), false);
            tradedPrice = amountOut.mulDiv(10 ** priceDecimals, _amountIn);
        }
    }

    function transfer(IERC20 token, uint256 amount, address recipient) external onlyDoppiContract {
        token.safeTransfer(recipient, amount);
    }

    // For unwind
    function unwindSwapOrder(uint256 _index, bool _isBuy) public {
        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(chainLinkFeed);

        if (_isBuy) {
            uint256 price = toBuyPrices[_index];
            uint256 amount = amountToBuy[price];

            _swapPancake(amount, amount.mulDiv(10 ** priceDecimals, price), true);

            delete amountToBuy[price];
            DALiquidityLib.sortedRemove(toBuyPrices, _index);
        } else {
            uint256 price = toSellPrices[_index];
            uint256 amount = amountToSell[price];

            _swapPancake(amount, amount.mulDiv(price, 10 ** priceDecimals), false);

            delete amountToSell[price];
            DALiquidityLib.sortedRemove(toSellPrices, _index);
        }
    }

    function totalAssetsInAssetA() public view override returns (uint256) {
        uint256 price = DALiquidityLib.getPrice(chainLinkFeed);
        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(chainLinkFeed);
        return assetA.balanceOf(address(this)) + assetB.balanceOf(address(this)).mulDiv(price, 10 ** priceDecimals);
    }

    function totalAssetsInAssetB() public view override returns (uint256) {
        uint256 price = DALiquidityLib.getPrice(chainLinkFeed);
        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(chainLinkFeed);
        return assetB.balanceOf(address(this)) + assetA.balanceOf(address(this)).mulDiv(10 ** priceDecimals, price);
    }

    function getPrice() external view returns (uint256) {
        return DALiquidityLib.getPrice(chainLinkFeed);
    }

    function getPriceDecimals() external view returns (uint8) {
        return DALiquidityLib.getPriceDecimals(chainLinkFeed);
    }

    function getToBuyPricesLength() external view returns (uint256) {
        return toBuyPrices.length;
    }

    function getToSellPricesLength() external view returns (uint256) {
        return toSellPrices.length;
    }

    function getBalanceAssetA() external view returns (uint256) {
        return assetA.balanceOf(address(this));
    }

    function getBalanceAssetB() external view returns (uint256) {
        return assetB.balanceOf(address(this));
    }

    /// @notice Set the address that `performUpkeep` is called from
    /// @dev Only callable by the owner
    /// @param forwarderAddress the address to set
    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        s_forwarderAddress = forwarderAddress;
    }

    function setDualAsset(address _dualAsset) external onlyOwner {
        doppiCore = _dualAsset;
    }

    function setOracle(address _newOracle) external onlyOwner {
        chainLinkFeed = AggregatorV3Interface(_newOracle);
    }

    function setDoppiTraderFactory(address _traderFactory) external onlyOwner {
        doppiTraderFactory = _traderFactory;
    }

    function setEntryPoint(address entryPoint, bool isValid) external onlyOwner {
        validEntryPoints[entryPoint] = isValid;
    }

    function approveEntryPoint(address entryPoint, address token) external onlyOwner {
        require(validEntryPoints[entryPoint], "Invalid entry point");
        IERC20(token).approve(entryPoint, type(uint256).max);
    }

    function setRouter(address _router) external onlyOwner {
        router = _router;
    }

    function setPancakeV3Pool(address _pool) external onlyOwner {
        pancakeV3Pool = _pool;
    }

    function setQuoter(address _quoter) external onlyOwner {
        quoter = _quoter;
    }

    function approveRouter() external onlyOwner {
        assetA.approve(router, type(uint256).max);
        assetB.approve(router, type(uint256).max);
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

    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // Check toBuyPrices - check highest buy price (last in sorted array) since it's most likely to be triggered
        if (toBuyPrices.length > 0) {
            uint256 highestBuyIndex = toBuyPrices.length - 1;
            uint256 highestBuyPrice = toBuyPrices[highestBuyIndex];

            if (amountToBuy[highestBuyPrice] > 0) {
                // Try static call to swapPancake to see if it would succeed
                uint8 priceDecimals = DALiquidityLib.getPriceDecimals(chainLinkFeed);
                uint256 amount = amountToBuy[highestBuyPrice];
                uint256 amountOut = amount.mulDiv(10 ** priceDecimals, highestBuyPrice);

                try this.canSwapPancake(amount, amountOut, true) returns (bool canSwap) {
                    if (canSwap) {
                        return (true, abi.encode(highestBuyIndex, true));
                    }
                } catch {
                    // Continue to check sell prices
                }
            }
        }

        // Check toSellPrices - check lowest sell price (first in sorted array) since it's most likely to be triggered
        if (toSellPrices.length > 0) {
            uint256 lowestSellPrice = toSellPrices[0];

            if (amountToSell[lowestSellPrice] > 0) {
                // Try static call to swapPancake to see if it would succeed
                uint8 priceDecimals = DALiquidityLib.getPriceDecimals(chainLinkFeed);
                uint256 amount = amountToSell[lowestSellPrice];
                uint256 amountOut = amount.mulDiv(lowestSellPrice, 10 ** priceDecimals);

                try this.canSwapPancake(amount, amountOut, false) returns (bool canSwap) {
                    if (canSwap) {
                        return (true, abi.encode(0, false));
                    }
                } catch {
                    // Continue
                }
            }
        }

        return (false, "0x");
    }

    function performUpkeep(bytes calldata performData) external override onlyForwarder {
        (uint256 index, bool isBuy) = abi.decode(performData, (uint256, bool));

        if (isBuy) {
            require(index < toBuyPrices.length, "Invalid buy index");
            require(amountToBuy[toBuyPrices[index]] > 0, "No amount to buy");
        } else {
            require(index < toSellPrices.length, "Invalid sell index");
            require(amountToSell[toSellPrices[index]] > 0, "No amount to sell");
        }

        unwindSwapOrder(index, isBuy);
    }

    function canSwapPancake(uint256 _amount, uint256 _amountOutQuote, bool _isBuy) external view returns (bool) {
        // Basic validation first
        if (_amount == 0 || _amountOutQuote == 0) return false;

        address tokenIn;
        address tokenOut;

        if (_isBuy) {
            tokenIn = address(assetA);
            tokenOut = address(assetB);
            if (assetA.balanceOf(address(this)) < _amount) return false;
        } else {
            tokenIn = address(assetB);
            tokenOut = address(assetA);
            if (assetB.balanceOf(address(this)) < _amount) return false;
        }

        // Use QuoterV2 with static call to simulate swap without state changes
        bytes memory quoteData = abi.encodeWithSelector(
            IQuoterV2.quoteExactInputSingle.selector,
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: _amount,
                fee: poolFee,
                sqrtPriceLimitX96: 0
            })
        );

        (bool success, bytes memory result) = quoter.staticcall(quoteData);
        console.log("QuoterV2 call success:", success);
        console.log("QuoterV2 result length:", result.length);

        // Handle successful quoter response
        if (success && result.length >= 32) {
            // QuoterV2 returns (amountOut, sqrtPriceX96After, initializedTicksCrossed, gasEstimate)
            (uint256 amountOut,,,) = abi.decode(result, (uint256, uint160, uint32, uint256));
            console.log("Quoted amountOut:", amountOut);
            uint256 minRequired = _amountOutQuote.mulDiv(10000 - slippage, 10000);
            console.log("Min required:", minRequired);
            return amountOut >= minRequired;
        }

        return false;
    }

    // internal
    function _swapExactInputV3(uint256 _amount, address _fromToken, address _toToken, address _recipient, uint256 amountOutQuote)
        internal
        returns (uint256)
    {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _fromToken,
            tokenOut: _toToken,
            fee: poolFee,
            recipient: _recipient,
            amountIn: _amount,
            amountOutMinimum: amountOutQuote.mulDiv(10000 - slippage, 10000),
            sqrtPriceLimitX96: 0
        });
        return ISwapRouter(router).exactInputSingle(params);
    }

    function _swapExactOutputV3(uint256 _amountOutAssetB, address _fromToken, address _toToken, address _recipient, uint256 amountIn)
        internal
        returns (uint256 result)
    {
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: _fromToken,
            tokenOut: _toToken,
            fee: poolFee,
            recipient: _recipient,
            deadline: block.timestamp + 300, 
            amountOut: _amountOutAssetB,
            amountInMaximum: amountIn.mulDiv(10000 + slippage, 10000),
            sqrtPriceLimitX96: 0 // no price limit
        });

        result = ISwapRouter(router).exactOutputSingle(params);
    }

    function _settle_buy(uint256 _amountIn, uint256 _price, bool _isBuy) internal returns (uint256 out) {
        
        // Amount out formula
        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(chainLinkFeed);
        uint256 amountOut = _amountIn.mulDiv(10 ** priceDecimals, _price); // in btc output
        uint256 balance = assetB.balanceOf(address(this));
        if(amountOut > balance){    
            _swapExactOutputV3(amountOut, address(assetA), address(assetB), msg.sender, _amountIn);
            out = amountOut;
        }else{
            out = _swap(_amountIn, _price, _isBuy, 0);
        }   
    }

    function _settle_sell(uint256 _amountIn, uint256 _price, bool _isBuy) internal returns (uint256 out) {
        
        // Amount out formula
        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(chainLinkFeed);
        uint256 amountOut = _amountIn.mulDiv(_price, 10 ** priceDecimals); // in usdt assetA output
        uint256 balance = assetA.balanceOf(address(this));
        if(amountOut > balance){            
            _swapExactOutputV3(amountOut, address(assetB), address(assetA), msg.sender, _amountIn);
            out = amountOut;
        }else{
            out = _swap(_amountIn, _price, _isBuy, 0);
        }   
    }

    function _swap(
        uint256 _amountIn,
        uint256 _price,
        bool _isBuy,
        uint256 _fee 
    ) internal returns (uint256) {
        
        uint256 targetPrice = 0;
        uint256 price = DALiquidityLib.getPrice(chainLinkFeed);
        uint8 priceDecimals = DALiquidityLib.getPriceDecimals(chainLinkFeed);
        require(_price == price, "Price mismatch");

        // Choose tokens depending on buy/sell
        IERC20 assetIn  = _isBuy ? assetA : assetB;
        IERC20 assetOut = _isBuy ? assetB : assetA;

        // Transfer input tokens in
        assetIn.safeTransferFrom(msg.sender, address(this), _amountIn);

        // Amount out formula
        uint256 amountOut = _isBuy
            ? (_amountIn - _fee).mulDiv(10 ** priceDecimals, _price)
            : (_amountIn - _fee).mulDiv(_price, 10 ** priceDecimals);

        
        uint256 balance = assetOut.balanceOf(address(this));
        // console.log("_swap", amountOut, balance);
        if(amountOut > balance){ //fallback  
            uint256 actualAmountIn = _swapExactOutputV3(amountOut, address(assetIn), address(assetOut), msg.sender, _amountIn); 
            uint256 tradedPrice = amountOut.mulDiv(10 ** priceDecimals, actualAmountIn);
            targetPrice = _isBuy
            ? tradedPrice.mulDiv(1_000_000 - swapMargin, 1_000_000)
            : tradedPrice.mulDiv(1_000_000 + swapMargin, 1_000_000); 

        }else{
            // Transfer fee (if any) and output
            if (_fee > 0) assetIn.safeTransfer(treasury, _fee);    
            assetOut.safeTransfer(msg.sender, amountOut);  

            // Target price and order book update
            targetPrice = _isBuy
            ? _price.mulDiv(1_000_000 - swapMargin, 1_000_000)
            : _price.mulDiv(1_000_000 + swapMargin, 1_000_000); 
        }
        
        if (_isBuy) {
            (bool exists, uint256 index) = DALiquidityLib.find(toBuyPrices, targetPrice);
            amountToBuy[targetPrice] += _amountIn;
            if (!exists) DALiquidityLib.sortedInsert(toBuyPrices, index, targetPrice);
        } else {
            (bool exists, uint256 index) = DALiquidityLib.find(toSellPrices, targetPrice);
            amountToSell[targetPrice] += _amountIn;
            if (!exists) DALiquidityLib.sortedInsert(toSellPrices, index, targetPrice);
        }   
        
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
        require(msg.sender == s_forwarderAddress, "This address does not have permission to call performUpkeep");
        _;
    }
}
