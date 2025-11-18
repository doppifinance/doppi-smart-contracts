// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "../Interface/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// import "forge-std/console.sol";

/// One DoppiConfig for one pair ie. USDT/BTC
contract DoppiConfig is Ownable {

    AggregatorV3Interface public chainLinkFeed; 
    address public router;
    address public quoter;
    address public pancakeV3Pool;

    uint24 public poolFee; // 5bps for the USDT/BTC pool 
    uint24 public slippage; // slippage for pancakeswap DEX
    uint32 public tolerance; // opportunity or traderbot unwind price move tolerance performUpkeep 
    uint24 public liquidityFee; // doppiLP internal swap fee
    uint32 public swapMargin; // 0.5% doppiLP internal swap back targetPrice margin
    uint32 public ratioLP; // traderbot split ratio for doppiLP and doppi trader bot
    uint32 public DEFAULT_DAYS;
    address public treasury;
    address public doppiUpKeepManager;
    address public doppiOffer;
    address public doppiPoints;
    uint24 public MAX_ORDER;
    uint24 public treasury_fee; 
    uint256 public minimal_assetA;
    uint256 public minimal_assetB;
    uint32 public twapDuration;
    uint24 public maxDepositPercentage;
    uint32 public maxDelay;
    
    constructor() Ownable(msg.sender) {

        chainLinkFeed = AggregatorV3Interface(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
        router = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
        quoter = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
        pancakeV3Pool = 0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4;
        twapDuration = 3600;
        poolFee = 500; // 5bps for the USDT/BTC pool 
        slippage = 100; // slippage for pancakeswap DEX
        tolerance = 100; // opportunity or traderbot unwind price move tolerance performUpkeep 
        liquidityFee = 1000; // doppiLP internal swap fee
        swapMargin = 5000; // 0.5% doppiLP internal swap back targetPrice margin
        ratioLP = 5000; // traderbot split ratio for doppiLP and doppi trader bot
        DEFAULT_DAYS = 1;
        treasury;
        MAX_ORDER = 5;
        treasury_fee = 1000;
        minimal_assetA = 100 ether;
        minimal_assetB = 0.001 ether;
        maxDepositPercentage = 10000;
        maxDelay = 2 minutes;
    }

    function getAmountFee(uint256 _amount) external view returns (uint256 amountAfterFee, uint256 amountFee) {
        amountFee = _amount * treasury_fee / 10000;
        amountAfterFee = _amount - amountFee;
    }

    // Configuration functions
    function setMaxDelay(uint32 _maxDelay) external onlyOwner {
        maxDelay = _maxDelay;
    }

    function setMaxDepositPercentage(uint24 _maxDepositPercentage) external onlyOwner {
        maxDepositPercentage = _maxDepositPercentage;
    }

    function setDoppiPoints(address _doppiPoints) external onlyOwner {
        doppiPoints = _doppiPoints;
    }

    function setDoppiUpKeepManager(address _doppiUpKeepManager) external onlyOwner {
        doppiUpKeepManager = _doppiUpKeepManager;
    }

    function setDoppiOffer(address _doppiOffer) external onlyOwner {
        doppiOffer = _doppiOffer;
    }

    function setMinimal(uint256 _assetA, uint256 _assetB) external onlyOwner {
        minimal_assetA = _assetA;
        minimal_assetB = _assetB;
    }

    function setTreasuryFee(uint24 _treasury_fee) external onlyOwner {
        treasury_fee = _treasury_fee;
    }

    function setMaxOrder(uint24 _maxOrder) external onlyOwner {
        MAX_ORDER = _maxOrder;
    }

    function setPoolFee(uint24 _poolFee) external onlyOwner {
        poolFee = _poolFee;
    }

    function setSlippage(uint24 _slippage) external onlyOwner {
        slippage = _slippage;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setOracle(address _newOracle) external onlyOwner {
        chainLinkFeed = AggregatorV3Interface(_newOracle);
    }

    function setRouter(address _router) external onlyOwner {
        router = _router;
    }

    function setPancakeV3Pool(address _pool) external onlyOwner {
        pancakeV3Pool = _pool;
    }

    function setTwapDuration(uint24 _twapDuration) external onlyOwner {
        twapDuration = _twapDuration;
    }

    function setQuoter(address _quoter) external onlyOwner {
        quoter = _quoter;
    }

    // Configuration functions

    function setDefault_days(uint32 _days) external onlyOwner {
        DEFAULT_DAYS = _days;
    }
    
    function setTolerance(uint32 _tolerance) external onlyOwner {
        tolerance = _tolerance;
    }

    function setRatioLP(uint32 _ratioLP) external onlyOwner {
        ratioLP = _ratioLP;
    }
    
    function setLiquidityFee(uint24 _liquidityFee) external onlyOwner {
        liquidityFee = _liquidityFee;
    }

    function setSwapMargin(uint32 _swapMargin) external onlyOwner {
        swapMargin = _swapMargin;
    }

    
}
