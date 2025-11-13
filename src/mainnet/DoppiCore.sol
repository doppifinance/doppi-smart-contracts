// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {IDoppiTrader} from "../Interface/IDoppiTrader.sol";
import {IDoppiPoints} from "../Interface/IDoppiPoints.sol";
import {IDoppiOffer} from "../Interface/IDoppiOffer.sol";
import "./DoppiCoreTypes.sol";
import "./DoppiCoreAdmin.sol";
import "./DoppiCoreView.sol";
// import "forge-std/console.sol";

contract DoppiCore is DoppiCoreAdmin, DoppiCoreView, ReentrancyGuard, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetA; // Made immutable
    IERC20 public immutable assetB; // Made immutable
    IDoppiOffer public immutable doppiOffer; // Made immutable
    IDoppiPoints public immutable doppiPoints;

    PendingSettlement public pendingSettlementBuy;
    PendingSettlement public pendingSettlementSell;
    uint256 public priceDecimal;
    uint64 private nextPositionId = 1; 
    uint32 public constant SECONDS_PER_YEAR = 31536000;
    uint24 public constant SECONDS_PER_DAY = 86400;
    uint16 public constant BASIS_POINTS = 10000;

    event Deposited(address indexed trader, uint64 positionId, address asset, uint256 amount, uint256 interest, uint256 strikePrice, uint32 apr, uint32 numDays);
    event Settled(address indexed trader, uint64 positionId, bool striked, bool isProfit, uint256 profitLoss, uint256 payout, uint256 interest, address profitToken, address payoutToken, address interestToken);
    event HedgeSettled(address indexed trader, uint64 positionId, bool isProfit, uint256 profitLoss, address profitToken);
    event EmergencyWithdraw(bool isBuy, address indexed trader, uint64 positionId, uint256 amount);

    error InvalidStrikePriceOrPrice();
    error InvalidAPR();
    error InvalidAmount();
    error InvalidOfferLength();
    error PriceMismatch();
    error NotExpired();
    error NoPosition();
    error ExceedsPoolCap();

    constructor(address _assetA, address _assetB, IDoppiLiquidity _doppiLP, IDoppiOffer _doppiOffer)
        Ownable(msg.sender)
    {
        assetA = IERC20(_assetA);
        assetB = IERC20(_assetB);
        doppiLP = _doppiLP;
        doppiConfig = DoppiConfig(doppiLP.getDoppiConfig());
        doppiOffer = _doppiOffer;
        priceDecimal = 10 ** _doppiLP.getPriceDecimals();
        doppiPoints = IDoppiPoints(doppiConfig.doppiPoints());
        opportunityBots[msg.sender] = true;
        assetA.safeIncreaseAllowance(address(doppiLP), type(uint256).max);
        assetB.safeIncreaseAllowance(address(doppiLP), type(uint256).max);
    }

    // Single deposit functionality
    function deposit_buy(DepositParams calldata params) 
        external nonReentrant whenNotPaused whenOpen {
        
        if (!canAcceptDeposit(true, params.amount)) {
            revert ExceedsPoolCap();
        }
        DualAssetOffer memory buyOffer = doppiOffer.getOffer(true, params.numDays, params.strikeZone);
        if(buyOffer.strikePrice != params.strikePrice || buyOffer.price == 0) revert InvalidStrikePriceOrPrice();
        if(!_isAPRWithinTolerance(buyOffer.apr, params.apr)) revert InvalidAPR();
        _depositBuy(params, buyOffer, true);
    }

    function deposit_sell(DepositParams calldata params) 
        external nonReentrant whenNotPaused whenOpen {
        
        if (!canAcceptDeposit(false, params.amount)) {
            revert ExceedsPoolCap();
        }
        DualAssetOffer memory sellOffer = doppiOffer.getOffer(false, params.numDays, params.strikeZone);
        if(sellOffer.strikePrice != params.strikePrice) revert InvalidStrikePriceOrPrice();
        if(!_isAPRWithinTolerance(sellOffer.apr, params.apr)) revert InvalidAPR();
        _depositSell(params, sellOffer, true);
    }

    function bulkHedge(uint256 _amountInHedgeAsset, uint256 _price, bool isBuy) external onlyTraderBot returns (uint256 swappedHedgeAmount, uint256 hedgePrice) {
        (swappedHedgeAmount, hedgePrice) = _doppiHedgeSwap(_amountInHedgeAsset, _price, isBuy);
        
    }

    function bulkDeposit(bool isBuy, DepositParams[] calldata params, DualAssetOffer[] memory _offers, bool _hedge) external onlyTraderBot whenNotPaused {
        uint256 length = params.length;
        if(length != _offers.length) revert InvalidOfferLength();
        
        for (uint256 i = 0; i < length; ) {
            DepositParams calldata param = params[i];
            if(param.amount == 0) revert InvalidAmount();
            if(param.apr == 0) revert InvalidAPR();

            isBuy ? _depositBuy(param, _offers[i], _hedge) : _depositSell(param, _offers[i], _hedge);
            unchecked { ++i; }
        }
    }

    function settle_buys(uint256[] memory _indexes) external nonReentrant onlyOwner {
        
        uint256 settlePrice = _getPriceFromLP();
        _settle_positions(_indexes, true, settlePrice);
    }

    function settle_sells(uint256[] memory _indexes) external nonReentrant onlyOwner {
        uint256 settlePrice = _getPriceFromLP();
        _settle_positions(_indexes, false, settlePrice);
    }

    // Admin functions
    function opportunitySwap(address _owner, uint256 _amountPay, uint256 _price, uint256 _keyIndex, bool _isBuy)
        external
        nonReentrant
        onlyOpportunityBot
        returns (uint256 amountOut, uint256 profit)
    {
        uint256 price = _getPriceFromLP();
        if(price != _price) revert PriceMismatch();
        return _oppTrade(_owner, _amountPay, _price, _keyIndex, _isBuy, false);
    }

    function opportunityUnwind(address _owner, uint256 _amountPay, uint256 _price, uint256 _keyIndex, bool _isBuy)
        external
        nonReentrant
        onlyOpportunityBot
        returns (uint256 amountOut, uint256 profit)
    {
        uint256 price = _getPriceFromLP();
        if(price != _price) revert PriceMismatch();
        return _oppTrade(_owner, _amountPay, _price, _keyIndex, _isBuy, true);
    }

    // Chainlink Keepers integration
    function checkUpkeep(bytes calldata) 
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // Check if we have pending settlements first (highest priority)
        if (pendingSettlementBuy.indexes.length > 0 || pendingSettlementSell.indexes.length > 0) {
            return (true, abi.encode(true)); // cached = true
        }
        
        // Check for new ready positions if no pending settlements
        uint256[] memory buys = getReadyBuyPositions();
        uint256[] memory sells = getReadySellPositions();
        
        if ((buys.length > 0 || sells.length > 0) && !paused()) {
            return (true, abi.encode(false, buys, sells)); // cached = false, with indexes
        }
        
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external nonReentrant onlyForwarder {
        
        if(paused()) return;
        
        // Decode the minimal data needed
        bool cached = abi.decode(performData, (bool));
        if (cached) {
            // Process pending settlements
            _processPendingSettlements();
        } else {
            // Process new settlements
            (, uint256[] memory buyIndexes, uint256[] memory sellIndexes) = 
                abi.decode(performData, (bool, uint256[], uint256[]));
            _processNewSettlements(buyIndexes, sellIndexes);
        }
    }

    function emergencyWithdraw() external whenEmergency whenPaused nonReentrant {
        _emergencyWithdrawSells();
        _emergencyWithdrawBuys();
    }

    function isEmergency() external view returns (bool){
        return emergencyMode;
    } 

    // Internal functions
    function _isAPRWithinTolerance(uint256 offerAPR, uint256 providedAPR) internal view returns (bool) {
        
        if (offerAPR == 0) return false;
        if (offerAPR == providedAPR) return true;
        uint256 deviation = providedAPR > offerAPR ? providedAPR - offerAPR : offerAPR - providedAPR;
        uint256 maxAllowedDeviation = (offerAPR * aprToleranceBP) / 10000;
        
        return deviation <= maxAllowedDeviation;
    }

    function _emergencyWithdrawSells() internal {
        for (uint256 i = sellPositionKeys.length; i > 0; ) {
            uint256 index = i - 1;
            KeyPosition memory keyPos = sellPositionKeys[index];
            
            if (keyPos.owner == msg.sender) {
                DualAssetPosition storage pos = positions_sell[keyPos.owner][keyPos.positionId];
                
                if (pos.amount > 0) {
                    uint256 amountToReturn = pos.amount;
                    // Update total deposits (prevent underflow)
                    if (totalSellDeposits >= amountToReturn) {
                        totalSellDeposits -= amountToReturn;
                    } else {
                        totalSellDeposits = 0;
                    }
                    _removePosition(index, keyPos, false); // for sells
                    assetB.safeTransfer(keyPos.owner, amountToReturn);
                    emit EmergencyWithdraw(false, keyPos.owner, keyPos.positionId, amountToReturn);
                }
            }
            unchecked { --i; }
        }
    }

    function _emergencyWithdrawBuys() internal {
        for (uint256 i = buyPositionKeys.length; i > 0; ) {
            uint256 index = i - 1;
            KeyPosition memory keyPos = buyPositionKeys[index];
            
            if (keyPos.owner == msg.sender) {
                DualAssetPosition storage pos = positions_buy[keyPos.owner][keyPos.positionId];
                
                if (pos.amount > 0) {
                    uint256 amountToReturn = pos.amount;
                    // Update total deposits (prevent underflow)
                    if (totalBuyDeposits >= amountToReturn) {
                        totalBuyDeposits -= amountToReturn;
                    } else {
                        totalBuyDeposits = 0;
                    }
                    _removePosition(index, keyPos, true);  // for buys
                    assetA.safeTransfer(keyPos.owner, amountToReturn);
                    emit EmergencyWithdraw(true, keyPos.owner, keyPos.positionId, amountToReturn);
                }
            }
            unchecked { --i; }
        }
    }

    function _getAndRemoveNextBatch(bool isBuy) internal returns (uint256[] memory batch, uint256 settlePrice) {
        PendingSettlement storage pending = isBuy ? pendingSettlementBuy : pendingSettlementSell;
        
        uint256 total = pending.indexes.length;
        if (total == 0) {
            return (new uint256[](0), 0);
        }
        
        uint256 count = total > UPKEEPS_PER_CHECK ? UPKEEPS_PER_CHECK : total;
        
        // Extract the batch to process
        batch = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            batch[i] = pending.indexes[i];
        }
        
        settlePrice = pending.settlementPrice;
        
        // Remove processed indexes from storage in the same operation
        uint256 remaining = total - count;
        if (remaining > 0) {
            uint256[] memory newIndexes = new uint256[](remaining);
            for (uint256 i = 0; i < remaining; i++) {
                newIndexes[i] = pending.indexes[count + i];
            }
            pending.indexes = newIndexes;
        } else {
            // Clear everything if no remaining indexes
            delete pending.indexes;
            pending.settlementPrice = 0;
        }
    }

    function _processPendingSettlements() internal {
        uint256 settlePrice;
        uint256[] memory batch;
        
        // Process buy pending settlements
        if (pendingSettlementBuy.indexes.length > 0) {
            (batch, settlePrice) = _getAndRemoveNextBatch(true);
            if (batch.length > 0) {
                _settle_positions(batch, true, settlePrice);
            }
        }
        
        // Process sell pending settlements
        if (pendingSettlementSell.indexes.length > 0) {
            (batch, settlePrice) = _getAndRemoveNextBatch(false);
            if (batch.length > 0) {
                _settle_positions(batch, false, settlePrice);
            }
        }
    }

    function _processNewSettlements(uint256[] memory buyIndexes, uint256[] memory sellIndexes) internal {
        uint256 settlePrice = _getPriceFromLP();
        
        // Process buy positions with batching
        if (buyIndexes.length > 0) {
            uint256[] memory toProcess = _storeExcessiveSettlement(true, buyIndexes, settlePrice);
            if (toProcess.length > 0) {
                _settle_positions(toProcess, true, settlePrice);
            }
        }
        
        // Process sell positions with batching
        if (sellIndexes.length > 0) {
            uint256[] memory toProcess = _storeExcessiveSettlement(false, sellIndexes, settlePrice);
            if (toProcess.length > 0) {
                _settle_positions(toProcess, false, settlePrice);
            }
        }
    }

    function _storeExcessiveSettlement(
        bool isBuy,
        uint256[] memory indexes,
        uint256 settlementPrice
    ) internal returns (uint256[] memory toProcessIndexes) {

        uint256 totalUpkeeps = indexes.length;
        if(totalUpkeeps < UPKEEPS_PER_CHECK){
            return indexes;
        }
        uint256 count = totalUpkeeps > UPKEEPS_PER_CHECK ? UPKEEPS_PER_CHECK : totalUpkeeps;
        toProcessIndexes = new uint256[](count);
        for (uint256 i = 0; i < count;) {
            toProcessIndexes[i] = indexes[i];
            unchecked { ++i;}
        }
        uint256 remaining = totalUpkeeps - count;
        
        uint256[] memory remainIndexes = new uint256[](remaining);
        for (uint256 i = 0; i < remaining; ) {
            remainIndexes[i] = indexes[count + i];
            unchecked { ++i;}
        }
        PendingSettlement storage pendingSettle = isBuy ? pendingSettlementBuy : pendingSettlementSell;
        pendingSettle.indexes = remainIndexes;
        pendingSettle.settlementPrice = settlementPrice;
    }

    function _depositBuy(DepositParams calldata params, DualAssetOffer memory _buyOffer, bool _hedge) internal {
        uint256 amount = params.amount;
        uint32 numDays = params.numDays;
        address sender = msg.sender;

        assetA.safeTransferFrom(sender, address(this), amount);
        // Update total deposits
        totalBuyDeposits += amount;
        uint64 positionId = nextPositionId;
        unchecked { nextPositionId = positionId + 1; }

        // Hedge
        uint256 hedgeAmountInAssetB;
        uint256 swappedHedgeAmount; 
        uint256 hedgePrice;

        if(_hedge){
            (hedgeAmountInAssetB, swappedHedgeAmount, hedgePrice) = _hedgeSwap(amount, _buyOffer.delta, _buyOffer.price, true);
        }
        // Calculate interest using precomputed values
        uint256 duration = SECONDS_PER_DAY * numDays;
        uint256 interest = (amount * _buyOffer.apr) / BASIS_POINTS;
        interest = (interest * duration) / SECONDS_PER_YEAR;
        positions_buy[sender][positionId] = DualAssetPosition(
            amount,
            _buyOffer.price,
            _buyOffer.strikePrice,
            _buyOffer.expiry,
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

        assetB.safeTransferFrom(sender, address(this), params.amount);

        // Update total deposits
        totalSellDeposits += amount;

        uint64 positionId = nextPositionId;
        unchecked { nextPositionId = positionId + 1; }
        
        // Hedge
        uint256 hedgeAmountInAssetA;
        uint256 swappedHedgeAmount; 
        uint256 hedgePrice;

        if(_hedge){
            (hedgeAmountInAssetA, swappedHedgeAmount, hedgePrice) = _hedgeSwap(amount, _sellOffer.delta, _sellOffer.price, false);
        }
        // Calculate interest using precomputed values
        uint256 duration = SECONDS_PER_DAY * numDays;
        uint256 interest = (amount * _sellOffer.apr) / BASIS_POINTS;
        interest = (interest * duration) / SECONDS_PER_YEAR;
        positions_sell[sender][positionId] = DualAssetPosition(
            amount,
            _sellOffer.price,
            _sellOffer.strikePrice,
            _sellOffer.expiry,
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
        bool isBuy,
        uint256 price
    ) internal {
        DualAssetPosition storage p = isBuy
            ? positions_buy[position.owner][position.positionId]
            : positions_sell[position.owner][position.positionId];

        if(p.expiryTimestamp > block.timestamp) revert NotExpired();

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
            _doppiTransfer(interestAsset, p.interest, address(this));
        }

        // Determine in-the-money condition
        bool isInTheMoney = isBuy ? (price <= p.strikePrice) : (price >= p.strikePrice);

        // In-the-money branch
        if (isInTheMoney) {
            unchecked {
                payout = isBuy
                    ? (p.amount * priceDecimal) / p.strikePrice
                    : (p.amount * p.strikePrice) / priceDecimal;
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

        // record for points
        if(!doppiPoints.paused()){
            uint256 tradeVolume = isBuy ? p.amount : (p.amount * price) / priceDecimal; 
            _recordTradePoints(position.owner, tradeVolume);
        }
        
        if(isBuy) {
            totalBuyDeposits -= p.amount; 
        }else{
            totalSellDeposits -= p.amount; 
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

    function _removePosition(uint256 index, KeyPosition memory _pos, bool isBuy) internal {
        // Delete from storage mapping
        if (isBuy) {
            delete positions_buy[_pos.owner][_pos.positionId];
        } else {
            delete positions_sell[_pos.owner][_pos.positionId];
        }
        
        // Get the correct array
        KeyPosition[] storage positionKeys = isBuy ? buyPositionKeys : sellPositionKeys;
        uint256 lastIndex = positionKeys.length - 1;
        
        // Swap and pop
        if (index != lastIndex) {
            positionKeys[index] = positionKeys[lastIndex];
        }
        positionKeys.pop();
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
        // uint256 amountOut = doppiLP.settle(p.amount, _price, _isBuy);
        uint256 amountOut = _doppiSettleCall(p.amount, _price, _isBuy);
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
            _doppiTransfer(profitToken, profitOrLoss, address(this));
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
        // uint256 amountOut = doppiLP.settle(p.swappedAmount, _price, !_isBuy);
        uint256 amountOut = _doppiSettleCall(p.swappedAmount, _price, !_isBuy);

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
            _doppiTransfer(payoutToken, profitOrLoss, address(this));
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


    function _settleHedgeSwap(DualAssetPosition memory p, uint256 price, bool isBuy, uint64 _positionId) internal {
        
        if (p.swappedHedgeAmount == 0) return;
        
        (uint256 hedgeOut, ) = _doppiHedgeSwap(p.swappedHedgeAmount, price, isBuy);
        
        bool isProfit = hedgeOut > p.hedgeAmountInHedgeToken;
        uint256 profitOrLoss = isProfit ? hedgeOut - p.hedgeAmountInHedgeToken : p.hedgeAmountInHedgeToken - hedgeOut;
        
        address profitOrLossToken = isBuy ? address(assetB) : address(assetA);
        
        emit HedgeSettled(p.owner, _positionId, isProfit, profitOrLoss, profitOrLossToken);
    }

    function _hedgeSwap(uint256 _amount, uint256 _delta, uint256 _price, bool isBuy) internal returns (uint256 amountInHedgeAsset, uint256 swappedHedgeAmount, uint256 hedgePrice) {
        
        if(_delta >= BASIS_POINTS) return (0,0,0);
        uint256 hedgeAmount = _amount * _delta / BASIS_POINTS;
        amountInHedgeAsset = isBuy ? hedgeAmount * priceDecimal / _price : hedgeAmount * _price / priceDecimal;
        (swappedHedgeAmount, hedgePrice) = _doppiHedgeSwap(amountInHedgeAsset, _price, !isBuy);
        
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
            if(p.amount == 0) revert NoPosition();

            amountOut = _swapLowLevel(_amountPay, _price, _isBuy);

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
            if(p.amount == 0) revert NoPosition();

            amountOut = _swapLowLevel(_amountPay, _price, _isBuy);
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

    function _settle_positions(uint256[] memory _indexes, bool isBuy, uint256 _settlePrice) internal {
        uint256 length = _indexes.length;
        require(length > 0, "empty array");
        require(_isDescending(_indexes), "not descending");
        
        for (uint256 i = 0; i < length; ) {
            uint256 idx = _indexes[i];
            KeyPosition[] storage positionKeys = isBuy ? buyPositionKeys : sellPositionKeys;
            require(idx < positionKeys.length, "index out of bounds");
            
            KeyPosition memory pos = positionKeys[idx];
            _settlePosition(pos, isBuy, _settlePrice);
            isBuy ? _removePosition(idx, pos, true) : _removePosition(idx, pos, false);

            unchecked { ++i; }
        }
    }

    function _safeTransferWithFee(IERC20 _asset, address _to, uint256 _amount) internal {
        
        uint256 amountFee = _amount * doppiConfig.treasury_fee() / 10000;
        uint256 amountAfterFee = _amount - amountFee;
        _asset.safeTransfer(_to, amountAfterFee);
        _asset.safeTransfer(doppiConfig.treasury(), amountFee);

    }
    
    // Helpers interacting via low-level calls (to avoid interface in module)
    function _recordTradePoints(address trader, uint256 volume) internal {
        (bool ok,) = address(doppiPoints).call(abi.encodeWithSignature("recordTrade(address,uint256)", trader, volume));
    }

    function _swapLowLevel(
        uint256 amountIn,
        uint256 price,
        bool isBuy
    ) internal returns (uint256 amountOut) {
        bytes memory callData = abi.encodeWithSignature("swap(uint256,uint256,bool)", amountIn, price, isBuy);

        (bool success, bytes memory result) = address(doppiLP).call(callData);
        require(success && result.length >= 32, "doppiLP: call failed");

        amountOut = abi.decode(result, (uint256));
    }

    function _getPriceFromLP() internal view returns (uint256 price) {
        (bool ok, bytes memory ret) = address(doppiLP).staticcall(abi.encodeWithSignature("getPrice()"));
        require(ok && ret.length >= 32, "price failed");
        price = abi.decode(ret, (uint256));
    }

    function _doppiSettleCall(uint256 amount, uint256 price, bool isBuy) internal returns (uint256 out) {
        (bool ok, bytes memory ret) = address(doppiLP).call(abi.encodeWithSignature("settle(uint256,uint256,bool)", amount, price, isBuy));
        require(ok, "settle failed");
        out = abi.decode(ret, (uint256));
    }


    function _doppiTransfer(IERC20 token, uint256 amount, address to) internal {
        // call doppiLP.transfer(token, amount, to)
        (bool ok, ) = address(doppiLP).call(abi.encodeWithSignature("transfer(address,uint256,address)", address(token), amount, to));
        require(ok, "doppi transfer failed");
    }


    function _doppiHedgeSwap(uint256 amount, uint256 price, bool isBuy) internal returns (uint256 out, uint256 hedgePrice) {
        (bool ok, bytes memory ret) = address(doppiLP).call(abi.encodeWithSignature("hedgeSwap(uint256,uint256,bool)", amount, price, isBuy));
        require(ok, "hedgeSwap failed");
        (out, hedgePrice) = abi.decode(ret, (uint256, uint256));
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
        require(opportunityBots[msg.sender], "only opportunityBot");
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

    modifier whenOpen() {
        require(publicOpen == true, "not open");
        _;
    }

    modifier whenEmergency() {
        require(emergencyMode, "Not in emergency mode");
        _;
    }
}