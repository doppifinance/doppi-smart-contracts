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
    event OppPerformed(bool isBuy, address indexed trader, uint256 price, uint256 amount, uint256 amountOut);
    event OppUnwindPerformed(bool isBuy, address indexed trader, uint256 price, uint256 swappedAmount, uint256 amountOut, uint256 profit, address profitToken);
    
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
            0,
            false,
            interest,
            hedgeAmountInAssetB,
            swappedHedgeAmount,
            hedgePrice,
            payout
        );

        buyPositionKeys.push(KeyPosition(sender, positionId));
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
            0,
            false,
            interest,
            hedgeAmountInAssetA,
            swappedHedgeAmount,
            hedgePrice,
            payout
        );
        sellPositionKeys.push(KeyPosition(sender, positionId));
        _updateInterestLiability(interest, false);
        emit Deposited(sender, positionId, address(assetB), amount, interest, _sellOffer.strikePrice, _sellOffer.apr, numDays);
    }

    function _settlePosition(
        KeyPosition memory position,
        bool isBuy,
        uint256 price
    ) internal {
        
        DualAssetPosition memory p = isBuy
            ? positions_buy[position.positionId]
            : positions_sell[position.positionId];

        if(p.expiryTimestamp > block.timestamp) revert NotExpired();

        uint256 payout = p.payout;
        
        _removeInterestLiability(p.interest, isBuy);
        _updateTotalDeposit(p.amount, isBuy);

        SettlementResult memory result;
        bool isInTheMoney = isBuy ? (price <= p.strikePrice) : (price >= p.strikePrice);
        if (isInTheMoney) {
            result = p.isTraded ? _settleStrikeTraded(p, isBuy) : _settleStrikeNoTraded(p, price, isBuy);
            _createTraderBotUnwindPosition(p, isBuy);
            
        } else {
            result = p.isTraded ? _settleNoStrikeTraded(p, price, isBuy) : _settleNoStrikeNoTraded(p, isBuy);
            payout = 0;
        }
        // get interest from LP and unwind hedging
        (uint256 hedgeOut, ) = _doppiInterestUnwindHedge(IERC20(result.interestToken), p.interest, p.swappedHedgeAmount, price, isBuy);
        
        if (p.interest > 0) {
            _safeTransferWithFee(IERC20(result.interestToken), p.owner, p.interest);
        }
        // update Hedge unwind settlement
        if(hedgeOut > 0){
            _recordHedgeSwap(p, hedgeOut, isBuy, position.positionId);
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
    function _settleStrikeNoTraded(
        DualAssetPosition memory p,
        uint256 _price,
        bool _isBuy
    ) internal returns (SettlementResult memory result) {
        (IERC20 payoutToken_, IERC20 interestToken_) = _isBuy ? (assetB, assetA): (assetA, assetB);

        uint256 amountOut = _isBuy
            ? (p.amount * priceDecimal) / _price
            : (p.amount * _price) / priceDecimal;
        _doppiSettleCall(p.amount, amountOut, _price, _isBuy);
        payoutToken_.safeTransfer(p.owner, p.payout);
        uint256 settleprofit = amountOut > p.payout ? amountOut - p.payout : 0;
        if (settleprofit > 0) {
            _safeTransferWithFee(payoutToken_, address(doppiLP), settleprofit);
        }

        result.payoutToken = address(payoutToken_);
        result.interestToken = address(interestToken_);
        result.profitToken = address(payoutToken_);
        return result;
    }


    function _settleStrikeTraded(
        DualAssetPosition memory p,
        bool _isBuy
    ) internal returns (SettlementResult memory result) {
        
        (IERC20 profitToken, IERC20 payoutToken, IERC20 interestToken) = _isBuy
            ? (assetB, assetB, assetA)
            : (assetA, assetA, assetB);

        // Payout
        payoutToken.safeTransfer(p.owner, p.payout);
        if (p.swappedAmount >= p.payout) {
            unchecked {
                result.profitLoss = p.swappedAmount - p.payout; 
            }
            result.isProfit = true;
            _safeTransferWithFee(profitToken, address(doppiLP), result.profitLoss);
        }

        result.profitToken = address(profitToken);
        result.payoutToken = address(payoutToken);
        result.interestToken = address(interestToken);
        return result;
    }


    function _settleNoStrikeTraded(
        DualAssetPosition memory p,
        uint256 _price,
        bool _isBuy
    ) internal returns (SettlementResult memory result) {
        // Pick settle/payout tokens based on trade direction
        IERC20 payoutToken = _isBuy ? assetA : assetB;
        // Perform settlement
        uint256 amountOut = _swapLowLevel(p.swappedAmount, _price, !_isBuy); 
        // Profit calculation
        if (amountOut >= p.amount) {
            unchecked {
                result.profitLoss = amountOut - p.amount; 
            }
            result.isProfit = true;
            _safeTransferWithFee(payoutToken, address(doppiLP), result.profitLoss);
        }

        result.profitToken = address(payoutToken);
        result.payoutToken = address(payoutToken);
        result.interestToken = address(payoutToken);
        return result;
    }


    function _settleNoStrikeNoTraded(
        DualAssetPosition memory p,
        bool _isBuy
    ) internal returns (SettlementResult memory result) {
        IERC20 payoutToken = _isBuy ? assetA : assetB;
        // Transfer principal
        payoutToken.safeTransfer(p.owner, p.amount);
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

    function checkOpportunity(uint256 price, bool _isBuy) external view
        returns (uint256 count, uint256[] memory indexes) {
        
        uint256 oneDayMove = doppiOffer.getOneDayBuffer(price, _isBuy);
        uint256 length = _isBuy ? buyPositionKeys.length : sellPositionKeys.length; 
        if(length == 0) return (count, indexes);
        
        indexes = new uint256[](UPKEEPS_PER_CHECK);
        count = 0;
        for (uint256 i = 0; i < length && count < UPKEEPS_PER_CHECK; ) {

            DualAssetPosition memory p = _isBuy
                ? positions_buy[buyPositionKeys[i].positionId]
                : positions_sell[sellPositionKeys[i].positionId];

            uint256 buffer = p.strikePrice * oneDayMove / 10000;
            
            if (_isBuy) {
                uint256 triggerPrice = p.strikePrice - buffer;
                if ((!p.isTraded && price <= triggerPrice) || (p.isTraded && price >= p.strikePrice)) {
                    indexes[count] = i;
                    count++;
                }
            } else {
                uint256 triggerPrice = p.strikePrice + buffer;
                if ((!p.isTraded && price >= triggerPrice) || (p.isTraded && price <= p.strikePrice)) {
                    indexes[count] = i;
                    count++;
                }
            }
            unchecked { ++i; }
        }
        // If we found fewer than max, trim the array
        if (count < UPKEEPS_PER_CHECK) {
            uint256[] memory trimmed = new uint256[](count);
            for (uint256 j = 0; j < count; j++) {
                trimmed[j] = indexes[j];
            }
            return (count, trimmed);
        }
        return (count, indexes);
    }

    function performOpportunity(
        uint256 price,
        uint256[] memory _indexes,
        bool _isBuy
    ) external onlyOpportunityBot nonReentrant {
        
        uint256 oneDayMove = doppiOffer.getOneDayBuffer(price, _isBuy);
        
        uint256 length = _isBuy ? buyPositionKeys.length : sellPositionKeys.length; 
        for (uint256 j = 0; j < _indexes.length; ) {
            uint256 i = _indexes[j];
            if (i < length) {
                
                DualAssetPosition storage p = _isBuy
                    ? positions_buy[buyPositionKeys[i].positionId]
                    : positions_sell[sellPositionKeys[i].positionId];
                
                uint256 bufferUnwind = p.strikePrice * tolerance / 10000;
                uint256 buffer = p.strikePrice * oneDayMove / 10000;
                    
                if (_isNotTradedTriggered(_isBuy, p, price, buffer)) {

                    uint256 amountOut = _swapLowLevel(p.amount, price, _isBuy);
                    p.isTraded = true;
                    p.swappedAmount = amountOut;
                    emit OppPerformed(_isBuy, p.owner, price, p.amount, amountOut);
                } else if (_isTradedTriggered(_isBuy, p, price, bufferUnwind)) {
                    
                    uint256 swappedAmount = p.swappedAmount;
                    uint256 amountOut = _swapLowLevel(swappedAmount, price, !_isBuy);
                    p.isTraded = false;
                    p.swappedAmount = 0;
                    uint256 profit = amountOut - p.amount;
                    _safeTransferWithFee(_isBuy ? assetA : assetB, address(doppiLP), profit);
                    emit OppUnwindPerformed(_isBuy, p.owner, price, swappedAmount, amountOut, profit, _isBuy ? address(assetA): address(assetB));
                }
            }
            unchecked { ++j; }
        }
    }

    function _isNotTradedTriggered(
        bool _isBuy,
        DualAssetPosition memory _order,
        uint256 _price,
        uint256 _buffer
    ) internal pure returns (bool) {
        if (_isBuy) {
            uint256 triggerPrice = _order.strikePrice + _buffer;
            return !_order.isTraded && _price <= triggerPrice;
        } else {
            uint256 triggerPrice = _order.strikePrice - _buffer;
            return !_order.isTraded && _price >= triggerPrice;
        }
    }

    function _isTradedTriggered(
        bool _isBuy,
        DualAssetPosition memory _order,
        uint256 _price,
        uint256 _buffer
    ) internal pure returns (bool) {
        if (_isBuy) {
            uint256 triggerPrice = _order.strikePrice + _buffer;
            return _order.isTraded && _price >= triggerPrice;
        } else {
            return _order.isTraded && _price <= _order.strikePrice;
        }
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