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

    struct DualStats {
        uint256 interestPaid_assetA;
        uint256 interestPaid_assetB;
        uint256 settleProfit_assetA;
        uint256 settleProfit_assetB;
        uint256 opportunityProfit_assetA;
        uint256 opportunityProfit_assetB;
        uint256 opportunityLoss_assetA;
        uint256 opportunityLoss_assetB;
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
    
    // Packed hedge stats into a single struct to save storage slots
    struct HedgeStats {
        uint128 settleHedgeProfitAssetA;
        uint128 settleHedgeProfitAssetB;
        uint128 settleHedgeLossAssetA;
        uint128 settleHedgeLossAssetB;
    }
    
    HedgeStats public hedgeStats;
    
    // User statistics
    mapping(address => DualStats) public dualStats;

    event Deposited(address indexed user, uint256 amountA, uint256 amountB);
    event Settled(address indexed user, uint256 payoutA, uint256 payoutB);
    event BulkDeposited(address indexed user, uint256 totalAmount, bool isBuy);
    event BulkSettled(uint256 settledCount, bool isBuy);

    constructor(address _assetA, address _assetB, IDoppiLiquidity _doppiLP, IImpliedVol _impliedVol)
        Ownable(msg.sender)
    {
        assetA = IERC20(_assetA);
        assetB = IERC20(_assetB);
        doppiLP = _doppiLP;
        impliedVol = _impliedVol;
        admins[msg.sender] = true;
    }

    // Single deposit functionality
    function deposit_buy(DepositParams calldata params) external whenNotPaused {
        DualAssetOffer memory buyOffer = getOffer(true, params.numDays, params.strikeZone);
        require(buyOffer.strikePrice == params.strikePrice, "incorrect strikePrice");
        require(buyOffer.apr == params.apr, "incorrect apr");
        require(buyOffer.apr > 0, "apr not available");
        require(params.validityTime >= block.timestamp, "offer expired");
        _depositBuy(params, buyOffer);
    }

    function deposit_sell(DepositParams calldata params) external whenNotPaused {
        DualAssetOffer memory sellOffer = getOffer(false, params.numDays, params.strikeZone);
        require(sellOffer.strikePrice == params.strikePrice, "incorrect strikePrice");
        require(sellOffer.apr == params.apr, "incorrect apr");
        require(sellOffer.apr > 0, "apr not available");
        require(params.validityTime >= block.timestamp, "offer expired");
        _depositSell(params, sellOffer);
    }

    function bulkDepositBuys(DepositParams[] calldata params, DualAssetOffer[] memory _buyOffers) external onlyTraderBot whenNotPaused {
        uint256 length = params.length;
        for (uint256 i = 0; i < length; ) {
            require(params[i].amount > 0, "amount less than 0");
            require(params[i].apr > 0, "apr not available");
            DualAssetOffer memory buyOffer = _buyOffers[params[i].strikeZone];
            _depositBuy(params[i], buyOffer);
            unchecked { ++i; }
        }
    }

    function bulkDepositSells(DepositParams[] calldata params, DualAssetOffer[] memory _sellOffers) external onlyTraderBot whenNotPaused {
        uint256 length = params.length;
        for (uint256 i = 0; i < length; ) {
            require(params[i].amount > 0, "amount less than 0");
            require(params[i].apr > 0, "apr not available");
            DualAssetOffer memory sellOffer = _sellOffers[params[i].strikeZone];
            _depositSell(params[i], sellOffer);
            unchecked { ++i; }
        }
    }

    function settle_buys(uint256[] memory _indexes) external onlyOwner {
        _settle_buys(_indexes);
    }

    function settle_sells(uint256[] memory _indexes) external onlyOwner {
        _settle_sells(_indexes);
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
            _settle_buys(buyIndexes);
        }
        if (sellReady) {
            _settle_sells(sellIndexes);
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

    function get_stats(address _owner) external view returns (DualStats memory) {
        return dualStats[_owner];
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
    function _settle_buys(uint256[] memory _indexes) internal {
        uint256 length = _indexes.length;
        require(length > 0, "empty array");
        require(_isDescending(_indexes), "not descending");
        
        for (uint256 i = 0; i < length; ) {
            uint256 idx = _indexes[i];
            require(idx < buyPositionKeys.length, "index out of bounds");
            KeyPosition memory pos = buyPositionKeys[idx];
            _settlePosition(pos, true);
            _removeBuyPosition(idx, pos);
            unchecked { ++i; }
        }
    }

    function _settle_sells(uint256[] memory _indexes) internal {
        uint256 length = _indexes.length;
        require(length > 0, "empty array");
        require(_isDescending(_indexes), "not descending");

        for (uint256 i = 0; i < length; ) {
            uint256 idx = _indexes[i];
            require(idx < sellPositionKeys.length, "index out of bounds");
            KeyPosition memory pos = sellPositionKeys[idx];
            _settlePosition(pos, false);
            _removeSellPosition(idx, pos);
            unchecked { ++i; }
        }
    }

    function _depositBuy(DepositParams calldata params, DualAssetOffer memory _buyOffer) internal {
        uint256 price = doppiLP.getPrice();
        assetA.safeTransferFrom(msg.sender, address(this), params.amount);
        uint32 positionId = nextPositionId++;

        // Hedge
        (uint256 hedgeAmountInAssetB, uint256 swappedHedgeAmount, uint256 hedgePrice) = 
            _hedgeSwap(params.amount, _buyOffer.delta, price, true);

        // Calculate interest using precomputed values
        uint256 interest = params.amount * _buyOffer.apr / (BASIS_POINTS * (SECONDS_PER_YEAR / (SECONDS_PER_DAY * params.numDays)));
        positions_buy[msg.sender][positionId] = DualAssetPosition(
            params.amount,
            _buyOffer.price,
            _buyOffer.strikePrice,
            uint32(block.timestamp + (SECONDS_PER_DAY * params.numDays)),
            _buyOffer.apr,
            msg.sender,
            0,
            false,
            interest,
            hedgeAmountInAssetB,
            swappedHedgeAmount,
            hedgePrice
        );

        buyPositionKeys.push(KeyPosition(msg.sender, positionId));
    }

    function _depositSell(DepositParams calldata params, DualAssetOffer memory _sellOffer) internal {
        uint256 price = doppiLP.getPrice();
        assetB.safeTransferFrom(msg.sender, address(this), params.amount);
        uint32 positionId = nextPositionId++;

        // Hedge
        (uint256 hedgeAmountInAssetA, uint256 swappedHedgeAmount, uint256 hedgePrice) = 
            _hedgeSwap(params.amount, _sellOffer.delta, price, false);

        // Calculate interest using precomputed values
        uint256 interest = params.amount * _sellOffer.apr / (BASIS_POINTS * (SECONDS_PER_YEAR / (SECONDS_PER_DAY * params.numDays)));

        positions_sell[msg.sender][positionId] = DualAssetPosition(
            params.amount,
            _sellOffer.price,
            _sellOffer.strikePrice,
            uint32(block.timestamp + (SECONDS_PER_DAY * params.numDays)),
            _sellOffer.apr,
            msg.sender,
            0,
            false,
            interest,
            hedgeAmountInAssetA,
            swappedHedgeAmount,
            hedgePrice
        );
        sellPositionKeys.push(KeyPosition(msg.sender, positionId));

        emit Deposited(msg.sender, 0, params.amount);
    }

    function _settlePosition(KeyPosition memory position, bool isBuy) internal {
        DualAssetPosition storage p = isBuy 
            ? positions_buy[position.owner][position.positionId] 
            : positions_sell[position.owner][position.positionId];
        
        require(p.expiryTimestamp <= block.timestamp, "not ready for settlement");
        
        uint256 price = doppiLP.getPrice();
        uint8 priceDecimals = doppiLP.getPriceDecimals();
        
        // Determine assets and conditions
        IERC20 interestAsset = isBuy ? assetA : assetB;
        bool isInTheMoney = isBuy ? (price <= p.strikePrice) : (price >= p.strikePrice);

        // Transfer interest
        doppiLP.transfer(interestAsset, p.interest, address(this));

        if (isInTheMoney) {
            // Calculate payout
            uint256 payout = isBuy 
                ? p.amount * (10 ** priceDecimals) / p.strikePrice
                : p.amount * p.strikePrice / (10 ** priceDecimals);
            
            p.isTraded 
                ? _settleStrikeTraded(p, payout, isBuy) 
                : _settleStrikeNoTraded(p, price, payout, isBuy);
            
            // Create unwind position for trader bots
            if (address(doppiTraderFactory) != address(0) && doppiTraderFactory.isTraderBot(p.owner)) {
                IDoppiTrader(p.owner).createUnwindPosition(p.amount, p.strikePrice, isBuy);
            }
        } else {
            p.isTraded 
                ? _settleNoStrikeTraded(p, price, isBuy) 
                : _settleNoStrikeNoTraded(p, isBuy);
        }

        _settleHedgeSwap(p, price, isBuy);
        emit Settled(p.owner, isBuy ? 0 : p.amount, isBuy ? p.amount : 0);
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
        uint256 priceGapWithDecimals = DoppiConfig(doppiLP.getDoppiConfig()).PRICE_GAP_PEROFFER() * (10 ** priceDecimals);
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * _strikeZone) : _price + (priceGapWithDecimals * _strikeZone);
    }

    // Settlement helper functions
    function _settleStrikeNoTraded(DualAssetPosition memory p, uint256 _price, uint256 _payout, bool _isBuy) internal {
        (IERC20 inToken, IERC20 payoutToken, IERC20 interestToken) = _isBuy 
            ? (assetA, assetB, assetA) 
            : (assetB, assetA, assetB);

        inToken.safeIncreaseAllowance(address(doppiLP), p.amount);
        uint256 amountOut = doppiLP.settle(p.amount, _price, _isBuy);
        
        uint256 profit = amountOut > _payout ? amountOut - _payout : 0;
        
        if (_isBuy) {
            dualStats[p.owner].settleProfit_assetB += profit;
            dualStats[p.owner].interestPaid_assetA += p.interest;
        } else {
            dualStats[p.owner].settleProfit_assetA += profit;
            dualStats[p.owner].interestPaid_assetB += p.interest;
        }

        if (profit > 0) {
            payoutToken.safeTransfer(address(doppiLP), profit);
        }
        payoutToken.safeTransfer(p.owner, _payout);
        interestToken.safeTransfer(p.owner, p.interest);
    }

    function _settleStrikeTraded(DualAssetPosition memory p, uint256 _payout, bool _isBuy) internal {
        (IERC20 profitToken, IERC20 payoutToken, IERC20 interestToken) = _isBuy 
            ? (assetB, assetB, assetA) 
            : (assetA, assetA, assetB);

        if (_isBuy) {
            dualStats[p.owner].interestPaid_assetA += p.interest;
        } else {
            dualStats[p.owner].interestPaid_assetB += p.interest;
        }

        uint256 profitOrLoss;
        bool isProfit = p.swappedAmount >= _payout;
        
        if (isProfit) {
            profitOrLoss = p.swappedAmount - _payout;
            if (_isBuy) {
                dualStats[p.owner].opportunityProfit_assetB += profitOrLoss;
            } else {
                dualStats[p.owner].opportunityProfit_assetA += profitOrLoss;
            }
            profitToken.safeTransfer(address(doppiLP), profitOrLoss);
        } else {
            profitOrLoss = _payout - p.swappedAmount;
            if (_isBuy) {
                dualStats[p.owner].opportunityLoss_assetB += profitOrLoss;
            } else {
                dualStats[p.owner].opportunityLoss_assetA += profitOrLoss;
            }
            doppiLP.transfer(profitToken, profitOrLoss, address(this));
        }

        payoutToken.safeTransfer(p.owner, _payout);
        interestToken.safeTransfer(p.owner, p.interest);
    }

    function _settleNoStrikeTraded(DualAssetPosition memory p, uint256 _price, bool _isBuy) internal {
        (IERC20 settleToken, IERC20 profitLossToken) = _isBuy 
            ? (assetB, assetA) 
            : (assetA, assetB);

        settleToken.safeIncreaseAllowance(address(doppiLP), p.swappedAmount);
        uint256 amountOut = doppiLP.settle(p.swappedAmount, _price, !_isBuy);
        
        if (_isBuy) {
            dualStats[p.owner].interestPaid_assetA += p.interest;
        } else {
            dualStats[p.owner].interestPaid_assetB += p.interest;
        }

        uint256 profitOrLoss;
        bool isProfit = amountOut >= p.amount;
        
        if (isProfit) {
            profitOrLoss = amountOut - p.amount;
            if (_isBuy) {
                dualStats[p.owner].opportunityProfit_assetA += profitOrLoss;
            } else {
                dualStats[p.owner].opportunityProfit_assetB += profitOrLoss;
            }
            profitLossToken.safeTransfer(address(doppiLP), profitOrLoss);
        } else {
            profitOrLoss = p.amount - amountOut;
            if (_isBuy) {
                dualStats[p.owner].opportunityLoss_assetA += profitOrLoss;
            } else {
                dualStats[p.owner].opportunityLoss_assetB += profitOrLoss;
            }
            doppiLP.transfer(profitLossToken, profitOrLoss, address(this));
        }

        profitLossToken.safeTransfer(p.owner, p.amount + p.interest);
    }

    function _settleNoStrikeNoTraded(DualAssetPosition memory p, bool _isBuy) internal {
        IERC20 token = _isBuy ? assetA : assetB;
        
        if (_isBuy) {
            dualStats[p.owner].interestPaid_assetA += p.interest;
        } else {
            dualStats[p.owner].interestPaid_assetB += p.interest;
        }
        
        token.safeTransfer(p.owner, p.amount + p.interest);
    }

    function _settleHedgeSwap(DualAssetPosition memory p, uint256 price, bool isBuy) internal {
        if(p.swappedHedgeAmount == 0) return;

        (uint256 hedgeOut, ) = doppiLP.hedgeSwap(p.swappedHedgeAmount, price, isBuy);
        if (hedgeOut > p.hedgeAmountInHedgeToken) {
            uint256 profit = hedgeOut - p.hedgeAmountInHedgeToken;
            if(isBuy){
                hedgeStats.settleHedgeProfitAssetB += uint128(profit);
            }else{
                hedgeStats.settleHedgeProfitAssetA += uint128(profit);
            } 
        }else{
            uint256 loss = p.hedgeAmountInHedgeToken - hedgeOut;
            if(isBuy){
                hedgeStats.settleHedgeLossAssetB += uint128(loss);
            }else{
                hedgeStats.settleHedgeLossAssetA += uint128(loss);
            } 
        } 
    }

    function _hedgeSwap(uint256 _amount, uint256 _delta, uint256 _price, bool isBuy) internal returns (uint256 amountInHedgeAsset, uint256 swappedHedgeAmount, uint256 hedgePrice) {
        uint256 priceDecimals = doppiLP.getPriceDecimals();
        uint256 hedgeAmount = _amount * _delta / BASIS_POINTS;
        amountInHedgeAsset = hedgeAmount * (10 ** priceDecimals) / _price;
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

            assetA.safeIncreaseAllowance(address(doppiLP), _amountPay);
            amountOut = doppiLP.swap(_amountPay, _price, _isBuy);

            if (_isUnwind) {
                p.isTraded = false;
                p.swappedAmount = 0;
                profit = amountOut - p.amount;
                assetB.safeTransfer(address(doppiLP), profit);
            } else {
                p.isTraded = true;
                p.swappedAmount = amountOut;
            }
        } else {
            p = _isUnwind
                ? positions_buy[_owner][buyPositionKeys[_keyIndex].positionId]
                : positions_sell[_owner][sellPositionKeys[_keyIndex].positionId];
            require(p.amount > 0, "position not found");

            assetB.safeIncreaseAllowance(address(doppiLP), _amountPay);
            amountOut = doppiLP.swap(_amountPay, _price, _isBuy);
            if (_isUnwind) {
                p.isTraded = false;
                p.swappedAmount = 0;
                profit = amountOut - p.amount;
                assetA.safeTransfer(address(doppiLP), profit);
            } else {
                p.isTraded = true;
                p.swappedAmount = amountOut;
            }
        }
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