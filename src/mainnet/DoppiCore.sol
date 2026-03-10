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

    bytes4 constant SWAP_SELECTOR = bytes4(keccak256("swap(uint256,uint256,bool)"));
    bytes4 constant PRICE_SELECTOR = bytes4(keccak256("getPrice()"));
    bytes4 constant SETTLE_SELECTOR = bytes4(keccak256("settle(uint256,uint256,uint256,bool)"));
    bytes4 constant INTEREST_SELECTOR = bytes4(keccak256("interestGet(address,uint256,uint256,bool)"));
    bytes4 constant RECORD_SELECTOR = bytes4(keccak256("recordTrade(address,uint256)"));

    IERC20 public immutable assetA; // Made immutable
    IERC20 public immutable assetB; // Made immutable
    IDoppiOffer public immutable doppiOffer; // Made immutable
    IDoppiPoints public immutable doppiPoints;

    uint256 public priceDecimal;
    uint32 private constant SECONDS_PER_YEAR = 31536000;
    uint24 private constant SECONDS_PER_DAY = 86400;
    uint16 private constant BASIS_POINTS = 10000;
    uint256 public upperBound;
    uint256 public lowerBound;
    
    event Deposited(address indexed trader, uint64 positionId, address asset, uint256 amount, uint256 interest, uint256 strikePrice, uint32 apr, uint8 numDays);
    event Settled(address indexed trader, uint64 positionId, bool striked, uint256 strikePrice, uint256 marketPrice, bool isProfit, uint256 profitLoss, uint256 payout, uint256 interest, address payoutToken, address interestToken);
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
    error SwapFailed();
    error PriceFailed();
    error SettleFailed();
    error InterestGetFailed();
    error EmergencyModeActive();
    error RecordTradeFailed();
    error OnlyOpportunityBot();
    error OnlyForwarder();
    error OnlyTraderBot();
    error NotOpen();


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

        uint256 price = _getPriceFromLP();
        lowerBound = _getTargetPrice(price, 1, true);
        upperBound = _getTargetPrice(price, 1, false);
        supportDays.push(1);
        nextProcessId[1] = 1;
        nextPositionId = 1;
    }

    // Single deposit functionality
    function deposit_buy(DepositParams calldata params) 
        external nonReentrant whenNotPaused {
        
        _whenOpen();
        if (emergencyMode) revert EmergencyModeActive();
        if(params.amount < minOrderA) revert InvalidAmount(); 
        if (!canAcceptDeposit(true, params.amount)) {
            revert ExceedsPoolCap();
        }
        DualAssetOffer memory buyOffer = doppiOffer.getOffer(true, params.numDays, params.strikeZone);
        if(buyOffer.strikePrice != params.strikePrice || buyOffer.price == 0) revert InvalidStrikePriceOrPrice();
        if(!_isAPRWithinTolerance(buyOffer.apr, params.apr)) revert InvalidAPR();
        
        _depositBuy(params, buyOffer);
        _updateLowerUpperBound(buyOffer.strikePrice);
    }

    function deposit_sell(DepositParams calldata params) 
        external nonReentrant whenNotPaused {
        
        _whenOpen();
        if (emergencyMode) revert EmergencyModeActive();
        if(params.amount < minOrderB) revert InvalidAmount(); 
        if (!canAcceptDeposit(false, params.amount)) {
            revert ExceedsPoolCap();
        }
        DualAssetOffer memory sellOffer = doppiOffer.getOffer(false, params.numDays, params.strikeZone);
        if(sellOffer.strikePrice != params.strikePrice) revert InvalidStrikePriceOrPrice();
        if(!_isAPRWithinTolerance(sellOffer.apr, params.apr)) revert InvalidAPR();
        _depositSell(params, sellOffer);
        _updateLowerUpperBound(sellOffer.strikePrice);
    }

    function bulkDeposit(bool isBuy, DepositParams[] calldata params, DualAssetOffer[] memory _offers) external whenNotPaused {
        
        _onlyTraderBot();
        uint256 length = params.length;
        if(length != _offers.length) revert InvalidOfferLength();
        
        for (uint256 i = 0; i < length; ) {
            DepositParams calldata param = params[i];
            if(param.amount == 0) revert InvalidAmount();
            if(param.apr == 0) revert InvalidAPR();

            isBuy ? _depositBuy(param, _offers[i]) : _depositSell(param, _offers[i]);
            _updateLowerUpperBound(_offers[i].strikePrice);
            unchecked { ++i; }
        }
    }

    // Chainlink Keepers integration
    function checkUpkeep(bytes calldata) 
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        (uint64[] memory allPositions, SettleAccumulate memory settleAccu) = getReadyAllPositions();
        if (allPositions.length > 0 && !paused()) {
            return (true, abi.encode(allPositions, settleAccu)); 
        }        
        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external nonReentrant {
        
        _onlyForwarder();
        if(paused()) return;
        
        (uint64[] memory allPositions, SettleAccumulate memory settleAccu) = abi.decode(performData, (uint64[], SettleAccumulate));
        _processNewSettlements(allPositions, settleAccu);
    }

    function settleOrders(uint64[] memory allPositions, SettleAccumulate memory settleAccu) external nonReentrant onlyOwner {
        _processNewSettlements(allPositions, settleAccu);
    }

    function emergencyWithdraw() external whenPaused nonReentrant {
        
        if (!emergencyMode) revert EmergencyModeActive();
        _emergencyWithdrawAll();
    }

    function addSupportDay(uint8 _day) external onlyOwner {
        supportDays.push(_day);
    }

    function isEmergency() external view returns (bool){
        return emergencyMode;
    } 

    function getReadyAllPositions() public view 
        returns (
            uint64[] memory readyPositionId,
            SettleAccumulate memory settleAccu
        ) {
        
        uint64[] memory tempPositionId = new uint64[](UPKEEPS_PER_CHECK);
        uint256 idx = 0;
        
        for(uint8 x=0; x < supportDays.length; ) {
            uint8 day = supportDays[x];
            uint64 id = nextProcessId[day];
            uint64 end = id + uint64(UPKEEPS_PER_CHECK);
            
            for (uint64 posId = id; posId < end; ) {
                bool isBuy = positions_buy[day][posId].amount > 0;
                DualAssetPosition memory pos = isBuy ? positions_buy[day][posId] : positions_sell[day][posId];
                bool exist = _posExist(day, posId);
                if(exist) {
                    if (pos.expiryTimestamp <= block.timestamp) {
                        tempPositionId[idx] = posId;
                        if(isBuy){
                            settleAccu.totalInterestA += pos.interest;
                        }else {
                            settleAccu.totalInterestB += pos.interest;
                        }
                        idx++;
                    }else{
                        break;
                    }
                }
                unchecked { ++posId; }
            }
            unchecked { ++x; }
        }
        if(idx > 0) {
            uint256 resultSize = idx < UPKEEPS_PER_CHECK ? idx : UPKEEPS_PER_CHECK;
            readyPositionId = new uint64[](resultSize);
            for (uint64 i = 0; i < resultSize;) {
                readyPositionId[i] = tempPositionId[i];
                unchecked { ++i; }
            }
        }
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

    function _emergencyWithdrawAll() internal {

        
        for (uint8 x = 0; x < supportDays.length; ) {
            
            uint8 day = supportDays[x];
            uint64 length = getPositionLength(x);
            uint64 end = nextProcessId[day] + uint64(length);
            for (uint64 i = nextProcessId[day]; i < end; ) {
                bool exist = _posExist(day, i);
                if(exist) {
                    bool isBuy = positions_buy[day][i].amount > 0;
                    DualAssetPosition memory pos = positions_buy[day][i].amount > 0 ? positions_buy[day][i] : positions_sell[day][i];

                    if (pos.amount > 0) {
                        uint256 amountToReturn = pos.amount;
                        uint256 interest = pos.interest;
                        // Update total deposits (prevent underflow)
                        _updateTotalDeposit(amountToReturn, isBuy);
                        _removeInterestLiability(interest, isBuy);
                        if (isBuy) {
                            delete positions_buy[day][i];
                            assetA.safeTransfer(pos.owner, amountToReturn);
                        } else {
                            delete positions_sell[day][i];
                            assetB.safeTransfer(pos.owner, amountToReturn);
                        }
                        emit EmergencyWithdraw(isBuy, pos.owner, i, amountToReturn);
                    }
                }
                unchecked { ++i; }
            }
            unchecked { ++x; }  
        }
    }

    function _processNewSettlements(
        uint64[] memory allPositions,
        SettleAccumulate memory settleAccu
    ) internal {
        uint256 price = _getPriceFromLP();
        _batchProcess(allPositions, settleAccu, price);
        _settle_positions(allPositions, price);   
        _updateBound();     
    }

    function _depositBuy(DepositParams calldata params, DualAssetOffer memory _buyOffer) internal {
        uint256 amount = params.amount;
        uint8 numDays = params.numDays;
        address sender = msg.sender;

        assetA.safeTransferFrom(sender, address(this), amount);
        // Update total deposits
        totalBuyDeposits += amount;
        uint64 positionId = nextPositionId;
        unchecked { nextPositionId = positionId + 1; }

        // Calculate interest using precomputed values
        uint256 duration = SECONDS_PER_DAY * numDays;
        uint256 interest = (amount * _buyOffer.apr) / BASIS_POINTS;
        interest = (interest * duration) / SECONDS_PER_YEAR;
        uint256 payout = (amount * priceDecimal) / _buyOffer.strikePrice;
        positions_buy[numDays][positionId] = DualAssetPosition(
            amount,
            _buyOffer.price,
            _buyOffer.strikePrice,
            _buyOffer.expiry,
            _buyOffer.apr,
            sender,
            interest,
            payout
        );
        opportunityBuy[_buyOffer.strikePrice].amount += amount;
        _updateInterestLiability(interest, true);
        // record for points
        if(!doppiPoints.paused()){
            _recordTradePoints(sender, amount);
        }
        emit Deposited(sender, positionId, address(assetA), amount, interest, _buyOffer.strikePrice, _buyOffer.apr, numDays);
    }

    function _depositSell(DepositParams calldata params, DualAssetOffer memory _sellOffer) internal {
        
        uint256 amount = params.amount;
        uint8 numDays = params.numDays;
        address sender = msg.sender;

        assetB.safeTransferFrom(sender, address(this), params.amount);

        // Update total deposits
        totalSellDeposits += amount;

        uint64 positionId = nextPositionId;
        unchecked { nextPositionId = positionId + 1; }
        
        // Calculate interest using precomputed values
        uint256 duration = SECONDS_PER_DAY * numDays;
        uint256 interest = (amount * _sellOffer.apr) / BASIS_POINTS;
        interest = (interest * duration) / SECONDS_PER_YEAR;
        uint256 payout = (amount * _sellOffer.strikePrice) / priceDecimal;
        positions_sell[numDays][positionId] = DualAssetPosition(
            amount,
            _sellOffer.price,
            _sellOffer.strikePrice,
            _sellOffer.expiry,
            _sellOffer.apr,
            sender,
            interest,
            payout
        );
        opportunitySell[_sellOffer.strikePrice].amount += amount;

        _updateInterestLiability(interest, false);
        // record for points
        if(!doppiPoints.paused()){
            uint256 tradeVolume = (amount * _sellOffer.price) / priceDecimal; 
            _recordTradePoints(sender, tradeVolume);
        }
        emit Deposited(sender, positionId, address(assetB), amount, interest, _sellOffer.strikePrice, _sellOffer.apr, numDays);
    }

    function _settlePosition(
        uint8 day,
        uint64 posId,
        uint256 price,
        bool isBuy
    ) internal {
        
        bool isInTheMoney;
        DualAssetPosition memory p;
        
        if(positions_buy[day][posId].amount > 0){
            p = positions_buy[day][posId];
            delete positions_buy[day][posId];
            isInTheMoney = price <= p.strikePrice;
        }else{
            p = positions_sell[day][posId];
            delete positions_sell[day][posId];
            isInTheMoney = price >= p.strikePrice;
        }
        if(p.expiryTimestamp > block.timestamp) revert NotExpired();
        uint256 payout = p.payout;
        
        _removeInterestLiability(p.interest, isBuy);
        _updateTotalDeposit(p.amount, isBuy);

        IERC20 payoutToken;
        IERC20 interestToken;
        bool isProfit;
        uint256 profitLoss;
        
        if (isInTheMoney) {
            (payoutToken, interestToken) = isBuy ? (assetB, assetA) : (assetA, assetB);
            (isProfit, profitLoss) = _settleStrike(p, price, isBuy, payoutToken);
            _createTraderBotUnwindPosition(p, isBuy);

        } else {
            (payoutToken, interestToken)  = isBuy ? (assetA, assetA) : (assetB, assetB);
            _settleNoStrike(p, price, isBuy, payoutToken);
            payout = 0;
        }
        
        if (p.interest > 0) {
            _safeTransferWithFee(interestToken, p.owner, p.interest);
        }

        emit Settled(
            p.owner,
            posId,
            payout > 0, // in-the-money if payout > 0
            p.strikePrice,
            price,
            isProfit,
            profitLoss,
            payout,
            p.interest,
            address(payoutToken),
            address(interestToken)
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
    
    // Settlement helper functions
    function _settleStrike(
        DualAssetPosition memory p,
        uint256 _price,
        bool _isBuy,
        IERC20 payoutToken
    ) internal returns (bool isProfit, uint256 profitLoss) {
        
        mapping(uint256 => OpportunityOrders) storage opporMap = _isBuy ? opportunityBuy : opportunitySell; 
        OpportunityOrders storage order = opporMap[p.strikePrice];
        uint256 swappedAmount = order.swappedAmount;
        uint256 amountOut = _isBuy ? (p.amount * priceDecimal) / _price : (p.amount * _price) / priceDecimal;
        // not traded case
        if(!_isPosTraded(p.strikePrice, p.amount, _isBuy)){
            payoutToken.safeTransfer(p.owner, p.payout);
            uint256 settleprofit = amountOut > p.payout ? amountOut - p.payout : 0;
            if (settleprofit > 0) {
                _safeTransferWithFee(payoutToken, address(doppiLP), settleprofit);
            }
        // traded case
        }else{
            payoutToken.safeTransfer(p.owner, p.payout);
            uint256 ratio = p.amount * 1e18 / swappedAmount;
            uint256 myamountOut = order.outAmount * ratio / 1e18;
            if (myamountOut >= p.payout) {
                unchecked {
                    profitLoss = myamountOut - p.payout; 
                }
                isProfit = true;
                _safeTransferWithFee(payoutToken, address(doppiLP), profitLoss);

                order.outAmount = order.outAmount > myamountOut ? order.outAmount - myamountOut : 0;
                order.swappedAmount = order.swappedAmount > swappedAmount ? order.swappedAmount - swappedAmount : 0;
            }
        } 
        if(p.amount >= order.amount){
            delete opporMap[p.strikePrice];
        }else{
            order.amount -= p.amount;
        }       
    }

    function _settleNoStrike(
        DualAssetPosition memory p,
        uint256 _price,
        bool _isBuy,
        IERC20 payoutToken
    ) internal returns (bool isProfit, uint256 profitLoss) {
        
        mapping(uint256 => OpportunityOrders) storage opporMap = _isBuy ? opportunityBuy : opportunitySell; 
        OpportunityOrders storage order = opporMap[p.strikePrice];
        uint256 swappedAmount = order.swappedAmount;

        if(!_isPosTraded(p.strikePrice, p.amount, _isBuy)){
            payoutToken.safeTransfer(p.owner, p.amount);
        }else{
            uint256 ratio = p.amount * 1e18 / swappedAmount;
            uint256 amountOut = order.outAmount * ratio / 1e18;
            // Perform settlement
            uint256 amountInOrig = _swapLowLevel(amountOut, _price, !_isBuy);             
            payoutToken.safeTransfer(p.owner, p.amount);
            // Profit calculation
            if (amountInOrig >= p.amount) {
                unchecked {
                    profitLoss = amountInOrig - p.amount; 
                }
                isProfit = true;
                _safeTransferWithFee(payoutToken, address(doppiLP), profitLoss);
            }
            order.outAmount = order.outAmount > amountOut ? order.outAmount - amountOut : 0;
            order.swappedAmount = order.swappedAmount > swappedAmount ? order.swappedAmount - swappedAmount : 0;
        }
        if(p.amount > order.amount){
            delete opporMap[p.strikePrice];
        }else{
            order.amount -= p.amount;
        }        
    }

    function _settle_positions(
        uint64[] memory _allPositions, 
        uint256 _settlePrice
        ) internal {
        
        uint256 length = _allPositions.length;

        for (uint256 i = 0; i < length; ) {
            uint64 idx = _allPositions[i];
            (bool isBuy, , uint8 day, ) = _getPos(idx);
            _settlePosition(day, idx, _settlePrice, isBuy);
            nextProcessId[day] = idx + 1;
            unchecked { ++i; }
        }
    }

    function _posExist(uint8 day, uint64 posId) internal view returns (bool) {
        return positions_buy[day][posId].amount > 0 || positions_sell[day][posId].amount > 0;
    }

    function _getPos(uint64 posId) internal view returns (bool isBuy, DualAssetPosition memory p, uint8 day, bool found) {
        
        for(uint256 i=0; i< supportDays.length; ) {
            day = supportDays[i];
            (p, isBuy) = positions_buy[day][posId].amount > 0 ? (positions_buy[day][posId], true) : (positions_sell[day][posId], false);
            if(p.amount > 0) {
                found = true;
                break;
            } 
            unchecked { ++i; }
        }
    }

    function _checkOppoOrUnwind(
        bool _isBuy,
        uint256 price, 
        uint256 oneDayMove,
        bool _unwind
    ) internal view returns (uint256[] memory targetPrices, uint256 totalAmount) 
    {
        mapping(uint256 => OpportunityOrders) storage opporMap = _isBuy ? opportunityBuy : opportunitySell; 
        
        bool direction = (_isBuy && _unwind) || (!_isBuy && !_unwind);

        uint256 round = _getLoopRound(price, direction);
        uint256[] memory tempTargetPrice = new uint256[](round);
        
        uint256 count = 0;
        uint256 buffer = price * oneDayMove / 10000;
        uint256 triggerPrice = _isBuy ? price + buffer : price - buffer;
        uint256 triggerUnwindPrice = _isBuy ? price - buffer : price + buffer;
        uint256 maxSwapInLocal = (_isBuy == _unwind) ? maxSwap * priceDecimal / price : maxSwap;

        for (uint256 i = round; i > 0; ) {
            if (totalAmount >= maxSwapInLocal) break;
            uint256 strikeprice = _getTargetPrice(price, uint8(i), direction);
            bool isTriggered;
            uint256 totalAmountPost;
            uint256 comparedAmount;

            
            if(_unwind){
                comparedAmount = opporMap[strikeprice].outAmount; // get traded amount for unwind
                uint256 unwindSwappedAmount = opporMap[strikeprice].swappedAmount;
                
                if(comparedAmount > 0){
                    uint256 costPrice = _isBuy ? unwindSwappedAmount * priceDecimal / comparedAmount : comparedAmount * priceDecimal / unwindSwappedAmount;
                    isTriggered = _isBuy ? costPrice < triggerUnwindPrice : costPrice > triggerUnwindPrice;
                    totalAmountPost = totalAmount + comparedAmount;
                }
            }else{
                OpportunityOrders memory order = opporMap[strikeprice];
                comparedAmount = order.amount - order.swappedAmount; // get untraded amount
                isTriggered = _isBuy ? (comparedAmount > 0) && strikeprice > triggerPrice : (comparedAmount > 0) && strikeprice < triggerPrice;
                totalAmountPost = totalAmount + comparedAmount;
            }
            uint256 toTradeAmount = totalAmountPost > maxSwapInLocal ? comparedAmount - (totalAmountPost - maxSwapInLocal) : comparedAmount;
            
            if (isTriggered && (totalAmount + toTradeAmount) <= maxSwapInLocal) {
                totalAmount += toTradeAmount;
                tempTargetPrice[count] = strikeprice;
                count++;
            }
            unchecked { --i; }   
        }
        targetPrices = _createResultArrays(tempTargetPrice, count);
    }

    function checkOpportunity(uint256 price, bool _isBuy) external view
        returns (
            uint256[] memory targetPrices, 
            uint256[] memory targetPricesUnwind, 
            uint256 totalAmount,
            uint256 totalAmountUnwind
        ) {
        
        uint256 oneDayMove = doppiOffer.getOneDayBuffer(price, _isBuy);
        (targetPrices, totalAmount) = _checkOppoOrUnwind(_isBuy, price, oneDayMove, false);
        (targetPricesUnwind, totalAmountUnwind) = _checkOppoOrUnwind(_isBuy, price, oneDayMove, true);
    }

    function performOpportunity(
        uint256[] memory targetPrices, 
        uint256[] memory targetPricesUnwind, 
        uint256 totalAmount,
        uint256 totalAmountUnwind,
        bool isBuy
    ) external nonReentrant {
        
        _checkOpportunityBot();
        uint256 price = _getPriceFromLP();
        mapping(uint256 => OpportunityOrders) storage opporMap = isBuy ? opportunityBuy : opportunitySell; 
        
        if(targetPrices.length > 0){
            uint256 amountOut = _swapLowLevel(totalAmount, price, isBuy);
            uint256 reduced = totalAmount;
            uint256 reducedout = amountOut;
            for (uint256 j = targetPrices.length; j > 0 ; ) {
                (reduced, reducedout) = _executeOpportunity(totalAmount, amountOut, price, reduced, reducedout, isBuy, opporMap[targetPrices[j-1]]);
                unchecked { --j; }
            }
        }
        if(targetPricesUnwind.length > 0){
            uint256 amountOutUnwind = _swapLowLevel(totalAmountUnwind, price, !isBuy);
            uint256 reduced = totalAmountUnwind;
            uint256 reducedout = amountOutUnwind;
            for (uint256 j = 0; j < targetPricesUnwind.length; ) {
                (reduced, reducedout) = _executeUnwind(
                    totalAmountUnwind, amountOutUnwind, price, reduced, reducedout, isBuy, opporMap[targetPricesUnwind[j]]
                    );
                unchecked { ++j; }
            }
        }
    }

    function _updateBound() internal {

        uint256 gap = doppiOffer.getPriceGapPerOffer() * priceDecimal;

        // ------------------ UPDATE LOWER BOUND ------------------
        uint256 i = lowerBound;
        while (true) {
            if (opportunityBuy[i].amount > 0 || opportunitySell[i].amount > 0) {
                lowerBound = i;
                break;
            }
            // move upward
            i += gap;

            // no valid strike left
            if (i > upperBound) {
                _resetBound();
                return;
            }
        }

        // ------------------ UPDATE UPPER BOUND ------------------
        i = upperBound;
        while (true) {
            if (opportunityBuy[i].amount > 0 || opportunitySell[i].amount > 0) {
                upperBound = i;
                break;
            }
            // guard underflow
            if (i < gap) break;
            i -= gap;

            if (i < lowerBound) {
                _resetBound();
                return;
            }
        }
    }

    function _resetBound() internal {
        uint256 price = _getPriceFromLP();
        lowerBound = _getTargetPrice(price, 1, true);
        upperBound = _getTargetPrice(price, 1, false);
    }

    function _createResultArrays(
        uint256[] memory tempPrices,
        uint256 count
    ) private pure returns (uint256[] memory prices) {
        uint256 resultSize = count < tempPrices.length ? count : tempPrices.length;
        
        prices = new uint256[](resultSize);
        
        for (uint256 i = 0; i < resultSize;) {
            prices[i] = tempPrices[resultSize - 1 - i];
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
        uint256 totalAmount,
        uint256 totalAmountOut,
        uint256 price,
        uint256 reduced,
        uint256 reducedout,
        bool isBuy,
        OpportunityOrders storage order
    ) internal returns (uint256 reducedUpdated, uint256 reducedoutUpdated) {
        
        uint256 amount = order.amount;
        uint256 swappedAmount = order.swappedAmount;
        uint256 unTrade = amount - swappedAmount;
        
        uint256 myAmountOut;
        reducedUpdated = reduced;
        reducedoutUpdated = reducedout;

        if(reducedUpdated >= unTrade){
            uint256 ratio = unTrade * 1e18 / totalAmount;
            myAmountOut = totalAmountOut * ratio / 1e18;
            order.outAmount += myAmountOut;
            order.swappedAmount += unTrade;
            reducedUpdated -= unTrade;
            reducedoutUpdated = reducedoutUpdated > myAmountOut ? reducedoutUpdated - myAmountOut : 0; 
        }else{
            order.outAmount += reducedout;
            order.swappedAmount += reduced;
            myAmountOut = reducedout;
            amount = reduced;
        }
        emit OppPerformed(isBuy, price, amount, myAmountOut);
    }

    function _executeUnwind(
        uint256 totalAmountUnwind,
        uint256 amountOutUnwind,
        uint256 price,
        uint256 reduced,
        uint256 reducedout,
        bool isBuy,
        OpportunityOrders storage order
    ) internal returns (uint256 reducedUpdated, uint256 reducedoutUpdated){

        uint256 unwind = order.outAmount;
        uint256 swappedAmount = order.swappedAmount;
        uint256 ratio;
        uint256 myAmountOut;
        reducedUpdated = reduced;
        reducedoutUpdated = reducedout;
        
        if(reducedUpdated >= unwind){
            ratio = unwind * 1e27 / totalAmountUnwind;
            myAmountOut = amountOutUnwind * ratio / 1e27;
            order.outAmount -= unwind;
            order.swappedAmount -= swappedAmount;
            reducedUpdated -= unwind;
            reducedoutUpdated = reducedoutUpdated >= swappedAmount ? reducedoutUpdated - swappedAmount : 0;
        }else{
            uint256 unwindTotal = unwind;
            unwind = unwind - reducedUpdated; 
            ratio = (unwindTotal - reducedUpdated) * 1e27 / unwindTotal; // get not inclusion portion
            uint256 newSwappedAmount = swappedAmount * ratio / 1e27; // 100% unwind amount
            swappedAmount = swappedAmount > newSwappedAmount ? swappedAmount - newSwappedAmount : 0;
            myAmountOut = reducedoutUpdated;
            order.outAmount = order.outAmount > reducedUpdated ? order.outAmount - reducedUpdated : 0;
            order.swappedAmount = newSwappedAmount;
        }
        // Calculate and transfer profit if any
        uint256 profit;
        IERC20 profitToken = isBuy ? assetA : assetB;
        if (myAmountOut > swappedAmount) {
            profit = myAmountOut - swappedAmount;
            _safeTransferWithFee(profitToken, address(doppiLP), profit);
            reducedoutUpdated -= profit;
        }
        emit OppUnwindPerformed(isBuy, price, unwind, myAmountOut, profit, address(profitToken));
    }

    function _batchProcess(
        uint64[] memory allPositions,
        SettleAccumulate memory settleAccu,
        uint256 price
        ) internal {
        
        uint256 length = allPositions.length;

        for (uint256 i = 0; i < length; ) {
            uint64 idx = allPositions[i];
            bool isInTheMoney;
            (bool isBuy, DualAssetPosition memory p, ,) = _getPos(idx);
            if(isBuy){
                isInTheMoney = price <= p.strikePrice;
                if(isInTheMoney){
                    if(!_isPosTraded(p.strikePrice, p.amount, true)){
                        settleAccu.totalA += p.amount;
                    }else{
                        OpportunityOrders memory opp = opportunityBuy[p.strikePrice];
                        uint256 notenough = p.payout > opp.outAmount ? p.payout - opp.outAmount : 0; 
                        settleAccu.totalInterestB += notenough;
                    }
                }
            }else{
                isInTheMoney = price >= p.strikePrice;
                if(isInTheMoney){
                    if(!_isPosTraded(p.strikePrice, p.amount, false)){
                        settleAccu.totalB += p.amount;
                    }else{
                        OpportunityOrders memory opp = opportunitySell[p.strikePrice];
                        uint256 notenough = p.payout > opp.outAmount ? p.payout - opp.outAmount : 0; 
                        settleAccu.totalInterestA += notenough;
                    }
                }
            }
            unchecked { ++i; }
        }
        if(settleAccu.totalA > 0){
            uint256 amountOut = (settleAccu.totalA * priceDecimal) / price;
            _doppiSettleCall(settleAccu.totalA, amountOut, price, true);
        }
        if(settleAccu.totalB > 0){
            uint256 amountOut = (settleAccu.totalB * price) / priceDecimal;
            _doppiSettleCall(settleAccu.totalB, amountOut, price, false);
        }
        if(settleAccu.totalInterestA > 0){
            _doppiInterestGet(assetA, settleAccu.totalInterestA, price, true);
        }        
        if(settleAccu.totalInterestB > 0){
            _doppiInterestGet(assetB, settleAccu.totalInterestB, price, false);
        }
    }

    function _updateLowerUpperBound(uint256 strikePrice) internal {
        if(strikePrice > upperBound){
            upperBound = strikePrice;
        }else if (strikePrice < lowerBound || lowerBound == 0){
            lowerBound = strikePrice;
        }
    }

    function _isPosTraded(
        uint256 strikePrice, 
        uint256 orderAmount,
        bool isBuy) internal view returns (bool) 
    {
        OpportunityOrders memory order = isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice]; 
        uint256 amount = order.amount;
        uint256 swappedAmount = order.swappedAmount;
        uint256 unTradeAmount = amount - swappedAmount;
        return unTradeAmount < orderAmount;
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

        (bool ok, ) = address(doppiPoints).call(abi.encodeWithSelector(RECORD_SELECTOR, trader, volume));
        if (!ok) revert RecordTradeFailed();
    }

    function _swapLowLevel(
        uint256 amountIn,
        uint256 price,
        bool isBuy
    ) internal returns (uint256 amountOut) {

        bytes memory callData = abi.encodeWithSelector(SWAP_SELECTOR, amountIn, price, isBuy);
        (bool success, bytes memory result) = address(doppiLP).call(callData);
        if (!(success && result.length >= 32)) revert SwapFailed();

        amountOut = abi.decode(result, (uint256));
    }

    function _getPriceFromLP() internal view returns (uint256 price) {

        bytes memory callData = abi.encodeWithSelector(PRICE_SELECTOR);
        (bool ok, bytes memory ret) = address(doppiLP).staticcall(callData);
        if (!(ok && ret.length >= 32)) revert PriceFailed();
        price = abi.decode(ret, (uint256));
    }

    function _doppiSettleCall(uint256 amount, uint256 payout, uint256 price, bool isBuy) internal returns (uint256 out) {

        (bool ok, bytes memory ret) = address(doppiLP).call(
            abi.encodeWithSelector(
                SETTLE_SELECTOR,
                amount,
                payout,
                price,
                isBuy
            )
        );
        if (!(ok && ret.length >= 32)) revert SettleFailed();
        out = abi.decode(ret, (uint256));
    }

    function _doppiInterestGet(
            IERC20 interestToken,
            uint256 interest,
            uint256 price,
            bool isBuy
        ) internal {

        (bool ok, ) = address(doppiLP).call(
            abi.encodeWithSelector(INTEREST_SELECTOR, address(interestToken), interest, price, isBuy)
        );
        if (!ok) revert InterestGetFailed();
    }

    function _checkOpportunityBot() internal view {
        if (!opportunityBots[msg.sender]) revert OnlyOpportunityBot();
    }

    function _onlyForwarder() internal view {
        if (msg.sender != s_forwarderAddress) revert OnlyForwarder();
    }

    function _onlyTraderBot() internal view {
        if (!doppiTraderFactory.isTraderBot(msg.sender)) revert OnlyTraderBot();
    }

    function _whenOpen() internal view {
        if (!publicOpen) revert NotOpen();
    }
}