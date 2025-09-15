// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiTrader} from "../Interface/IDoppiTrader.sol";
import {DoppiTraderFactory} from "./DoppiTraderFactory.sol";
import {DoppiConfig} from "./DoppiConfig.sol";
import {IImpliedVol} from "../Interface/IImpliedVol.sol";
import "forge-std/console.sol";

contract DoppiCore is Ownable, Pausable, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct DualAssetPosition {
        uint256 amount;
        uint256 price;
        uint256 strikePrice;
        uint32 expiryTimestamp; // Changed to uint32 to save storage
        uint32 apr;
        address owner;
        uint256 swappedAmount;
        bool isTraded;
        uint256 interest;
        uint256 hedgeAmountInHedgeToken;
        uint256 swappedHedgeAmount;
        uint256 hedgePrice;
    }

    struct DualAssetOffer {
        uint256 price;
        uint256 strikePrice;
        uint32 apr;
        uint256 delta;
        uint32 validUntilTimestamp; // Changed to uint32
    }

    struct KeyPosition {
        address owner;
        uint32 positionId; // Changed to uint32
    }

    struct DepositParams {
        uint256 amount;
        uint8 strikeZone;
        uint256 strikePrice;
        uint32 numDays;
        uint32 apr;
        uint32 validityTime; // Changed to uint32
    }

    IERC20 public immutable assetA; // Made immutable
    IERC20 public immutable assetB; // Made immutable
    IImpliedVol public immutable impliedVol; // Made immutable
    IDoppiLiquidity public immutable doppiLP; // Made immutable
    DoppiTraderFactory public doppiTraderFactory;
    DoppiConfig public immutable doppiConfig;
    
    mapping(address => bool) public admins;
    uint256 private constant SECONDS_PER_YEAR = 31536000;
    uint256 private constant SECONDS_PER_DAY = 86400;
    uint256 private constant BASIS_POINTS = 10000;
    
    // Packed storage for positions
    mapping(address => mapping(uint32 => DualAssetPosition)) public positions_buy; // Changed to uint32
    mapping(address => mapping(uint32 => DualAssetPosition)) public positions_sell; // Changed to uint32
    
    KeyPosition[] public buyPositionKeys;
    KeyPosition[] public sellPositionKeys;
    uint32 private nextPositionId = 1; // Changed to uint32
    address public s_forwarderAddress;
    
    event Deposited(address indexed trader, uint256 positionId, address asset, uint256 amount, uint256 interest, uint256 strikePrice, uint32 apr, uint32 numDays);
    event Settled(address indexed trader, uint256 positionId, bool striked, bool isProfit, uint256 profitLoss, uint256 payout, uint256 interest, address profitToken, address payoutToken, address interestToken);
    event HedgeSettled(address indexed trader, uint256 positionId, bool isProfit, uint256 profitLoss, address profitToken);

    constructor(address _assetA, address _assetB, IDoppiLiquidity _doppiLP, IImpliedVol _impliedVol)
        Ownable(msg.sender)
    {
        assetA = IERC20(_assetA);
        assetB = IERC20(_assetB);
        doppiLP = _doppiLP;
        doppiConfig = DoppiConfig(doppiLP.getDoppiConfig());
        impliedVol = _impliedVol;
        admins[msg.sender] = true;
        assetA.safeIncreaseAllowance(address(doppiLP), type(uint256).max);
        assetB.safeIncreaseAllowance(address(doppiLP), type(uint256).max);
    }

    // Single deposit functionality
    function deposit_buy(DepositParams calldata params) external whenNotPaused {
        DualAssetOffer memory buyOffer = getOffer(true, params.numDays, params.strikeZone);
        require(buyOffer.strikePrice == params.strikePrice, "incorrect strikePrice");
        require(buyOffer.apr == params.apr, "incorrect apr");
        require(buyOffer.apr > 0, "apr not available");
        require(params.validityTime >= block.timestamp, "offer expired");
        _depositBuy(params, buyOffer, true);
    }

    function deposit_sell(DepositParams calldata params) external whenNotPaused {
        DualAssetOffer memory sellOffer = getOffer(false, params.numDays, params.strikeZone);
        require(sellOffer.strikePrice == params.strikePrice, "incorrect strikePrice");
        require(sellOffer.apr == params.apr, "incorrect apr");
        require(sellOffer.apr > 0, "apr not available");
        require(params.validityTime >= block.timestamp, "offer expired");
        _depositSell(params, sellOffer, true);
    }

    function bulkHedge(uint256 _amountInHedgeAsset, uint256 _price, bool isBuy) external returns (uint256 swappedHedgeAmount, uint256 hedgePrice) {
        (swappedHedgeAmount, hedgePrice) = doppiLP.hedgeSwap(_amountInHedgeAsset, _price, isBuy);
    }

    function bulkDeposit(bool isBuy, DepositParams[] calldata params, DualAssetOffer[] memory _offers, bool _hedge) external onlyTraderBot whenNotPaused {
        uint256 length = params.length;
        require(length == _offers.length, "Array length mismatch");
        
        for (uint256 i = 0; i < length; ) {
            DepositParams calldata param = params[i];
            require(param.amount > 0, "Zero amount");
            require(param.apr > 0, "Zero APR");
            isBuy ? _depositBuy(param, _offers[i], _hedge) : _depositSell(param, _offers[i], _hedge);
            unchecked { ++i; }
        }
    }

    function settle_buys(uint256[] memory _indexes) external onlyOwner {
        _settle_positions(_indexes, true);
    }

    function settle_sells(uint256[] memory _indexes) external onlyOwner {
        _settle_positions(_indexes, false);
    }

    // Admin functions
    function opportunitySwap(address _owner, uint256 _amountPay, uint256 _price, uint256 _keyIndex, bool _isBuy)
        external
        onlyOpportunityBot
        returns (uint256 amountOut, uint256 profit)
    {
        uint256 price = doppiLP.getPrice();
        require(price == _price, "price mismatch");
        return _oppTrade(_owner, _amountPay, _price, _keyIndex, _isBuy, false);
    }

    function opportunityUnwind(address _owner, uint256 _amountPay, uint256 _price, uint256 _keyIndex, bool _isBuy)
        external
        onlyOpportunityBot
        returns (uint256 amountOut, uint256 profit)
    {
        uint256 price = doppiLP.getPrice();
        require(price == _price, "price mismatch");
        return _oppTrade(_owner, _amountPay, _price, _keyIndex, _isBuy, true);
    }

    // Chainlink Keepers integration
    function checkUpkeep(bytes calldata /*checkData*/ )
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256[] memory buys = getReadyBuyPositions();
        uint256[] memory sells = getReadySellPositions();
        bool buyReady = buys.length > 0;
        bool sellReady = sells.length > 0;

        if (buys.length == 0 && sells.length == 0 && paused()) {
            return (false, bytes(""));
        } else {
            return (buyReady || sellReady, abi.encode(buyReady, buys, sellReady, sells));
        }
    }

    function performUpkeep(bytes calldata performData) external onlyForwarder {
        
        if(paused()) return;
        
        (bool buyReady, uint256[] memory buyIndexes, bool sellReady, uint256[] memory sellIndexes) =
            abi.decode(performData, (bool, uint256[], bool, uint256[]));
        if (buyReady) {
            _settle_positions(buyIndexes, true);
        }
        if (sellReady) {
            _settle_positions(sellIndexes, false);
        }
    }

    // return buy or sell single offer
    function getOffer(bool _isBuy, uint32 _numDays, uint8 _strikeZone)
        public
        view
        returns (DualAssetOffer memory offer)
    {
        uint256 price = doppiLP.getPrice();
        uint256 strikePrice = _getStrikePrice(price, _strikeZone + 1, _isBuy);
        (uint32 apr, uint256 delta) = _isBuy
            ? impliedVol.getBuyAPR(SECONDS_PER_DAY * _numDays, price, strikePrice)
            : impliedVol.getSellAPR(SECONDS_PER_DAY * _numDays, price, strikePrice);
        offer = DualAssetOffer(price, strikePrice, apr, delta, uint32(block.timestamp + 60));
    }

    // Offer generation
    function getBuyOffers(uint32 _numDays) public view returns (DualAssetOffer[] memory buyoffers) {
        buyoffers = new DualAssetOffer[](5);

        for (uint8 i = 0; i < 5; ) {
            buyoffers[i] = getOffer(true, _numDays, i);
            unchecked { ++i; }
        }
        return buyoffers;
    }

    function getSellOffers(uint32 _numDays) public view returns (DualAssetOffer[] memory selloffers) {
        selloffers = new DualAssetOffer[](5);
        for (uint8 i = 0; i < 5; ) {
            selloffers[i] = getOffer(false, _numDays, i);
            unchecked { ++i; }
        }
        return selloffers;
    }

    function getAllOffers(uint32 _numDays)
        public
        view
        returns (DualAssetOffer[] memory buyoffers, DualAssetOffer[] memory selloffers)
    {
        buyoffers = new DualAssetOffer[](5);
        selloffers = new DualAssetOffer[](5);
        for (uint8 i = 0; i < 5; ) {
            buyoffers[i] = getOffer(true, _numDays, i);
            selloffers[i] = getOffer(false, _numDays, i);
            unchecked { ++i; }
        }
    }

    function get_buy_positions_id(address _owner) external view returns (KeyPosition[] memory) {
        uint256 count = 0;
        uint256 length = buyPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (buyPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        
        KeyPosition[] memory result = new KeyPosition[](count);
        count = 0;
        for (uint256 i = 0; i < length; ) {
            if (buyPositionKeys[i].owner == _owner) {
                result[count] = buyPositionKeys[i];
                count++;
            }
            unchecked { ++i; }
        }
        return result;
    }

    function get_sell_positions_id(address _owner) external view returns (KeyPosition[] memory) {
        uint256 count = 0;
        uint256 length = sellPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (sellPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        
        KeyPosition[] memory result = new KeyPosition[](count);
        count = 0;
        for (uint256 i = 0; i < length; ) {
            if (sellPositionKeys[i].owner == _owner) {
                result[count] = sellPositionKeys[i];
                count++;
            }
            unchecked { ++i; }
        }
        return result;
    }

    // View functions for positions
    function get_positions_buy(address _owner) external view returns (DualAssetPosition[] memory) {
        uint256 count = 0;
        uint256 length = buyPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (buyPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        
        DualAssetPosition[] memory result = new DualAssetPosition[](count);
        count = 0;
        for (uint256 i = 0; i < length; ) {
            if (buyPositionKeys[i].owner == _owner) {
                result[count] = positions_buy[buyPositionKeys[i].owner][buyPositionKeys[i].positionId];
                count++;
            }
            unchecked { ++i; }
        }
        return result;
    }

    function get_positions_sell(address _owner) external view returns (DualAssetPosition[] memory) {
        uint256 count = 0;
        uint256 length = sellPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (sellPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        
        DualAssetPosition[] memory result = new DualAssetPosition[](count);
        count = 0;
        for (uint256 i = 0; i < length; ) {
            if (sellPositionKeys[i].owner == _owner) {
                result[count] = positions_sell[sellPositionKeys[i].owner][sellPositionKeys[i].positionId];
                count++;
            }
            unchecked { ++i; }
        }
        return result;
    }

    function get_positions_buy() external view returns (DualAssetPosition[] memory) {
        uint256 length = buyPositionKeys.length;
        DualAssetPosition[] memory result = new DualAssetPosition[](length);
        for (uint256 i = 0; i < length; ) {
            result[i] = positions_buy[buyPositionKeys[i].owner][buyPositionKeys[i].positionId];
            unchecked { ++i; }
        }
        return result;
    }

    function get_positions_sell() external view returns (DualAssetPosition[] memory) {
        uint256 length = sellPositionKeys.length;
        DualAssetPosition[] memory result = new DualAssetPosition[](length);
        for (uint256 i = 0; i < length; ) {
            result[i] = positions_sell[sellPositionKeys[i].owner][sellPositionKeys[i].positionId];
            unchecked { ++i; }
        }
        return result;
    }

    function get_buy(address _owner, uint32 _positionId) external view returns (DualAssetPosition memory) {
        return positions_buy[_owner][_positionId];
    }

    function get_sell(address _owner, uint32 _positionId) external view returns (DualAssetPosition memory) {
        return positions_sell[_owner][_positionId];
    }

    function getBuyPositionCount(address _owner) external view returns (uint256) {
        uint256 count = 0;
        uint256 length = buyPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (buyPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        return count;
    }

    function getBuyPositionCount() external view returns (uint256) {
        return buyPositionKeys.length;
    }

    function getSellPositionCount(address _owner) external view returns (uint256) {
        uint256 count = 0;
        uint256 length = sellPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (sellPositionKeys[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        return count;
    }

    function getSellPositionCount() external view returns (uint256) {
        return sellPositionKeys.length;
    }

    function getReadyBuyPositions() public view returns (uint256[] memory) {
        uint256 count = 0;
        uint256 length = buyPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (positions_buy[buyPositionKeys[i].owner][buyPositionKeys[i].positionId].expiryTimestamp <= block.timestamp) {
                count++;
            }
            unchecked { ++i; }
        }
        
        uint256[] memory readyIndexes = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            if (positions_buy[buyPositionKeys[index].owner][buyPositionKeys[index].positionId].expiryTimestamp <= block.timestamp) {
                readyIndexes[idx] = index;
                idx++;
            }
            unchecked { --i; }
        }
        return readyIndexes;
    }

    function getReadySellPositions() public view returns (uint256[] memory) {
        uint256 count = 0;
        uint256 length = sellPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            if (positions_sell[sellPositionKeys[i].owner][sellPositionKeys[i].positionId].expiryTimestamp <= block.timestamp) {
                count++;
            }
            unchecked { ++i; }
        }
        
        uint256[] memory readyIndexes = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            if (positions_sell[sellPositionKeys[index].owner][sellPositionKeys[index].positionId].expiryTimestamp <= block.timestamp) {
                readyIndexes[idx] = index;
                idx++;
            }
            unchecked { --i; }
        }
        return readyIndexes;
    }

    // Configuration functions
    function setDoppiTraderFactory(DoppiTraderFactory _traderFactory) external onlyOwner {
        doppiTraderFactory = _traderFactory;
    }

    function setAdmin(address _admin, bool _status) external onlyOwner {
        admins[_admin] = _status;
    }

    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        s_forwarderAddress = forwarderAddress;
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnPause() external onlyOwner {
        _unpause();
    }

    // Internal functions
    function _depositBuy(DepositParams calldata params, DualAssetOffer memory _buyOffer, bool _hedge) internal {
        uint256 amount = params.amount;
        uint32 numDays = params.numDays;
        address sender = msg.sender;

        uint256 price = doppiLP.getPrice();
        assetA.safeTransferFrom(sender, address(this), amount);
        uint32 positionId = nextPositionId;
        unchecked { nextPositionId = positionId + 1; }

        // Hedge
        uint256 hedgeAmountInAssetB;
        uint256 swappedHedgeAmount; 
        uint256 hedgePrice;

        if(_hedge){
            (hedgeAmountInAssetB, swappedHedgeAmount, hedgePrice) = _hedgeSwap(amount, _buyOffer.delta, price, true);
        }
        // Calculate interest using precomputed values
        uint256 duration = SECONDS_PER_DAY * numDays;
        uint256 interest = (amount * _buyOffer.apr * duration) / (BASIS_POINTS * SECONDS_PER_YEAR);
        uint32 expiry = uint32(block.timestamp + duration);
        positions_buy[sender][positionId] = DualAssetPosition(
            amount,
            _buyOffer.price,
            _buyOffer.strikePrice,
            expiry,
            _buyOffer.apr,
            sender,
            0,
            false,
            interest,
            hedgeAmountInAssetB,
            swappedHedgeAmount,
            hedgePrice
        );

        buyPositionKeys.push(KeyPosition(sender, positionId));
        emit Deposited(sender, positionId, address(assetA), amount, interest, _buyOffer.strikePrice, _buyOffer.apr, numDays);

    }

    function _depositSell(DepositParams calldata params, DualAssetOffer memory _sellOffer, bool _hedge) internal {
        
        uint256 amount = params.amount;
        uint32 numDays = params.numDays;
        address sender = msg.sender;

        uint256 price = doppiLP.getPrice();
        assetB.safeTransferFrom(sender, address(this), params.amount);
        uint32 positionId = nextPositionId;
        unchecked { nextPositionId = positionId + 1; }
        
        // Hedge
        uint256 hedgeAmountInAssetA;
        uint256 swappedHedgeAmount; 
        uint256 hedgePrice;

        if(_hedge){
            (hedgeAmountInAssetA, swappedHedgeAmount, hedgePrice) = _hedgeSwap(amount, _sellOffer.delta, price, false);
        }
        // Calculate interest using precomputed values
        uint256 duration = SECONDS_PER_DAY * numDays;
        uint256 interest = (amount * _sellOffer.apr * duration) / (BASIS_POINTS * SECONDS_PER_YEAR);
        // Cache expiry
        uint32 expiry = uint32(block.timestamp + duration);
        positions_sell[sender][positionId] = DualAssetPosition(
            amount,
            _sellOffer.price,
            _sellOffer.strikePrice,
            expiry,
            _sellOffer.apr,
            sender,
            0,
            false,
            interest,
            hedgeAmountInAssetA,
            swappedHedgeAmount,
            hedgePrice
        );
        sellPositionKeys.push(KeyPosition(sender, positionId));
        emit Deposited(sender, positionId, address(assetB), amount, interest, _sellOffer.strikePrice, _sellOffer.apr, numDays);
    }

    function _settlePosition(
        KeyPosition memory position,
        bool isBuy
    ) internal {
        DualAssetPosition storage p = isBuy
            ? positions_buy[position.owner][position.positionId]
            : positions_sell[position.owner][position.positionId];

        require(p.expiryTimestamp <= block.timestamp, "not ready for settlement");

        // Cache external calls (less gas than calling multiple times)
        (uint256 price, uint8 priceDecimals) = (doppiLP.getPrice(), doppiLP.getPriceDecimals());

        // Track results for event emission (computed in each branch)
        address profitToken;
        address payoutToken;
        address interestToken;
        bool isProfit;
        uint256 profitLoss;
        uint256 payout;

        // Transfer interest upfront only if >0
        if (p.interest > 0) {
            IERC20 interestAsset = isBuy ? assetA : assetB;
            doppiLP.transfer(interestAsset, p.interest, address(this));
        }

        // Determine in-the-money condition
        bool isInTheMoney = isBuy ? (price <= p.strikePrice) : (price >= p.strikePrice);

        // In-the-money branch
        if (isInTheMoney) {
            unchecked {
                payout = isBuy
                    ? (p.amount * (10 ** priceDecimals)) / p.strikePrice
                    : (p.amount * p.strikePrice) / (10 ** priceDecimals);
            }

            (
                profitToken,
                payoutToken,
                interestToken,
                isProfit,
                profitLoss
            ) = p.isTraded
                ? _settleStrikeTraded(p, payout, isBuy)
                : _settleStrikeNoTraded(p, price, payout, isBuy);

            // Trader-bot unwind hook
            if (
                address(doppiTraderFactory) != address(0) &&
                doppiTraderFactory.isTraderBot(p.owner)
            ) {
                IDoppiTrader(p.owner).createUnwindPosition(
                    p.amount,
                    p.strikePrice,
                    isBuy
                );
            }
        }
        // Out-of-the-money branch
        else {

            (
                profitToken,
                payoutToken,
                interestToken,
                isProfit,
                profitLoss
            ) = p.isTraded
                ? _settleNoStrikeTraded(p, price, isBuy)
                : _settleNoStrikeNoTraded(p, isBuy);

            payout = 0; // explicit for clarity
        }

        emit Settled(
            p.owner,
            position.positionId,
            payout > 0, // in-the-money if payout > 0
            isProfit,
            profitLoss,
            payout,
            p.interest,
            profitToken,
            payoutToken,
            interestToken
        );

        // Hedge unwind settlement
        _settleHedgeSwap(p, price, isBuy, position.positionId);
    }

    function _removeSellPosition(uint256 index, KeyPosition memory _pos) internal {
        delete positions_sell[_pos.owner][_pos.positionId];
        uint256 lastIndex = sellPositionKeys.length - 1;
        if (index != lastIndex) {
            sellPositionKeys[index] = sellPositionKeys[lastIndex];
        }
        sellPositionKeys.pop();
    }

    function _removeBuyPosition(uint256 index, KeyPosition memory _pos) internal {
        delete positions_buy[_pos.owner][_pos.positionId];
        uint256 lastIndex = buyPositionKeys.length - 1;
        if (index != lastIndex) {
            buyPositionKeys[index] = buyPositionKeys[lastIndex];
        }
        buyPositionKeys.pop();
    }

    function _getStrikePrice(uint256 _price, uint8 _strikeZone, bool _isBuy) internal view returns (uint256) {
        uint8 priceDecimals = doppiLP.getPriceDecimals();
        uint256 priceGapWithDecimals = doppiConfig.PRICE_GAP_PEROFFER() * (10 ** priceDecimals);
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * _strikeZone) : _price + (priceGapWithDecimals * _strikeZone);
    }

    // Settlement helper functions
    function _settleStrikeNoTraded(
        DualAssetPosition memory p,
        uint256 _price,
        uint256 _payout,
        bool _isBuy
    ) internal returns (address payoutToken, address payoutTokenAgain, address interestToken, bool, uint256) {
        (IERC20 payoutToken_, IERC20 interestToken_) = _isBuy ? (assetB, assetA): (assetA, assetB);

        // Settlement
        uint256 amountOut = doppiLP.settle(p.amount, _price, _isBuy);
        if (amountOut > _payout) {
            unchecked {
                _safeTransferWithFee(payoutToken_, address(doppiLP), amountOut - _payout);
            }
        }
        payoutToken_.safeTransfer(p.owner, _payout);

        // Pay interest if any
        if (p.interest > 0) {
            _safeTransferWithFee(interestToken_, p.owner, p.interest);
        }
        return (address(payoutToken_), address(payoutToken_), address(interestToken_), false, 0);
    }


    function _settleStrikeTraded(
        DualAssetPosition memory p,
        uint256 _payout,
        bool _isBuy
    ) internal returns (address, address, address, bool isProfit, uint256 profitOrLoss) {
        (IERC20 profitToken, IERC20 payoutToken, IERC20 interestToken) = _isBuy
            ? (assetB, assetB, assetA)
            : (assetA, assetA, assetB);

        if (p.swappedAmount >= _payout) {
            unchecked {
                profitOrLoss = p.swappedAmount - _payout; // safe due to >= check
            }
            isProfit = true;
            _safeTransferWithFee(profitToken, address(doppiLP), profitOrLoss);
        } else {
            unchecked {
                profitOrLoss = _payout - p.swappedAmount; // safe due to < check
            }
            doppiLP.transfer(profitToken, profitOrLoss, address(this));
        }

        // Payout
        payoutToken.safeTransfer(p.owner, _payout);

        // Only transfer interest if > 0
        if (p.interest > 0) {
            _safeTransferWithFee(interestToken, p.owner, p.interest);
        }
        return (address(profitToken), address(payoutToken), address(interestToken), isProfit, profitOrLoss);
    }


    function _settleNoStrikeTraded(
        DualAssetPosition memory p,
        uint256 _price,
        bool _isBuy
    ) internal returns (address tokenUsed, address tokenSettled, address tokenPaid, bool isProfit, uint256 profitOrLoss) {
        // Pick settle/payout tokens based on trade direction
        IERC20 payoutToken = _isBuy ? assetA : assetB;

        // Perform settlement
        uint256 amountOut = doppiLP.settle(p.swappedAmount, _price, !_isBuy);

        // Profit/loss calculation
        if (amountOut >= p.amount) {
            unchecked {
                profitOrLoss = amountOut - p.amount; // save gas with unchecked math
            }
            isProfit = true;
            _safeTransferWithFee(payoutToken, address(doppiLP), profitOrLoss);
        } else {
            unchecked {
                profitOrLoss = p.amount - amountOut;
            }
            doppiLP.transfer(payoutToken, profitOrLoss, address(this));
        }

        // Transfer principal + interest
        payoutToken.safeTransfer(p.owner, p.amount);
        if (p.interest > 0) { // skip zero-fee transfer
            _safeTransferWithFee(payoutToken, p.owner, p.interest);
        }

        return (
            address(payoutToken), 
            address(payoutToken), 
            address(payoutToken), 
            isProfit, 
            profitOrLoss
        );
    }


    function _settleNoStrikeNoTraded(
        DualAssetPosition memory p,
        bool _isBuy
    ) internal returns (address, address, address, bool, uint256) {
        IERC20 payoutToken = _isBuy ? assetA : assetB;

        // Transfer principal
        payoutToken.safeTransfer(p.owner, p.amount);

        // Only transfer interest if > 0
        if (p.interest > 0) {
            _safeTransferWithFee(payoutToken, p.owner, p.interest);
        }
        return (address(payoutToken), address(payoutToken), address(payoutToken), false, 0);
    }


    function _settleHedgeSwap(DualAssetPosition memory p, uint256 price, bool isBuy, uint256 _positionId) internal {
        
        if (p.swappedHedgeAmount == 0) return;
        
        (uint256 hedgeOut, ) = doppiLP.hedgeSwap(p.swappedHedgeAmount, price, isBuy);
        bool isProfit = hedgeOut > p.hedgeAmountInHedgeToken;
        uint256 profitOrLoss = isProfit ? hedgeOut - p.hedgeAmountInHedgeToken : p.hedgeAmountInHedgeToken - hedgeOut;
        
        address profitOrLossToken = isBuy ? address(assetB) : address(assetA);
        
        emit HedgeSettled(p.owner, _positionId, isProfit, profitOrLoss, profitOrLossToken);
    }

    function _hedgeSwap(uint256 _amount, uint256 _delta, uint256 _price, bool isBuy) internal returns (uint256 amountInHedgeAsset, uint256 swappedHedgeAmount, uint256 hedgePrice) {
        uint256 priceDecimals = doppiLP.getPriceDecimals();
        uint256 hedgeAmount = _amount * _delta / BASIS_POINTS;
        amountInHedgeAsset = isBuy ? hedgeAmount * (10 ** priceDecimals) / _price : hedgeAmount * _price / (10 ** priceDecimals);
        (swappedHedgeAmount, hedgePrice) = doppiLP.hedgeSwap(amountInHedgeAsset, _price, !isBuy);
    }

    function _oppTrade(
        address _owner,
        uint256 _amountPay,
        uint256 _price,
        uint256 _keyIndex,
        bool _isBuy,
        bool _isUnwind
    ) private returns (uint256 amountOut, uint256 profit) {
        DualAssetPosition storage p;

        if (_isBuy) {
            p = _isUnwind
                ? positions_sell[_owner][sellPositionKeys[_keyIndex].positionId]
                : positions_buy[_owner][buyPositionKeys[_keyIndex].positionId];
            require(p.amount > 0, "position not found");

            amountOut = doppiLP.swap(_amountPay, _price, _isBuy);

            if (_isUnwind) {
                p.isTraded = false;
                p.swappedAmount = 0;
                profit = amountOut - p.amount;
                _safeTransferWithFee(assetB, address(doppiLP), profit);
            } else {
                p.isTraded = true;
                p.swappedAmount = amountOut;
            }
        } else {
            p = _isUnwind
                ? positions_buy[_owner][buyPositionKeys[_keyIndex].positionId]
                : positions_sell[_owner][sellPositionKeys[_keyIndex].positionId];
            require(p.amount > 0, "position not found");

            amountOut = doppiLP.swap(_amountPay, _price, _isBuy);
            if (_isUnwind) {
                p.isTraded = false;
                p.swappedAmount = 0;
                profit = amountOut - p.amount;
                _safeTransferWithFee(assetA, address(doppiLP), profit);
            } else {
                p.isTraded = true;
                p.swappedAmount = amountOut;
            }
        }
    }

    function _settle_positions(uint256[] memory _indexes, bool isBuy) internal {
        uint256 length = _indexes.length;
        require(length > 0, "empty array");
        require(_isDescending(_indexes), "not descending");
        
        for (uint256 i = 0; i < length; ) {
            uint256 idx = _indexes[i];
            KeyPosition[] storage positionKeys = isBuy ? buyPositionKeys : sellPositionKeys;
            require(idx < positionKeys.length, "index out of bounds");
            
            KeyPosition memory pos = positionKeys[idx];
            _settlePosition(pos, isBuy);
            isBuy ? _removeBuyPosition(idx, pos) : _removeSellPosition(idx, pos);
            
            unchecked { ++i; }
        }
    }

    function _safeTransferWithFee(IERC20 _asset, address _to, uint256 _amount) internal {
        
        (uint256 amountAfterFee, uint256 amountFee) = doppiConfig.getAmountFee(_amount);
        _asset.safeTransfer(_to, amountAfterFee);
        _asset.safeTransfer(doppiConfig.treasury(), amountFee);

    }


    function _isDescending(uint256[] memory arr) internal pure returns (bool) {
        if (arr.length < 2) return true;
        for (uint256 i = 1; i < arr.length; ) {
            if (arr[i - 1] < arr[i]) {
                return false;
            }
            unchecked { ++i; }
        }
        return true;
    }

    modifier onlyOpportunityBot() {
        require(admins[msg.sender], "only admin");
        _;
    }

    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "invalid forwarder");
        _;
    }

    modifier onlyTraderBot() {
        require(doppiTraderFactory.isTraderBot(msg.sender), "only trader bot");
        _;
    }
}