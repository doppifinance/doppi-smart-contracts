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
        uint256 hedgeAmountInHedgeToken; // amount sell of B
        uint256 swappedHedgeAmount; // proceeds of A 
        uint256 hedgePrice; // sold price
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
    DoppiTraderFactory public doppiTraderFactory;
    mapping(address => bool) public admins;

    uint256 private constant SECONDS_PER_YEAR = 31536000;
    uint256 public PRICE_GAP_PEROFFER = 500;

    mapping(address => mapping(uint256 => DualAssetPosition)) public positions_buy;
    mapping(address => mapping(uint256 => DualAssetPosition)) public positions_sell;
    KeyPosition[] public buyPositionKeys;
    KeyPosition[] public sellPositionKeys;
    uint256 private nextPositionId = 1;
    address public s_forwarderAddress;
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
    function bulkDepositBuys(DepositParams[] calldata params, DualAssetOffer[] memory _buyOffers) external onlyTraderBot {
        for (uint256 i = 0; i < params.length; i++) {
            DualAssetOffer memory buyOffer = _buyOffers[params[i].strikeZone];
            _depositBuy(params[i], buyOffer);
        }
    }

    // check not required to save gas as it is called internally from trader bot
    function bulkDepositSells(DepositParams[] calldata params, DualAssetOffer[] memory _sellOffers) external onlyTraderBot {
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
            _settlePosition(pos, true);
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
            _settlePosition(pos, false);
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

    function performUpkeep(bytes calldata performData) external onlyForwarder {
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
    function setDoppiTraderFactory(DoppiTraderFactory _traderFactory) external onlyOwner {
        doppiTraderFactory = _traderFactory;
    }

    function setAdmin(address _admin, bool _status) public onlyOwner {
        admins[_admin] = _status;
    }

    function setPriceGap(uint256 _priceGap) external onlyOwner {
        PRICE_GAP_PEROFFER = _priceGap;
    }

    /// @notice Set the address that `performUpkeep` is called from
    /// @dev Only callable by the owner
    /// @param forwarderAddress the address to set
    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        s_forwarderAddress = forwarderAddress;
    }

    // Internal functions
    function _depositBuy(DepositParams calldata params, DualAssetOffer memory _buyOffer) internal {
        
        uint256 price = doppiLP.getPrice();

        assetA.safeTransferFrom(msg.sender, address(this), params.amount);
        uint256 positionId = nextPositionId++;

        // Hedge
        (uint256 hedgeAmountInAssetB, uint256 swappedHedgeAmount, uint256 hedgePrice) = _hedgeSwap(params.amount, _buyOffer.delta, price, true);

        positions_buy[msg.sender][positionId] = DualAssetPosition(
            params.amount,
            _buyOffer.price,
            _buyOffer.strikePrice,
            block.timestamp + (86400 * params.numDays),
            _buyOffer.apr,
            msg.sender,
            0,
            false,
            params.amount.mulDiv(_buyOffer.apr, 10000 * (31536000 / 86400 * params.numDays)),
            hedgeAmountInAssetB, // amount sell of B
            swappedHedgeAmount, // proceeds of A 
            hedgePrice // sold price
        );

        buyPositionKeys.push(KeyPosition(msg.sender, positionId));
    }

    function _depositSell(DepositParams calldata params, DualAssetOffer memory _sellOffer) internal {
        
        uint256 price = doppiLP.getPrice();

        assetB.safeTransferFrom(msg.sender, address(this), params.amount);
        uint256 positionId = nextPositionId++;

        // Hedge
        (uint256 hedgeAmountInAssetA, uint256 swappedHedgeAmount, uint256 hedgePrice) = _hedgeSwap(params.amount, _sellOffer.delta, price, false);

        positions_sell[msg.sender][positionId] = DualAssetPosition(
            params.amount,
            _sellOffer.price,
            _sellOffer.strikePrice,
            block.timestamp + (86400 * params.numDays),
            _sellOffer.apr,
            msg.sender,
            0,
            false,
            params.amount.mulDiv(_sellOffer.apr, 10000 * (31536000 / 86400 * params.numDays)),
            hedgeAmountInAssetA, // amount sell of B
            swappedHedgeAmount, // proceeds of A 
            hedgePrice // sold price
        );
        sellPositionKeys.push(KeyPosition(msg.sender, positionId));

        emit Deposited(msg.sender, 0, params.amount);
    }

    function _settlePosition(KeyPosition memory position, bool isBuy) internal {
        // Select the correct position mapping based on direction
        DualAssetPosition storage p = isBuy 
            ? positions_buy[position.owner][position.positionId] 
            : positions_sell[position.owner][position.positionId];
        
        require(p.expiryTimestamp <= block.timestamp, "not ready for settlement");
        
        uint256 price = doppiLP.getPrice();
        uint8 priceDecimals = doppiLP.getPriceDecimals();
        
        // Determine assets and conditions based on direction
        IERC20 interestAsset = isBuy ? assetA : assetB;
        bool isInTheMoney = isBuy ? (price <= p.strikePrice) : (price >= p.strikePrice);

        // Transfer interest
        doppiLP.transfer(interestAsset, p.interest, address(this));

        if (isInTheMoney) {
            // Calculate payout - different formula for buy vs sell
            uint256 payout = isBuy 
                ? p.amount.mulDiv(10 ** priceDecimals, p.strikePrice)  // Buy payout
                : p.amount.mulDiv(p.strikePrice, 10 ** priceDecimals); // Sell payout
            
            // Handle traded vs non-traded
            p.isTraded 
                ? _settleStrikeTraded(p, payout, isBuy) 
                : _settleStrikeNoTraded(p, price, payout, isBuy);
            
            // Create unwind position for trader bots
            if (address(doppiTraderFactory) != address(0) && doppiTraderFactory.isTraderBot(p.owner)) {
                IDoppiTrader(p.owner).createUnwindPosition(p.amount, p.strikePrice, isBuy);
            }
        } else {
            // Handle out-of-the-money positions
            p.isTraded 
                ? _settleNoStrikeTraded(p, price, isBuy) 
                : _settleNoStrikeNoTraded(p, isBuy);
        }

        _settleHedgeSwap(p, price, isBuy);
        emit Settled(p.owner, isBuy ? 0 : p.amount, isBuy ? p.amount : 0);
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
        return _isBuy ? _price - (priceGapWithDecimals * _strikeZone) : _price + (priceGapWithDecimals * _strikeZone);
    }

    // Settlement helper functions (from DualAssetNew)
    function _settleStrikeNoTraded(DualAssetPosition memory p, uint256 _price, uint256 _payout, bool _isBuy) internal {
        // 1. Determine the assets based on the trade direction
        (IERC20 inToken, IERC20 payoutToken, IERC20 interestToken) = _isBuy 
            ? (assetA, assetB, assetA) 
            : (assetB, assetA, assetB);

        // 2. Execute the settlement
        inToken.safeIncreaseAllowance(address(doppiLP), p.amount);
        uint256 amountOut = doppiLP.settle(p.amount, _price, _isBuy);
        
        // 3. Calculate profit
        uint256 profit = amountOut > _payout ? amountOut - _payout : 0;
        
        // 4. Update stats - directly update the correct storage field
        if (_isBuy) {
            dualStats[p.owner].settleProfit_assetB += profit;
            dualStats[p.owner].interestPaid_assetA += p.interest;
        } else {
            dualStats[p.owner].settleProfit_assetA += profit;
            dualStats[p.owner].interestPaid_assetB += p.interest;
        }

        // 5. Transfer tokens
        if (profit > 0) {
            payoutToken.safeTransfer(address(doppiLP), profit);
        }
        payoutToken.safeTransfer(p.owner, _payout);
        interestToken.safeTransfer(p.owner, p.interest);
    }

    function _settleStrikeTraded(DualAssetPosition memory p, uint256 _payout, bool _isBuy) internal {
        // 1. Determine assets and stats based on direction
        (IERC20 profitToken, IERC20 payoutToken, IERC20 interestToken) = _isBuy 
            ? (assetB, assetB, assetA) 
            : (assetA, assetA, assetB);

        // 2. Update interest stats
        if (_isBuy) {
            dualStats[p.owner].interestPaid_assetA += p.interest;
        } else {
            dualStats[p.owner].interestPaid_assetB += p.interest;
        }

        // 3. Calculate profit/loss
        uint256 profitOrLoss;
        bool isProfit = p.swappedAmount >= _payout;
        
        if (isProfit) {
            profitOrLoss = p.swappedAmount - _payout;
            // Update profit stats
            if (_isBuy) {
                dualStats[p.owner].opportunityProfit_assetB += profitOrLoss;
            } else {
                dualStats[p.owner].opportunityProfit_assetA += profitOrLoss;
            }
            profitToken.safeTransfer(address(doppiLP), profitOrLoss);
        } else {
            profitOrLoss = _payout - p.swappedAmount;
            // Update loss stats
            if (_isBuy) {
                dualStats[p.owner].opportunityLoss_assetB += profitOrLoss;
            } else {
                dualStats[p.owner].opportunityLoss_assetA += profitOrLoss;
            }
            doppiLP.transfer(profitToken, profitOrLoss, address(this));
        }

        // 4. Execute final transfers
        payoutToken.safeTransfer(p.owner, _payout);
        interestToken.safeTransfer(p.owner, p.interest);
    }

    function _settleNoStrikeTraded(DualAssetPosition memory p, uint256 _price, bool _isBuy) internal {
        // 1. Determine assets based on direction
        (IERC20 settleToken, IERC20 profitLossToken) = _isBuy 
            ? (assetB, assetA) 
            : (assetA, assetB);

        // 2. Execute settlement
        settleToken.safeIncreaseAllowance(address(doppiLP), p.swappedAmount);
        uint256 amountOut = doppiLP.settle(p.swappedAmount, _price, !_isBuy);
        
        // 3. Update interest stats
        if (_isBuy) {
            dualStats[p.owner].interestPaid_assetA += p.interest;
        } else {
            dualStats[p.owner].interestPaid_assetB += p.interest;
        }

        // 4. Handle profit/loss
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

        // 5. Final transfer (principal + interest)
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
        
        // no hedge position
        if(p.swappedHedgeAmount == 0) return;

        (uint256 hedgeOut, ) = doppiLP.hedgeSwap(p.swappedHedgeAmount, price, isBuy); // Asset A -> Asset B
        if (hedgeOut > p.hedgeAmountInHedgeToken) {
            uint256 profit = hedgeOut - p.hedgeAmountInHedgeToken;
            if(isBuy){
                settleHedgeProfitAssetB += profit;  
            }else{
                settleHedgeProfitAssetA += profit;    
            } 
        }else{
            uint256 loss = p.hedgeAmountInHedgeToken - hedgeOut;
            if(isBuy){
                settleHedgeLossAssetB += loss;  
            }else{
                settleHedgeLossAssetA += loss;    
            } 
        } 
    }

    function _hedgeSwap(uint256 _amount, uint256 _delta, uint256 _price, bool isBuy) internal returns (uint256 amountInHedgeAsset, uint256 swappedHedgeAmount, uint256 hedgePrice) {
        
        uint256 priceDecimals = doppiLP.getPriceDecimals();
        uint256 hedgeAmount = _amount.mulDiv(_delta, 10000);
        amountInHedgeAsset = hedgeAmount.mulDiv(10 ** priceDecimals, _price);
        (swappedHedgeAmount, hedgePrice) = doppiLP.hedgeSwap(amountInHedgeAsset, _price, !isBuy); // Selling Asset B to hedge
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

    modifier onlyForwarder() {
        require(msg.sender == s_forwarderAddress, "This address does not have permission to call performUpkeep");
        _;
    }

    modifier onlyTraderBot() {
        require(doppiTraderFactory.isTraderBot(msg.sender), "only trader bot is allowed to call");
        _;
    }

    
}
