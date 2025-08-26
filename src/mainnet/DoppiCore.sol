// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiTrader} from "../Interface/IDoppiTrader.sol";
import {DoppiTraderFactory} from "./DoppiTraderFactory.sol";
import {IImpliedVol} from "../Interface/IImpliedVol.sol";
import "forge-std/console.sol";

contract DoppiCore is Ownable, AutomationCompatibleInterface {
    struct DualAssetPosition {
        uint256 amount;
        uint256 price;
        uint256 strikePrice;
        uint256 expiryTimestamp;
        uint32 apr;
        address owner;
        uint256 swappedAmount;
        bool isTraded;
        uint256 interest;
        uint256 hedgeAmount; // Amount used for hedging
        uint256 swappedHedgeAmount;
        uint256 hedgePrice;
    }

    struct DualAssetOffer {
        uint256 price;
        uint256 strikePrice;
        uint32 apr;
        uint256 delta;
        uint256 validUntilTimestamp;
    }

    struct KeyPosition {
        address owner;
        uint256 positionId;
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
        uint256 validityTime;
    }

    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 public assetA;
    IERC20 public assetB;
    IImpliedVol public impliedVol;
    IDoppiLiquidity public doppiLP;
    DoppiTraderFactory public traderFactory;
    mapping(address => bool) public admins;

    uint256 private constant SECONDS_PER_YEAR = 31536000;
    uint256 public PRICE_GAP_PEROFFER = 500;

    mapping(address => mapping(uint256 => DualAssetPosition)) public positions_buy;
    mapping(address => mapping(uint256 => DualAssetPosition)) public positions_sell;
    KeyPosition[] public buyPositionKeys;
    KeyPosition[] public sellPositionKeys;
    uint256 private nextPositionId = 1;

    uint256 public settleHedgeProfitAssetA;
    uint256 public settleHedgeProfitAssetB;
    uint256 public settleHedgeLossAssetA;
    uint256 public settleHedgeLossAssetB;

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

    // Single deposit functionality (enhanced from both contracts)
    function deposit_buy(DepositParams calldata params) external {
        DualAssetOffer memory buyOffer = getOffer(true, params.numDays, params.strikeZone);
        require(buyOffer.strikePrice == params.strikePrice, "incorrect strikePrice");
        require(buyOffer.apr == params.apr, "incorrect apr");
        require(params.validityTime >= block.timestamp, "offer expired");
        _depositBuy(params, buyOffer);
    }

    function deposit_sell(DepositParams calldata params) external {
        DualAssetOffer memory sellOffer = getOffer(false, params.numDays, params.strikeZone);
        require(sellOffer.strikePrice == params.strikePrice, "incorrect strikePrice");
        require(sellOffer.apr == params.apr, "incorrect apr");
        require(params.validityTime >= block.timestamp, "offer expired");
        _depositSell(params, sellOffer);
    }

    // check not required to save gas as it is called internally from trader bot
    function bulkDepositBuys(DepositParams[] calldata params, DualAssetOffer[] memory _buyOffers) external {
        for (uint256 i = 0; i < params.length; i++) {
            DualAssetOffer memory buyOffer = _buyOffers[params[i].strikeZone];
            _depositBuy(params[i], buyOffer);
        }
    }

    // check not required to save gas as it is called internally from trader bot
    function bulkDepositSells(DepositParams[] calldata params, DualAssetOffer[] memory _sellOffers) external {
        for (uint256 i = 0; i < params.length; i++) {
            DualAssetOffer memory sellOffer = _sellOffers[params[i].strikeZone];
            _depositSell(params[i], sellOffer);
        }
    }

    function settle_buys(uint256[] memory _indexes) public {
        require(_indexes.length > 0, "empty array");
        require(_isDescending(_indexes), "not descending");
        for (uint256 i = 0; i < _indexes.length; i++) {
            uint256 idx = _indexes[i];
            require(idx < buyPositionKeys.length, "index out of bounds");
            KeyPosition memory pos = buyPositionKeys[idx];
            _settleBuyPosition(pos);
            _removeBuyPosition(idx, pos);
        }
    }

    function settle_sells(uint256[] memory _indexes) public {
        require(_indexes.length > 0, "empty array");
        require(_isDescending(_indexes), "not descending");

        for (uint256 i = 0; i < _indexes.length; i++) {
            uint256 idx = _indexes[i];
            require(idx < sellPositionKeys.length, "index out of bounds");
            KeyPosition memory pos = sellPositionKeys[idx];
            _settleSellPosition(pos);
            _removeSellPosition(idx, pos);
        }
    }

    // Admin functions
    function adminSwap(address _owner, uint256 _amountPay, uint256 _price, uint256 _keyIndex, bool _isBuy)
        external
        onlyAdmin
        returns (uint256 amountOut, uint256 profit) {

        uint256 price = doppiLP.getPrice();
        require(price == _price, "price mismatch");
        return _adminTrade(_owner, _amountPay, _price, _keyIndex, _isBuy, false);
    }

    function adminUnwind(address _owner, uint256 _amountPay, uint256 _price, uint256 _keyIndex, bool _isBuy)
        external
        onlyAdmin
        returns (uint256 amountOut, uint256 profit) {
        
        uint256 price = doppiLP.getPrice();
        require(price == _price, "price mismatch");
        return _adminTrade(_owner, _amountPay, _price, _keyIndex, _isBuy, true);
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

        return (buyReady || sellReady, abi.encode(buyReady, buys, sellReady, sells));
    }

    function performUpkeep(bytes calldata performData) external {
        (bool buyReady, uint256[] memory buyIndexes, bool sellReady, uint256[] memory sellIndexes) =
            abi.decode(performData, (bool, uint256[], bool, uint256[]));
        if (buyReady) {
            settle_buys(buyIndexes);
        }
        if (sellReady) {
            settle_sells(sellIndexes);
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
            ? impliedVol.getBuyAPR(86400 * _numDays, price, strikePrice)
            : impliedVol.getSellAPR(86400 * _numDays, price, strikePrice);
        offer = DualAssetOffer(price, strikePrice, apr, delta, block.timestamp + 60);
    }

    // Offer generation (from DualAssetNew)
    function getBuyOffers(uint32 _numDays) public view returns (DualAssetOffer[] memory buyoffers) {
        buyoffers = new DualAssetOffer[](5);

        for (uint8 i = 0; i < 5; i++) {
            buyoffers[i] = getOffer(true, _numDays, i);
        }
        return buyoffers;
    }

    function getSellOffers(uint32 _numDays) public view returns (DualAssetOffer[] memory selloffers) {
        selloffers = new DualAssetOffer[](5);
        for (uint8 i = 0; i < 5; i++) {
            selloffers[i] = getOffer(false, _numDays, i);
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
        for (uint8 i = 0; i < 5; i++) {
            buyoffers[i] = getOffer(true, _numDays, i);
            selloffers[i] = getOffer(false, _numDays, i);
        }
    }

    function get_buy_positions_id(address _owner) external view returns (KeyPosition[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < buyPositionKeys.length; i++) {
            if (buyPositionKeys[i].owner == _owner) {
                count++;
            }
        }
        KeyPosition[] memory result = new KeyPosition[](count);
        count = 0;
        for (uint256 i = 0; i < buyPositionKeys.length; i++) {
            if (buyPositionKeys[i].owner == _owner) {
                result[count] = buyPositionKeys[i];
                count++;
            }
        }
        return result;
    }

    function get_sell_positions_id(address _owner) external view returns (KeyPosition[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < sellPositionKeys.length; i++) {
            if (sellPositionKeys[i].owner == _owner) {
                count++;
            }
        }
        KeyPosition[] memory result = new KeyPosition[](count);
        count = 0;
        for (uint256 i = 0; i < sellPositionKeys.length; i++) {
            if (sellPositionKeys[i].owner == _owner) {
                result[count] = sellPositionKeys[i];
                count++;
            }
        }
        return result;
    }

    function get_stats(address _owner) external view returns (DualStats memory) {
        return dualStats[_owner];
    }

    // View functions for positions
    function get_positions_buy(address _owner) external view returns (DualAssetPosition[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < buyPositionKeys.length; i++) {
            if (buyPositionKeys[i].owner == _owner) {
                count++;
            }
        }
        DualAssetPosition[] memory result = new DualAssetPosition[](count);
        count = 0;
        for (uint256 i = 0; i < buyPositionKeys.length; i++) {
            if (buyPositionKeys[i].owner == _owner) {
                result[count] = positions_buy[buyPositionKeys[i].owner][buyPositionKeys[i].positionId];
                count++;
            }
        }
        return result;
    }

    function get_positions_sell(address _owner) external view returns (DualAssetPosition[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < sellPositionKeys.length; i++) {
            if (sellPositionKeys[i].owner == _owner) {
                count++;
            }
        }
        DualAssetPosition[] memory result = new DualAssetPosition[](count);
        count = 0;
        for (uint256 i = 0; i < sellPositionKeys.length; i++) {
            if (sellPositionKeys[i].owner == _owner) {
                result[count] = positions_sell[sellPositionKeys[i].owner][sellPositionKeys[i].positionId];
                count++;
            }
        }
        return result;
    }

    function get_positions_buy() external view returns (DualAssetPosition[] memory) {
        DualAssetPosition[] memory result = new DualAssetPosition[](buyPositionKeys.length);
        for (uint256 i = 0; i < buyPositionKeys.length; i++) {
            result[i] = positions_buy[buyPositionKeys[i].owner][buyPositionKeys[i].positionId];
        }
        return result;
    }

    function get_positions_sell() external view returns (DualAssetPosition[] memory) {
        DualAssetPosition[] memory result = new DualAssetPosition[](sellPositionKeys.length);
        for (uint256 i = 0; i < sellPositionKeys.length; i++) {
            result[i] = positions_sell[sellPositionKeys[i].owner][sellPositionKeys[i].positionId];
        }
        return result;
    }

    function get_buy(address _owner, uint256 _positionId) external view returns (DualAssetPosition memory) {
        return positions_buy[_owner][_positionId];
    }

    function get_sell(address _owner, uint256 _positionId) external view returns (DualAssetPosition memory) {
        return positions_sell[_owner][_positionId];
    }

    function getBuyPositionCount(address _owner) external view returns (uint256) {
        return this.get_positions_buy(_owner).length;
    }

    function getBuyPositionCount() external view returns (uint256) {
        return buyPositionKeys.length;
    }

    function getSellPositionCount(address _owner) external view returns (uint256) {
        return this.get_positions_sell(_owner).length;
    }

    function getSellPositionCount() external view returns (uint256) {
        return sellPositionKeys.length;
    }

    function getReadyBuyPositions() public view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < buyPositionKeys.length; i++) {
            if (
                positions_buy[buyPositionKeys[i].owner][buyPositionKeys[i].positionId].expiryTimestamp
                    <= block.timestamp
            ) {
                count++;
            }
        }
        uint256[] memory readyIndexes = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = buyPositionKeys.length; i > 0; i--) {
            if (
                positions_buy[buyPositionKeys[i - 1].owner][buyPositionKeys[i - 1].positionId].expiryTimestamp
                    <= block.timestamp
            ) {
                readyIndexes[idx] = i - 1;
                idx++;
            }
        }
        return readyIndexes;
    }

    function getReadySellPositions() public view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < sellPositionKeys.length; i++) {
            if (
                positions_sell[sellPositionKeys[i].owner][sellPositionKeys[i].positionId].expiryTimestamp
                    <= block.timestamp
            ) {
                count++;
            }
        }
        uint256[] memory readyIndexes = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = sellPositionKeys.length; i > 0; i--) {
            if (
                positions_sell[sellPositionKeys[i - 1].owner][sellPositionKeys[i - 1].positionId].expiryTimestamp
                    <= block.timestamp
            ) {
                readyIndexes[idx] = i - 1;
                idx++;
            }
        }
        return readyIndexes;
    }

    // Configuration functions
    function setTraderFactory(DoppiTraderFactory _traderFactory) external onlyOwner {
        traderFactory = _traderFactory;
    }

    function setAdmin(address _admin, bool _status) public onlyAdmin {
        admins[_admin] = _status;
    }

    function setPriceGap(uint256 _priceGap) external onlyOwner {
        PRICE_GAP_PEROFFER = _priceGap;
    }

    // Internal functions
    function _depositBuy(DepositParams calldata params, DualAssetOffer memory _buyOffer) internal {
        uint256 priceDecimals = doppiLP.getPriceDecimals();
        uint256 price = doppiLP.getPrice();

        assetA.safeTransferFrom(msg.sender, address(this), params.amount);
        uint256 positionId = nextPositionId++;

        // Hedge
        uint256 hedgeAmount = params.amount.mulDiv(_buyOffer.delta, 10000);
        uint256 hedgeAmountInAssetB = hedgeAmount.mulDiv(10 ** priceDecimals, price);
        uint256 hedgeOut = doppiLP.hedgeSwap(hedgeAmountInAssetB, price, false); // Selling Asset B to hedge

        positions_buy[msg.sender][positionId] = DualAssetPosition(
            params.amount,
            _buyOffer.price,
            _buyOffer.strikePrice,
            block.timestamp + (86400 * params.numDays),
            _buyOffer.apr,
            msg.sender,
            0,
            false,
            params.amount.mulDiv(_buyOffer.apr, 10000 * 365),
            hedgeAmount,
            hedgeOut,
            price
        );
        buyPositionKeys.push(KeyPosition(msg.sender, positionId));
    }

    function _depositSell(DepositParams calldata params, DualAssetOffer memory _sellOffer) internal {
        uint256 priceDecimals = doppiLP.getPriceDecimals();
        uint256 price = doppiLP.getPrice();

        assetB.safeTransferFrom(msg.sender, address(this), params.amount);
        uint256 positionId = nextPositionId++;

        // Hedge
        uint256 hedgeAmount = params.amount.mulDiv(_sellOffer.delta, 10000);
        uint256 hedgeAmountInAssetA = hedgeAmount.mulDiv(price, 10 ** priceDecimals);
        uint256 hedgeOut = doppiLP.hedgeSwap(hedgeAmountInAssetA, price, true); // Selling Asset B to hedge
        
        positions_sell[msg.sender][positionId] = DualAssetPosition(
            params.amount,
            _sellOffer.price,
            _sellOffer.strikePrice,
            block.timestamp + (86400 * params.numDays),
            _sellOffer.apr,
            msg.sender,
            0,
            false,
            params.amount.mulDiv(_sellOffer.apr, 10000 * 365),
            hedgeAmount,
            hedgeOut,
            price
        );
        sellPositionKeys.push(KeyPosition(msg.sender, positionId));

        emit Deposited(msg.sender, 0, params.amount);
    }

    function _settleBuyPosition(KeyPosition memory position) internal {
        DualAssetPosition storage p = positions_buy[position.owner][position.positionId];
        require(p.expiryTimestamp <= block.timestamp, "no ready for settlement");
        uint256 price = doppiLP.getPrice();
        uint8 priceDecimals = doppiLP.getPriceDecimals();

        doppiLP.transfer(assetA, p.interest, address(this));
        if (price <= p.strikePrice) {
            uint256 assetBPayout = p.amount.mulDiv(10 ** priceDecimals, p.strikePrice);
            if (!p.isTraded) {
                _settleStrikeNoTraded(p, price, assetBPayout, true);
            } else {
                _settleStrikeTraded(p, assetBPayout, true);
            }
            if (address(traderFactory) != address(0) && traderFactory.isTraderBot(p.owner)) {
                IDoppiTrader(p.owner).createUnwindPosition(p.amount, p.strikePrice, true);
            }
        } else {
            if (p.isTraded) {
                _settleNoStrikeTraded(p, price, true);
            } else {
                _settleNoStrikeNoTraded(p, true);
            }
        }

        settleHedgeSwap(p, price, true);

        emit Settled(p.owner, 0, p.amount);
    }

    function _settleSellPosition(KeyPosition memory position) internal {
        DualAssetPosition storage p = positions_sell[position.owner][position.positionId];
        require(p.expiryTimestamp <= block.timestamp, "no ready for settlement");
        uint256 price = doppiLP.getPrice();
        uint8 priceDecimals = doppiLP.getPriceDecimals();

        doppiLP.transfer(assetB, p.interest, address(this));
        if (price >= p.strikePrice) {
            uint256 assetAPayout = p.amount.mulDiv(p.strikePrice, 10 ** priceDecimals);
            if (!p.isTraded) {
                _settleStrikeNoTraded(p, price, assetAPayout, false);
            } else {
                _settleStrikeTraded(p, assetAPayout, false);
            }
            if (address(traderFactory) != address(0) && traderFactory.isTraderBot(p.owner)) {
                IDoppiTrader(p.owner).createUnwindPosition(p.amount, p.strikePrice, false);
            }
        } else {
            if (p.isTraded) {
                _settleNoStrikeTraded(p, price, false);
            } else {
                _settleNoStrikeNoTraded(p, false);
            }
        }

        settleHedgeSwap(p, price, false);

        emit Settled(p.owner, p.amount, 0);
    }

    function _removeSellPosition(uint256 index, KeyPosition memory _pos) internal {
        delete positions_sell[_pos.owner][_pos.positionId];
        sellPositionKeys[index] = sellPositionKeys[sellPositionKeys.length - 1];
        sellPositionKeys.pop();
    }

    function _removeBuyPosition(uint256 index, KeyPosition memory _pos) internal {
        delete positions_buy[_pos.owner][_pos.positionId];
        buyPositionKeys[index] = buyPositionKeys[buyPositionKeys.length - 1];
        buyPositionKeys.pop();
    }

    function _getStrikePrice(uint256 _price, uint8 _strikeZone, bool _isBuy) internal view returns (uint256) {
        uint8 priceDecimals = doppiLP.getPriceDecimals();
        uint256 priceGapWithDecimals = PRICE_GAP_PEROFFER * 10 ** priceDecimals;
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        if (_isBuy) {
            return _price - (priceGapWithDecimals * _strikeZone);
        } else {
            return _price + (priceGapWithDecimals * _strikeZone);
        }
    }

    // Settlement helper functions (from DualAssetNew)
    function _settleStrikeNoTraded(DualAssetPosition memory p, uint256 _price, uint256 _payout, bool _isBuy) internal {
        if (_isBuy) {
            assetA.safeIncreaseAllowance(address(doppiLP), p.amount);
            uint256 amountOut = doppiLP.settle(p.amount, _price, true);
            uint256 profit = amountOut > _payout ? amountOut - _payout : 0;
            dualStats[p.owner].settleProfit_assetB += profit;
            dualStats[p.owner].interestPaid_assetA += p.interest;

            if(profit > 0){
                assetB.safeTransfer(address(doppiLP), profit);
            }
            assetB.safeTransfer(p.owner, _payout);
            assetA.safeTransfer(p.owner, p.interest);
        } else {
            assetB.safeIncreaseAllowance(address(doppiLP), p.amount);
            uint256 amountOut = doppiLP.settle(p.amount, _price, false);
            uint256 profit = amountOut > _payout ? amountOut - _payout : 0;

            dualStats[p.owner].settleProfit_assetA += profit;
            dualStats[p.owner].interestPaid_assetB += p.interest;

            if(profit > 0){
                assetA.safeTransfer(address(doppiLP), profit);
            }
            assetA.safeTransfer(p.owner, _payout);
            assetB.safeTransfer(p.owner, p.interest);
        }
    }

    function _settleStrikeTraded(DualAssetPosition memory p, uint256 _payout, bool _isBuy) internal {
        if (_isBuy) {
            dualStats[p.owner].interestPaid_assetA += p.interest;

            if (p.swappedAmount >= _payout) {
                dualStats[p.owner].opportunityProfit_assetB += p.swappedAmount - _payout;
                assetB.safeTransfer(address(doppiLP), p.swappedAmount - _payout);
            } else {
                dualStats[p.owner].opportunityLoss_assetB += _payout - p.swappedAmount;
                doppiLP.transfer(assetB, _payout - p.swappedAmount, address(this));
            }

            assetB.safeTransfer(p.owner, _payout);
            assetA.safeTransfer(p.owner, p.interest);
        } else {
            dualStats[p.owner].interestPaid_assetB += p.interest;

            if (p.swappedAmount >= _payout) {
                dualStats[p.owner].opportunityProfit_assetA += p.swappedAmount - _payout;
                assetA.safeTransfer(address(doppiLP), p.swappedAmount - _payout);
            } else {
                dualStats[p.owner].opportunityLoss_assetA += _payout - p.swappedAmount;
                doppiLP.transfer(assetA, _payout - p.swappedAmount, address(this));
            }

            assetA.safeTransfer(p.owner, _payout);
            assetB.safeTransfer(p.owner, p.interest);
        }
    }

    function _settleNoStrikeTraded(DualAssetPosition memory p, uint256 _price, bool _isBuy) internal {
        if (_isBuy) {
            assetB.safeIncreaseAllowance(address(doppiLP), p.swappedAmount);
            uint256 amountOut = doppiLP.settle(p.swappedAmount, _price, false);
            dualStats[p.owner].interestPaid_assetA += p.interest;

            if (amountOut >= p.amount) {
                dualStats[p.owner].opportunityProfit_assetA += amountOut - p.amount;
                assetA.safeTransfer(address(doppiLP), amountOut - p.amount);
            } else {
                dualStats[p.owner].opportunityLoss_assetA += p.amount - amountOut;
                doppiLP.transfer(assetA, p.amount - amountOut, address(this));
            }

            assetA.safeTransfer(p.owner, p.amount + p.interest);
        } else {
            assetA.safeIncreaseAllowance(address(doppiLP), p.swappedAmount);
            uint256 amountOut = doppiLP.settle(p.swappedAmount, _price, true);
            dualStats[p.owner].interestPaid_assetB += p.interest;

            if (amountOut >= p.amount) {
                dualStats[p.owner].opportunityProfit_assetB += amountOut - p.amount;
                assetB.safeTransfer(address(doppiLP), amountOut - p.amount);
            } else {
                dualStats[p.owner].opportunityLoss_assetB += p.amount - amountOut;
                doppiLP.transfer(assetB, p.amount - amountOut, address(this));
            }

            assetB.safeTransfer(p.owner, p.amount + p.interest);
        }
    }

    function _settleNoStrikeNoTraded(DualAssetPosition memory p, bool _isBuy) internal {
        if (_isBuy) {
            dualStats[p.owner].interestPaid_assetA += p.interest;
            assetA.safeTransfer(p.owner, p.amount + p.interest);
        } else {
            dualStats[p.owner].interestPaid_assetB += p.interest;
            assetB.safeTransfer(p.owner, p.amount + p.interest);
        }
    }

    function settleHedgeSwap(DualAssetPosition memory p, uint256 price, bool isBuy) internal {
        if (isBuy) {
            uint256 hedgeOut = doppiLP.hedgeSwap(p.swappedHedgeAmount, price, true); // Asset A -> Asset B
            if (hedgeOut > p.hedgeAmount) {
                settleHedgeProfitAssetB += hedgeOut - p.hedgeAmount;
            } else {
                settleHedgeLossAssetB += p.hedgeAmount - hedgeOut;
            }
        } else {
            uint256 hedgeOut = doppiLP.hedgeSwap(p.swappedHedgeAmount, price, false); // Asset B -> Asset A
            if (hedgeOut > p.hedgeAmount) {
                settleHedgeProfitAssetA += hedgeOut - p.hedgeAmount;
            } else {
                settleHedgeLossAssetA += p.hedgeAmount - hedgeOut;
            }
        }
    }

    function _adminTrade(
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
                ? positions_sell[_owner][sellPositionKeys[_keyIndex].positionId] // unwind buy → opposite side
                : positions_buy[_owner][buyPositionKeys[_keyIndex].positionId]; // normal buy
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
                ? positions_buy[_owner][buyPositionKeys[_keyIndex].positionId] // unwind sell → opposite side
                : positions_sell[_owner][sellPositionKeys[_keyIndex].positionId]; // normal sell
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
        for (uint256 i = 1; i < arr.length; i++) {
            if (arr[i - 1] < arr[i]) {
                return false;
            }
        }
        return true;
    }

    modifier onlyAdmin() {
        require(admins[msg.sender], "only admin");
        _;
    }
}
