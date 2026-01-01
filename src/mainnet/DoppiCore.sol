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
    uint256 public upperBound;
    uint256 public lowerBound;
    
    event Deposited(address indexed trader, uint64 positionId, address asset, uint256 amount, uint256 interest, uint256 strikePrice, uint32 apr, uint32 numDays);
    event Settled(address indexed trader, uint64 positionId, bool striked, bool isProfit, uint256 profitLoss, uint256 payout, uint256 interest, address profitToken, address payoutToken, address interestToken);
    event HedgeSettled(address indexed trader, uint64 positionId, bool isProfit, uint256 profitLoss, address profitToken);
    event EmergencyWithdraw(bool isBuy, address indexed trader, uint64 positionId, uint256 amount);
    event OppPerformed(bool isBuy, uint256 price, uint256 amount, uint256 amountOut);
    event OppUnwindPerformed(bool isBuy, uint256 price, uint256 swappedAmount, uint256 amountOut, uint256 profit, address profitToken);
    
    error InvalidStrikePriceOrPrice();
    error InvalidAPR();
    error InvalidAmount();
    error InvalidOfferLength();
    error PriceMismatch();
    error NotExpired();
    error NoPosition();
    error ExceedsPoolCap();

    constructor(address _assetA, address _assetB, IDoppiLiquidity _doppiLP, IDoppiOffer _doppiOffer, address _doppiPoints)
        Ownable(msg.sender)
    {
        assetA = IERC20(_assetA);
        assetB = IERC20(_assetB);
        doppiLP = _doppiLP;
        doppiOffer = _doppiOffer;
        priceDecimal = 10 ** _doppiLP.getPriceDecimals();
        doppiPoints = IDoppiPoints(_doppiPoints);
        opportunityBots[msg.sender] = true;
        assetA.safeIncreaseAllowance(address(doppiLP), type(uint256).max);
        assetB.safeIncreaseAllowance(address(doppiLP), type(uint256).max);

        uint256 price = doppiLP.getPrice();
        lowerBound = price;
        upperBound = price;
    }

    // Single deposit functionality
    function deposit_buy(DepositParams calldata params) 
        external nonReentrant whenNotPaused whenOpen {
        
        require(!emergencyMode, "Emergency mode active");
        if(params.amount < minOrderA) revert InvalidAmount(); 
        if (!canAcceptDeposit(true, params.amount)) {
            revert ExceedsPoolCap();
        }
        DualAssetOffer memory buyOffer = doppiOffer.getOffer(true, params.numDays, params.strikeZone);
        if(buyOffer.strikePrice != params.strikePrice || buyOffer.price == 0) revert InvalidStrikePriceOrPrice();
        if(!_isAPRWithinTolerance(buyOffer.apr, params.apr)) revert InvalidAPR();
        _depositBuy(params, buyOffer, true);

        if(buyOffer.strikePrice > upperBound){
            upperBound = buyOffer.strikePrice;
        }else if (buyOffer.strikePrice < lowerBound || lowerBound == 0){
            lowerBound = buyOffer.strikePrice;
        }
    }

    function deposit_sell(DepositParams calldata params) 
        external nonReentrant whenNotPaused whenOpen {
        
        require(!emergencyMode, "Emergency mode active");
        if(params.amount < minOrderB) revert InvalidAmount(); 
        if (!canAcceptDeposit(false, params.amount)) {
            revert ExceedsPoolCap();
        }
        DualAssetOffer memory sellOffer = doppiOffer.getOffer(false, params.numDays, params.strikeZone);
        if(sellOffer.strikePrice != params.strikePrice) revert InvalidStrikePriceOrPrice();
        if(!_isAPRWithinTolerance(sellOffer.apr, params.apr)) revert InvalidAPR();
        _depositSell(params, sellOffer, true);
        if(sellOffer.strikePrice > upperBound){
            upperBound = sellOffer.strikePrice;
        }else if (sellOffer.strikePrice < lowerBound || lowerBound == 0){
            lowerBound = sellOffer.strikePrice;
        }
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

    function getReadyBuyPositions() public view returns (uint256[] memory) {
        uint256 count = 0;
        uint256 length = buyPositionKeys.length;
        length = length > CHECKUPKEEPS_PER_ROUND ? CHECKUPKEEPS_PER_ROUND : length;

        for (uint256 i = 0; i < length; ) {
            if (positions_buy[buyPositionKeys[i].positionId].expiryTimestamp <= block.timestamp) {
                count++;
            }
            unchecked { ++i; }
        }
        
        uint256[] memory readyIndexes = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            if (positions_buy[buyPositionKeys[index].positionId].expiryTimestamp <= block.timestamp) {
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
        length = length > CHECKUPKEEPS_PER_ROUND ? CHECKUPKEEPS_PER_ROUND : length;
        for (uint256 i = 0; i < length; ) {
            if (positions_sell[sellPositionKeys[i].positionId].expiryTimestamp <= block.timestamp) {
                count++;
            }
            unchecked { ++i; }
        }
        
        uint256[] memory readyIndexes = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = length; i > 0; ) {
            uint256 index = i - 1;
            if (positions_sell[sellPositionKeys[index].positionId].expiryTimestamp <= block.timestamp) {
                readyIndexes[idx] = index;
                idx++;
            }
            unchecked { --i; }
        }
        return readyIndexes;
    }

    function getDoppiOffer() external view returns (address){
        return address(doppiOffer);
    } 

    // Internal functions
    function _updateInterestLiability(uint256 interest, bool isBuy) internal {
        if (isBuy) {
            totalInterestLiabilityA += interest;
        } else {
            totalInterestLiabilityB += interest;
        }
    }

    function _removeInterestLiability(uint256 interest, bool isBuy) internal {
        if (isBuy) {
            if (totalInterestLiabilityA >= interest) {
                totalInterestLiabilityA -= interest;
            } else {
                totalInterestLiabilityA = 0;
            }
        } else {
            if (totalInterestLiabilityB >= interest) {
                totalInterestLiabilityB -= interest;
            } else {
                totalInterestLiabilityB = 0;
            }
        }
    }

    function _updateTotalDeposit(uint256 amount, bool isBuy) internal {
        if (isBuy) {
            totalBuyDeposits = totalBuyDeposits >= amount ? totalBuyDeposits - amount : 0;
        } else {
            totalSellDeposits = totalSellDeposits >= amount ? totalSellDeposits - amount : 0;
        }
    }


    function _isAPRWithinTolerance(uint256 offerAPR, uint256 providedAPR) internal view returns (bool) {
        
        if (offerAPR == 0) return false;
        if (offerAPR == providedAPR) return true;
        uint256 deviation = providedAPR > offerAPR ? providedAPR - offerAPR : offerAPR - providedAPR;
        uint256 maxAllowedDeviation = (offerAPR * aprToleranceBP) / 10000;
        
        return deviation <= maxAllowedDeviation;
    }

    function _emergencyWithdrawSells() internal {
        
        uint256 initialLength = sellPositionKeys.length;
        for (uint256 i = initialLength; i > 0; ) {
            uint256 index = i - 1;

            if (index < sellPositionKeys.length) {
                KeyPosition memory keyPos = sellPositionKeys[index];
            
                if (keyPos.owner == msg.sender) {
                    DualAssetPosition storage pos = positions_sell[keyPos.positionId];
                    
                    if (pos.amount > 0) {
                        uint256 amountToReturn = pos.amount;
                        uint256 interest = pos.interest;
                        _updateTotalDeposit(amountToReturn, false);
                        _removeInterestLiability(interest, false);
                        _removePosition(index, keyPos, false); // for sells
                        assetB.safeTransfer(keyPos.owner, amountToReturn);
                        emit EmergencyWithdraw(false, keyPos.owner, keyPos.positionId, amountToReturn);
                    }
                }
            }
            unchecked { --i; }
        }
    }

    function _emergencyWithdrawBuys() internal {

        uint256 initialLength = buyPositionKeys.length;
        for (uint256 i = initialLength; i > 0; ) {
            uint256 index = i - 1;

            if (index < buyPositionKeys.length) {
                KeyPosition memory keyPos = buyPositionKeys[index];
            
                if (keyPos.owner == msg.sender) {
                    DualAssetPosition storage pos = positions_buy[keyPos.positionId];
                    
                    if (pos.amount > 0) {
                        uint256 amountToReturn = pos.amount;
                        uint256 interest = pos.interest;
                        // Update total deposits (prevent underflow)
                        _updateTotalDeposit(amountToReturn, true);
                        _removeInterestLiability(interest, true);
                        _removePosition(index, keyPos, true);  // for buys
                        assetA.safeTransfer(keyPos.owner, amountToReturn);
                        emit EmergencyWithdraw(true, keyPos.owner, keyPos.positionId, amountToReturn);
                    }
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
        
        // Early return - avoid any processing
        if (totalUpkeeps <= UPKEEPS_PER_CHECK) {
            return indexes;
        }
        
        // Only create ONE new array for processing
        toProcessIndexes = new uint256[](UPKEEPS_PER_CHECK);
        
        // Single loop to fill processing array
        for (uint256 i = 0; i < UPKEEPS_PER_CHECK; ) {
            toProcessIndexes[i] = indexes[i];
            unchecked { ++i;}
        }
        
        // Create remaining array directly
        uint256 remaining = totalUpkeeps - UPKEEPS_PER_CHECK;
        uint256[] memory remainIndexes = new uint256[](remaining);
        
        for (uint256 i = 0; i < remaining; ) {
            remainIndexes[i] = indexes[UPKEEPS_PER_CHECK + i];
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
        uint256 payout = (amount * priceDecimal) / _buyOffer.strikePrice;
        positions_buy[positionId] = DualAssetPosition(
            amount,
            _buyOffer.price,
            _buyOffer.strikePrice,
            _buyOffer.expiry,
            _buyOffer.apr,
            sender,
            interest,
            hedgeAmountInAssetB,
            swappedHedgeAmount,
            hedgePrice,
            payout
        );

        buyPositionKeys.push(KeyPosition(sender, positionId));
        opportunityBuy[_buyOffer.strikePrice].amount += amount;
        // Update interest liability
        _updateInterestLiability(interest, true);
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
        uint256 payout = (amount * _sellOffer.strikePrice) / priceDecimal;
        positions_sell[positionId] = DualAssetPosition(
            amount,
            _sellOffer.price,
            _sellOffer.strikePrice,
            _sellOffer.expiry,
            _sellOffer.apr,
            sender,
            interest,
            hedgeAmountInAssetA,
            swappedHedgeAmount,
            hedgePrice,
            payout
        );
        sellPositionKeys.push(KeyPosition(sender, positionId));
        opportunitySell[_sellOffer.strikePrice].amount += amount;

        _updateInterestLiability(interest, false);
        emit Deposited(sender, positionId, address(assetB), amount, interest, _sellOffer.strikePrice, _sellOffer.apr, numDays);
    }

    function _settlePosition(
        KeyPosition memory position,
        bool isBuy,
        uint256 price
    ) internal {
        
        DualAssetPosition memory p = isBuy ? positions_buy[position.positionId] : positions_sell[position.positionId];
        if(p.expiryTimestamp > block.timestamp) revert NotExpired();
        uint256 payout = p.payout;
        
        _removeInterestLiability(p.interest, isBuy);
        _updateTotalDeposit(p.amount, isBuy);

        SettlementResult memory result;
        bool isInTheMoney = isBuy ? (price <= p.strikePrice) : (price >= p.strikePrice);
        if (isInTheMoney) {
            result = _settleStrike(p, price, isBuy);
            _createTraderBotUnwindPosition(p, isBuy);
        } else {
            result = _settleNoStrike(p, price, isBuy);
            payout = 0;
        }

        // get interest from LP and unwind hedging
        (uint256 hedgeOut, ) = _doppiInterestUnwindHedge(IERC20(result.interestToken), p.interest, p.swappedHedgeAmount, price, isBuy);
        if(hedgeOut > 0){
            _recordHedgeSwap(p, hedgeOut, isBuy, position.positionId);
        }
        
        if (p.interest > 0) {
            _safeTransferWithFee(IERC20(result.interestToken), p.owner, p.interest);
        }
        // record for points
        if(!doppiPoints.paused()){
            uint256 tradeVolume = isBuy ? p.amount : (p.amount * price) / priceDecimal; 
            _recordTradePoints(position.owner, tradeVolume);
        }
        
        emit Settled(
            p.owner,
            position.positionId,
            payout > 0, // in-the-money if payout > 0
            result.isProfit,
            result.profitLoss,
            payout,
            p.interest,
            result.profitToken,
            result.payoutToken,
            result.interestToken
        );
    }

    function _createTraderBotUnwindPosition(DualAssetPosition memory p, bool isBuy) internal {
        
        if (
            address(doppiTraderFactory) != address(0) &&
            doppiTraderFactory.isTraderBot(p.owner)
        ) {
            IDoppiTrader(p.owner).createUnwindPosition(
                p.payout,
                p.strikePrice,
                isBuy
            );
        }
    }
    
    function _removePosition(uint256 index, KeyPosition memory _pos, bool isBuy) internal {
        // Delete from storage mapping
        if (isBuy) {
            delete positions_buy[_pos.positionId];
        } else {
            delete positions_sell[_pos.positionId];
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
    function _settleStrike(
        DualAssetPosition memory p,
        uint256 _price,
        bool _isBuy
    ) internal returns (SettlementResult memory result) {
        
        (IERC20 profitToken, IERC20 payoutToken, IERC20 interestToken) = _isBuy
            ? (assetB, assetB, assetA)
            : (assetA, assetA, assetB);

        mapping(uint256 => OpportunityOrders) storage opporMap = _isBuy ? opportunityBuy : opportunitySell; 
        uint256 amount = opporMap[p.strikePrice].amount;
        uint256 swappedAmount = opporMap[p.strikePrice].swappedAmount;
        uint256 unTradeAmount = amount - swappedAmount;
        
        uint256 amountOut = _isBuy ? (p.amount * priceDecimal) / _price : (p.amount * _price) / priceDecimal;
        
        // not traded case
        if(unTradeAmount >= p.amount){
            _doppiSettleCall(p.amount, amountOut, _price, _isBuy);
            payoutToken.safeTransfer(p.owner, p.payout);
            uint256 settleprofit = amountOut > p.payout ? amountOut - p.payout : 0;
            if (settleprofit > 0) {
                _safeTransferWithFee(payoutToken, address(doppiLP), settleprofit);
            }
        // traded case
        }else{
            payoutToken.safeTransfer(p.owner, p.payout);
            uint256 ratio = p.amount * 1e18 / swappedAmount;
            uint256 myamountOut = opporMap[p.strikePrice].outAmount * ratio / 1e18;
            if (myamountOut >= p.payout) {
                unchecked {
                    result.profitLoss = myamountOut - p.payout; 
                }
                result.isProfit = true;
                _safeTransferWithFee(profitToken, address(doppiLP), result.profitLoss);
                opporMap[p.strikePrice].outAmount -= myamountOut;
                opporMap[p.strikePrice].swappedAmount -= swappedAmount;
            }
        }
        
        result.payoutToken = address(payoutToken);
        result.interestToken = address(interestToken);
        result.profitToken = address(profitToken);
        return result;
    }

    function _settleNoStrike(
        DualAssetPosition memory p,
        uint256 _price,
        bool _isBuy
    ) internal returns (SettlementResult memory result) {
        
        mapping(uint256 => OpportunityOrders) storage opporMap = _isBuy ? opportunityBuy : opportunitySell; 
        uint256 amount = opporMap[p.strikePrice].amount;
        uint256 swappedAmount = opporMap[p.strikePrice].swappedAmount;
        uint256 unTradeAmount = amount - swappedAmount;

        // Pick settle/payout tokens based on trade direction
        IERC20 payoutToken = _isBuy ? assetA : assetB;

        if(unTradeAmount >= p.amount){
            payoutToken.safeTransfer(p.owner, p.amount);
        }else{
            uint256 ratio = p.amount * 1e18 / swappedAmount;
            uint256 amountOut = opporMap[p.strikePrice].outAmount * ratio / 1e18;
            // Perform settlement
            uint256 amountInOrig = _swapLowLevel(amountOut, _price, !_isBuy);             
            payoutToken.safeTransfer(p.owner, p.amount);
            // Profit calculation
            if (amountInOrig >= p.amount) {
                unchecked {
                    result.profitLoss = amountInOrig - p.amount; 
                }
                result.isProfit = true;
                _safeTransferWithFee(payoutToken, address(doppiLP), result.profitLoss);
            }
            opporMap[p.strikePrice].outAmount -= amountOut;
            opporMap[p.strikePrice].swappedAmount -= swappedAmount;
        }
        
        result.profitToken = address(payoutToken);
        result.payoutToken = address(payoutToken);
        result.interestToken = address(payoutToken);
        return result;
    }

    function _recordHedgeSwap(DualAssetPosition memory p, uint256 hedgeOut, bool isBuy, uint64 _positionId) internal {
        
        if (p.swappedHedgeAmount == 0) return;        
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

    function _settle_positions(uint256[] memory _indexes, bool isBuy, uint256 _settlePrice) internal {
        uint256 length = _indexes.length;
        require(length > 0, "empty array");
        require(_isDescending(_indexes), "not descending");
        
        uint256 poslength = isBuy ? buyPositionKeys.length : sellPositionKeys.length;
        for (uint256 i = 0; i < length; ) {
            uint256 idx = _indexes[i];
            require(idx < poslength, "index out of bounds");
            KeyPosition memory pos = isBuy ? buyPositionKeys[idx] : sellPositionKeys[idx];
            _settlePosition(pos, isBuy, _settlePrice);
            isBuy ? _removePosition(idx, pos, true) : _removePosition(idx, pos, false);

            unchecked { ++i; }
        }
    }

    function _checkOppoOrUnwind(
        bool _isBuy,
        uint256 price, 
        uint256 oneDayMove,
        bool _unwind
    ) internal view returns (uint256[] memory targetPrices, uint256[] memory totalAmount) 
    {
        mapping(uint256 => OpportunityOrders) storage opporMap = _isBuy ? opportunityBuy : opportunitySell; 
        
        bool direction = (_isBuy && _unwind) || (!_isBuy && !_unwind);

        uint256 round = _getLoopRound(price, direction);
        uint256[] memory tempTargetPrice = new uint256[](round);
        uint256[] memory tempTotalAmount = new uint256[](round);
        
        uint256 count = 0;
        uint256 buffer = price * oneDayMove / 10000;
        uint256 triggerPrice = _isBuy ? price + buffer : price - buffer;
        uint256 triggerUnwindPrice = _isBuy ? price - buffer : price + buffer;
        // uint256 maxSwapInLocal = isBuy ? config.maxSwap : config.maxSwap * config.decimals / currentPrice;
        
        for (uint256 i = round; i > 0; ) {
            uint256 strikeprice = _getTargetPrice(price, uint8(i), direction);
            
            if(_unwind){
                
                uint256 outAmount = opporMap[strikeprice].outAmount;
                uint256 unwindSwappedAmount = opporMap[strikeprice].swappedAmount;

                if(outAmount > 0){
                    uint256 costPrice = _isBuy ? unwindSwappedAmount * priceDecimal / outAmount : outAmount * priceDecimal / unwindSwappedAmount;
                    bool shouldUnwind = _isBuy ? costPrice < triggerUnwindPrice : costPrice > triggerUnwindPrice;
                    
                    if (shouldUnwind) {
                        tempTargetPrice[count] = strikeprice;
                        tempTotalAmount[count] = outAmount;
                        count++;
                    }
                }
            }else{
                uint256 unTradeAmount = opporMap[strikeprice].amount - opporMap[strikeprice].swappedAmount;
                bool isTriggered = _isBuy ? (unTradeAmount > 0) && strikeprice > triggerPrice : (unTradeAmount > 0) && strikeprice < triggerPrice;
                if(isTriggered){
                    tempTotalAmount[count] = unTradeAmount;                
                    tempTargetPrice[count] = strikeprice;
                    count++;
                }
            }
            unchecked { --i; }   
        }

        return _createResultArrays(tempTargetPrice, tempTotalAmount, count);
    }


    function checkOpportunity(uint256 price, bool _isBuy) external view
        returns (
            uint256[] memory targetPrices, 
            uint256[] memory targetPricesUnwind, 
            uint256[] memory totalAmount,
            uint256[] memory totalAmountUnwind
        ) {
        
        uint256 oneDayMove = doppiOffer.getOneDayBuffer(price, _isBuy);
        (targetPrices, totalAmount) = _checkOppoOrUnwind(_isBuy, price, oneDayMove, false);
        (targetPricesUnwind, totalAmountUnwind) = _checkOppoOrUnwind(_isBuy, price, oneDayMove, true);
    }

    function performOpportunity(
        uint256[] memory targetPrices, 
        uint256[] memory targetPricesUnwind, 
        uint256[] memory totalAmount,
        uint256[] memory totalAmountUnwind,
        bool _isBuy
    ) external onlyOpportunityBot nonReentrant {
        
        uint256 price = _getPriceFromLP();
        mapping(uint256 => OpportunityOrders) storage opporMap = _isBuy ? opportunityBuy : opportunitySell; 

        for (uint256 j = 0; j < targetPrices.length; ) {
            _executeOpportunity(targetPrices[j], totalAmount[j], _isBuy, price, opporMap);
            unchecked { ++j; }
        }
        for (uint256 j = 0; j < targetPricesUnwind.length; ) {
            _executeUnwind(targetPricesUnwind[j], totalAmountUnwind[j], _isBuy, price, opporMap);
            unchecked { ++j; }
        }
    }


    function _createResultArrays(
        uint256[] memory tempPrices,
        uint256[] memory tempAmounts,
        uint256 count
    ) private pure returns (uint256[] memory prices, uint256[] memory amounts) {
        uint256 resultSize = count < tempPrices.length ? count : tempPrices.length;
        
        prices = new uint256[](resultSize);
        amounts = new uint256[](resultSize);
        
        // Reverse order while copying to final arrays
        for (uint256 i = 0; i < resultSize;) {
            prices[i] = tempPrices[resultSize - 1 - i];
            amounts[i] = tempAmounts[resultSize - 1 - i];
            unchecked { ++i; }
        }
    }

    function _getLoopRound(uint256 _price, bool unwind) internal view returns (uint256 round) {

        uint256 firstPrice = _getTargetPrice(_price, 1, unwind);
        uint256 priceGap = doppiOffer.getPriceGapPerOffer() * priceDecimal;
        
        uint256 diff = unwind 
            ? (firstPrice > lowerBound ? firstPrice - lowerBound : 0)
            : (upperBound > firstPrice ? upperBound - firstPrice : 0);

        round = diff / priceGap + 1;
    }

    function _executeOpportunity(
        uint256 targetPrice,
        uint256 amount,
        bool isBuy,
        uint256 currentPrice,
        mapping(uint256 => OpportunityOrders) storage opporMap
    ) internal {
        
        uint256 amountOut = _swapLowLevel(amount, currentPrice, isBuy);
        opporMap[targetPrice].outAmount += amountOut;
        opporMap[targetPrice].swappedAmount += amount;
        
        emit OppPerformed(isBuy, currentPrice, amount, amountOut);
    }

    function _executeUnwind(
        uint256 targetPrice,
        uint256 amount,
        bool isBuy,
        uint256 currentPrice,
        mapping(uint256 => OpportunityOrders) storage opporMap
    ) internal {
        uint256 swappedAmount = opporMap[targetPrice].swappedAmount;
        uint256 amountOut = _swapLowLevel(amount, currentPrice, !isBuy);
        
        // Clear the order
        opporMap[targetPrice].outAmount = 0;
        opporMap[targetPrice].swappedAmount = 0;
        
        // Calculate and transfer profit if any
        uint256 profit;
        IERC20 profitToken = isBuy ? assetA : assetB;
        if (amountOut > swappedAmount) {
            profit = amountOut - swappedAmount;
            _safeTransferWithFee(profitToken, address(doppiLP), profit);
        }
        emit OppUnwindPerformed(isBuy, currentPrice, amount, amountOut, profit, address(profitToken));
    }

    function _getTargetPrice(uint256 _price, uint8 _zone, bool _isBuy) internal view returns (uint256) {
        uint256 priceGapWithDecimals = doppiOffer.getPriceGapPerOffer() * priceDecimal;
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * (_zone - 1)) : _price + (priceGapWithDecimals * _zone);
    }

    function _safeTransferWithFee(IERC20 _asset, address _to, uint256 _amount) internal {
        
        uint256 amountFee = _amount * treasury_fee / 10000;
        uint256 amountAfterFee = _amount - amountFee;
        _asset.safeTransfer(_to, amountAfterFee);
        _asset.safeTransfer(treasury, amountFee);

    }
    
    // Helpers interacting via low-level calls (to avoid interface in module)
    function _recordTradePoints(address trader, uint256 volume) internal {
        (bool ok,) = address(doppiPoints).call(abi.encodeWithSignature("recordTrade(address,uint256)", trader, volume));
        require(ok, "record point failed");
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

    function _doppiSettleCall(uint256 amount, uint256 payout, uint256 price, bool isBuy) internal returns (uint256 out) {
        (bool ok, bytes memory ret) = address(doppiLP).call(abi.encodeWithSignature("settle(uint256,uint256,uint256,bool)", amount, payout, price, isBuy));
        require(ok, "settle failed");
        out = abi.decode(ret, (uint256));
    }

    function _doppiInterestUnwindHedge(
            IERC20 interestToken,
            uint256 interest,
            uint256 unhedged,
            uint256 price,
            bool isBuy
        ) internal returns (uint256 hedgeOut, uint256 hedgeTradedPrice) {
        (bool ok, bytes memory ret) = address(doppiLP).call(abi.encodeWithSignature("interestUnwindHedge(address,uint256,uint256,uint256,bool)", address(interestToken), interest, unhedged, price, isBuy));
        require(ok, "interestUnwindHedge failed");
        (hedgeOut, hedgeTradedPrice) = abi.decode(ret, (uint256, uint256));
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