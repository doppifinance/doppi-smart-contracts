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

    struct StrikeNode {
        uint256 prev;
        uint256 next;
        bool active;
    }

    uint32 private constant SECONDS_PER_YEAR = 31536000;
    uint24 private constant SECONDS_PER_DAY = 86400;
    uint16 private constant BASIS_POINTS = 10000;
    mapping(uint256 => StrikeNode) internal buyStrikeNodes;
    mapping(uint256 => StrikeNode) internal sellStrikeNodes;
    uint256 internal buyHead;
    uint256 internal buyTail;
    uint256 internal sellHead;
    uint256 internal sellTail;
    uint256 internal activeBuyStrikeCount;
    uint256 internal activeSellStrikeCount;
    
    event Deposited(address indexed trader, uint64 positionId, address asset, uint256 amount, uint256 interest, uint256 strikePrice, uint32 apr, uint8 numDays);
    event Settled(address indexed trader, uint64 positionId, bool striked, uint256 strikePrice, uint256 marketPrice, bool isProfit, uint256 profitLoss, uint256 payout, uint256 interest, address payoutToken, address interestToken);
    event EmergencyWithdraw(bool isBuy, address indexed trader, uint64 positionId, uint256 amount);
    event OppPerformed(bool isBuy, uint256 price, uint256 amount, uint256 amountOut);
    event OppUnwindPerformed(bool isBuy, uint256 price, uint256 swappedAmount, uint256 amountOut, uint256 profit, address profitToken);
    
    error InvalidStrikePriceOrPrice();
    error InvalidAPR();
    error InvalidAmount();
    error InvalidOfferLength();
    error NotExpired();
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
    error NotExist();


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

        supportDays.push(1);
        nextProcessId[1] = 1;
        nextPositionId[1] = 1;
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
        _syncStrikeState(buyOffer.strikePrice, true);
        // record for points
        if(!doppiPoints.paused()){
            _recordTradePoints(msg.sender, params.amount);
        }
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
        _syncStrikeState(sellOffer.strikePrice, false);
        // record for points
        if(!doppiPoints.paused()){
            uint256 tradeVolume = (params.amount * sellOffer.price) / priceDecimal; 
            _recordTradePoints(msg.sender, tradeVolume);
        }
    }

    function bulkDeposit(bool isBuy, BulkDepositParam[] calldata params, uint256 total) external whenNotPaused {
        
        _onlyTraderBot();
        uint256 length = params.length;
        if (length == 0) revert InvalidOfferLength();

        // Fetch price once — all per-slot getSingleOffer calls below are pure math
        uint256 price = _getPriceFromLP();

        for (uint256 i = 0; i < length; ) {
            BulkDepositParam calldata param = params[i];
            if (param.amount == 0) revert InvalidAmount();

            // Core derives the authoritative offer — caller cannot manipulate strikePrice/apr/expiry
            DualAssetOffer memory offer = doppiOffer.getSingleOffer(isBuy, param.numDays, param.strikeZone, price);
            if (offer.price == 0) revert InvalidStrikePriceOrPrice();

            // Reconstruct a DepositParams so _depositBuy/_depositSell signatures are unchanged
            DepositParams memory dp = DepositParams({
                amount: param.amount,
                strikeZone: param.strikeZone,
                strikePrice: offer.strikePrice,
                numDays: param.numDays,
                apr: offer.apr,
                expiry: offer.expiry
            });

            isBuy ? _depositBuy(dp, offer) : _depositSell(dp, offer);
            _syncStrikeState(offer.strikePrice, isBuy);
            unchecked { ++i; }
        }

        if (!doppiPoints.paused()) {
            uint256 tradeVolume = isBuy ? total : (total * price) / priceDecimal;
            _recordTradePoints(msg.sender, tradeVolume);
        }
    }

    // Chainlink Keepers integration
    function checkUpkeep(bytes calldata) 
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if(paused()) return (false, bytes(""));

        uint64[] memory supportDaysPositions = new uint64[](supportDays.length);
        uint8[] memory durationDay = new uint8[](supportDays.length);
        uint256 count;
        for (uint256 i = 0; i < supportDays.length; ) {
            uint8 day = supportDays[i];
            uint64 endPosId = _getReadyAllPositions(day);
            if (endPosId >= nextProcessId[day] && endPosId != 0) {
                durationDay[count] = day;
                supportDaysPositions[count] = endPosId;
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }

        uint64[] memory endPositionIds = new uint64[](count);
        uint8[] memory dDays = new uint8[](count);
        for (uint256 i = 0; i < count; ) {
            dDays[i] = durationDay[i];
            endPositionIds[i] = supportDaysPositions[i];
            unchecked { ++i; }
        }
        

        if (count > 0) {
            return (true, abi.encode(dDays, endPositionIds));
        }

        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external nonReentrant {
        
        _onlyForwarder();
        if(paused()) return;
        
        (uint8[] memory durationDay, uint64[] memory endPositionId) = abi.decode(performData, (uint8[], uint64[]));
        _processNewSettlements(durationDay, endPositionId);
    }

    function settleOrders(uint8 day) external nonReentrant onlyOwner {
        uint256 price = _getPriceFromLP();
        uint64 endPosId = _getReadyAllPositions(day);
        uint64 start = nextProcessId[day];
        require(endPosId >= start && endPosId != 0, "no positions to settle");
        
        _batchProcess(day, start, endPosId, price);
        _settle_positions(day, start, endPosId, price);
        // _updateBound(); 
    }

    function emergencySettlement(uint8 day) external whenPaused nonReentrant onlyOwner {
        
        if (!emergencyMode) revert EmergencyModeActive();
        _emergencySettlement(day);
    }

    function addSupportDay(uint8 _day) external onlyOwner {
        for (uint256 i = 0; i < supportDays.length; i++) {
            require(supportDays[i] != _day, "day already registered");
        }
        supportDays.push(_day);
        nextProcessId[_day] = 1;
        nextPositionId[_day] = 1;
    }

    function isEmergency() external view returns (bool){
        return emergencyMode;
    } 

    function getReadyAllPositions(uint8 day) public view 
        returns (
            uint64 endPositionId
        ) {
        
        return _getReadyAllPositions(day);
    }

    function getDoppiOffer() external view returns (address){
        return address(doppiOffer);
    } 

    // Internal functions
    function _getReadyAllPositions(uint8 day) internal view 
        returns (
            uint64 endPositionId
        ) {
        
        uint64 start = nextProcessId[day];
        uint64 end = start + uint64(UPKEEPS_PER_CHECK);

        for (uint64 posId = start; posId < end; ) {
            bool exist = _posExist(day, posId);
            if (exist) {
                bool isBuy = positions_buy[day][posId].amount > 0;
                DualAssetPosition memory pos = isBuy ? positions_buy[day][posId] : positions_sell[day][posId];

                if (pos.expiryTimestamp <= block.timestamp) {
                    endPositionId = posId;
                } else {
                    break;
                }
            }else{
                break; 
            }
            unchecked { ++posId; }
        }
    }

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

    function _emergencySettlement(uint8 day) internal {

        uint256 unsettledLen = getPositionLength(day);
        if(unsettledLen == 0) return;
        
        uint64 start = nextProcessId[day];
        uint64 end = start + (uint64(unsettledLen) < uint64(UPKEEPS_PER_CHECK) ? uint64(unsettledLen) : uint64(UPKEEPS_PER_CHECK));

        uint256 price = _getPriceFromLP();
        for (uint64 i = start; i < end; ) {
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
                        _settleNoStrike(pos, price, isBuy, assetA);
                    } else {                            
                        delete positions_sell[day][i];
                        _settleNoStrike(pos, price, isBuy, assetB);
                    }
                    nextProcessId[day] = i + 1;
                    emit EmergencyWithdraw(isBuy, pos.owner, i, amountToReturn);
                }
            }
            unchecked { ++i; }
        }
        
    }

    function _processNewSettlements(
        uint8[] memory durationDay,
        uint64[] memory supportDaysPositions
    ) internal {
        
        uint256 price = _getPriceFromLP();
        uint256 length = durationDay.length;

        for (uint8 i = 0; i < length; ) {
            uint8 day = durationDay[i];
            uint64 start = nextProcessId[day];
            uint64 endPositionId = supportDaysPositions[i];
            _batchProcess(day, start, endPositionId, price);
            _settle_positions(day, start, endPositionId, price);
            unchecked { ++i; }
        }
        // _updateBound(); 
    }

    function _depositBuy(DepositParams memory params, DualAssetOffer memory _buyOffer) internal {
        uint256 amount = params.amount;
        uint8 numDays = params.numDays;
        address sender = msg.sender;

        assetA.safeTransferFrom(sender, address(this), amount);
        // Update total deposits
        totalBuyDeposits += amount;
        uint64 positionId = nextPositionId[numDays];
        unchecked { nextPositionId[numDays] = positionId + 1; }

        // Calculate interest using precomputed values
        uint256 duration = uint256(SECONDS_PER_DAY) * uint256(numDays);
        uint256 interest = (amount * uint256(_buyOffer.apr) * duration) / (uint256(BASIS_POINTS) * uint256(SECONDS_PER_YEAR));
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
        
        emit Deposited(sender, positionId, address(assetA), amount, interest, _buyOffer.strikePrice, _buyOffer.apr, numDays);
    }

    function _depositSell(DepositParams memory params, DualAssetOffer memory _sellOffer) internal {
        
        uint256 amount = params.amount;
        uint8 numDays = params.numDays;
        address sender = msg.sender;

        assetB.safeTransferFrom(sender, address(this), params.amount);

        // Update total deposits
        totalSellDeposits += amount;

        uint64 positionId = nextPositionId[numDays];
        unchecked { nextPositionId[numDays] = positionId + 1; }
        
        // Calculate interest using precomputed values
        uint256 duration = uint256(SECONDS_PER_DAY) * uint256(numDays);
        uint256 interest = (amount * uint256(_sellOffer.apr) * duration) / (uint256(BASIS_POINTS) * uint256(SECONDS_PER_YEAR));
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
        emit Deposited(sender, positionId, address(assetB), amount, interest, _sellOffer.strikePrice, _sellOffer.apr, numDays);
    }

    function _settlePosition(
        uint8 day,
        uint64 posId,
        uint256 price
    ) internal {
        
        bool striked;
        DualAssetPosition memory p;
        
        bool isBuy;
        if(positions_buy[day][posId].amount > 0){
            p = positions_buy[day][posId];
            delete positions_buy[day][posId];
            striked = price <= p.strikePrice;
            isBuy = true;
        }else{
            p = positions_sell[day][posId];
            delete positions_sell[day][posId];
            striked = price >= p.strikePrice;
            isBuy = false;
        }
        if(p.expiryTimestamp > block.timestamp) revert NotExpired();        
        _removeInterestLiability(p.interest, isBuy);
        _updateTotalDeposit(p.amount, isBuy);

        IERC20 payoutToken;
        IERC20 interestToken;
        bool isProfit;
        uint256 profitLoss;

        if (striked) {
            (payoutToken, interestToken) = isBuy ? (assetB, assetA) : (assetA, assetB);
            (isProfit, profitLoss) = _settleStrike(p, price, isBuy, payoutToken);
        }else{
            (payoutToken, interestToken) = isBuy ? (assetA, assetA) : (assetB, assetB);
            _settleNoStrike(p, price, isBuy, payoutToken);
        }

        _reduceOpportunityOrder(p.strikePrice, p.amount, isBuy);

        if(p.interest > 0) _safeTransferWithFee(interestToken, p.owner, p.interest);
        
        emit Settled(
            p.owner,
            posId,
            striked, 
            p.strikePrice,
            price,
            isProfit,
            profitLoss,
            striked ? p.payout : 0,
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
            try IDoppiTrader(p.owner).createUnwindPosition(
                p.payout,
                p.strikePrice,
                isBuy
            ) {
                // success
            } catch {
                // best-effort unwind position; do not revert settlement
            }
        }
    }
    
    // Settlement helper functions
    function _settleStrike(
        DualAssetPosition memory p,
        uint256 price,
        bool isBuy,
        IERC20 payoutToken
    ) internal returns (bool isProfit, uint256 profitLoss) {
        
        uint256 payout = p.payout;
        bool isTraded = _isPosTraded(p.strikePrice, p.amount, isBuy);
        mapping(uint256 => OpportunityOrders) storage opporMap = isBuy ? opportunityBuy : opportunitySell; 
        if(!isTraded){
            payoutToken.safeTransfer(p.owner, payout);
            uint256 amountOut = isBuy ? (p.amount * priceDecimal) / price : (p.amount * price) / priceDecimal;
            uint256 settleprofit = amountOut > payout ? amountOut - payout : 0;
            if (settleprofit > 0) {
                _safeTransferWithFee(payoutToken, address(doppiLP), settleprofit);
                unchecked {
                    profitLoss = settleprofit; 
                }
                isProfit = true;
            }
        }else{
            OpportunityOrders storage opp = opporMap[p.strikePrice];
            uint256 myAmountOut = opp.swappedAmount > 0 ? opp.outAmount * p.amount / opp.swappedAmount : 0;
            uint256 notenough = payout > myAmountOut ? payout - myAmountOut : 0; 
            if(notenough > 0) {
                _doppiInterestGet(payoutToken, notenough, price, isBuy);
            } else {
                uint256 settleprofit = myAmountOut - payout; 
                if (settleprofit > 0) {
                    _safeTransferWithFee(payoutToken, address(doppiLP), settleprofit);
                    unchecked {
                        profitLoss = settleprofit; 
                    }
                    isProfit = true;
                }
            }
            payoutToken.safeTransfer(p.owner, payout);            
            opp.outAmount = opp.outAmount > myAmountOut ? opp.outAmount - myAmountOut : 0;
            opp.swappedAmount = opp.swappedAmount > p.amount ? opp.swappedAmount - p.amount : 0;
        }
        _createTraderBotUnwindPosition(p, isBuy);
    }

    function _settleNoStrike(
        DualAssetPosition memory p,
        uint256 price,
        bool isBuy,
        IERC20 payoutToken
    ) internal returns (bool isProfit, uint256 profitLoss) {
        
        bool isTraded = _isPosTraded(p.strikePrice, p.amount, isBuy);
        mapping(uint256 => OpportunityOrders) storage opporMap = isBuy ? opportunityBuy : opportunitySell; 
        if(!isTraded){
            payoutToken.safeTransfer(p.owner, p.amount);
        }else {

            OpportunityOrders storage opp = opporMap[p.strikePrice];
            uint256 myAmountOut = opp.swappedAmount > 0 ? opp.outAmount * p.amount / opp.swappedAmount : 0;
            uint256 amountInOrig = _swapLowLevel(myAmountOut, price, !isBuy);
            
            if (amountInOrig >= p.amount) {
                unchecked {
                    profitLoss = amountInOrig - p.amount; 
                }
                isProfit = true;
                _safeTransferWithFee(payoutToken, address(doppiLP), profitLoss);
            }else{
                uint256 notenough = p.amount - amountInOrig; 
                _doppiInterestGet(payoutToken, notenough, price, isBuy);
            }
            payoutToken.safeTransfer(p.owner, p.amount);
            
            opp.outAmount = opp.outAmount > myAmountOut ? opp.outAmount - myAmountOut : 0;
            opp.swappedAmount = opp.swappedAmount > p.amount ? opp.swappedAmount - p.amount : 0;
        }
     
    }

    function _settle_positions(
        uint8 day,
        uint64 start,
        uint64 end,
        uint256 price
    ) internal {
        
        for (uint64 posId = start; posId <= end; ) {
            bool exist = _posExist(day, posId);
            if(!exist) {
                unchecked { ++posId; }
                continue;
            }
            _settlePosition(day, posId, price);
            unchecked { ++posId; }
        }
        nextProcessId[day] = end + 1;
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
        if (_isBuy) {
            return _scanActiveStrikes(opportunityBuy, buyStrikeNodes, activeBuyStrikeCount, price, oneDayMove, true, _unwind, buyHead, buyTail);
        }
        return _scanActiveStrikes(opportunitySell, sellStrikeNodes, activeSellStrikeCount, price, oneDayMove, false, _unwind, sellHead, sellTail);
    }

    function _scanActiveStrikes(
        mapping(uint256 => OpportunityOrders) storage opporMap,
        mapping(uint256 => StrikeNode) storage strikeNodes,
        uint256 activeCount,
        uint256 price,
        uint256 oneDayMove,
        bool isBuy,
        bool unwind,
        uint256 head,
        uint256 tail
    ) internal view returns (uint256[] memory targetPrices, uint256 totalAmount) {
        if (activeCount == 0) {
            return (new uint256[](0), 0);
        }

        uint256[] memory tempTargetPrice = new uint256[](activeCount);
        uint256 count = 0;
        uint256 buffer = price * oneDayMove / 10000;
        uint256 triggerPrice = isBuy ? price + buffer : price - buffer;
        uint256 triggerUnwindPrice = isBuy ? price - buffer : price + buffer;
        uint256 maxSwapInLocal = (isBuy == unwind) ? maxSwap * priceDecimal / price : maxSwap;
        bool ascending = isBuy != unwind;
        uint256 strikeprice = ascending ?  tail: head;

        while (strikeprice != 0) {
            uint256 nextStrike = ascending ? strikeNodes[strikeprice].prev : strikeNodes[strikeprice].next;
            OpportunityOrders storage order = opporMap[strikeprice];
            bool isTriggered;
            uint256 comparedAmount;

            if (unwind) {
                comparedAmount = order.outAmount;
                uint256 unwindSwappedAmount = order.swappedAmount;
                if (comparedAmount > 0 && unwindSwappedAmount > 0) {
                    uint256 costPrice = isBuy
                        ? unwindSwappedAmount * priceDecimal / comparedAmount
                        : comparedAmount * priceDecimal / unwindSwappedAmount;
                    isTriggered = isBuy ? costPrice < triggerUnwindPrice : costPrice > triggerUnwindPrice;
                }
            } else {
                comparedAmount = order.amount > order.swappedAmount ? order.amount - order.swappedAmount : 0;
                isTriggered = isBuy
                    ? (comparedAmount > 0 && strikeprice > triggerPrice)
                    : (comparedAmount > 0 && strikeprice < triggerPrice);
                
            }

            if (isTriggered && comparedAmount > 0) {
                uint256 totalAmountPost = totalAmount + comparedAmount;
                uint256 toTradeAmount = totalAmountPost > maxSwapInLocal
                    ? comparedAmount - (totalAmountPost - maxSwapInLocal)
                    : comparedAmount;

                if (toTradeAmount > 0 && (totalAmount + toTradeAmount) <= maxSwapInLocal) {
                    totalAmount += toTradeAmount;
                    tempTargetPrice[count] = strikeprice;
                    unchecked { ++count; }
                }
            }

            strikeprice = nextStrike;
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
                uint256 strikePrice = targetPrices[j - 1];
                (reduced, reducedout) = _executeOpportunity(totalAmount, amountOut, price, reduced, reducedout, isBuy, strikePrice, opporMap[strikePrice]);
                unchecked { --j; }
            }
        }
        if(targetPricesUnwind.length > 0){
            uint256 amountOutUnwind = _swapLowLevel(totalAmountUnwind, price, !isBuy);
            uint256 reduced = totalAmountUnwind;
            uint256 reducedout = amountOutUnwind;
            for (uint256 j = 0; j < targetPricesUnwind.length; ) {
                uint256 strikePrice = targetPricesUnwind[j];
                (reduced, reducedout) = _executeUnwind(
                    totalAmountUnwind, amountOutUnwind, price, reduced, reducedout, isBuy, strikePrice, opporMap[strikePrice]
                    );
                unchecked { ++j; }
            }
        }
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

    function _executeOpportunity(
        uint256 totalAmount,
        uint256 totalAmountOut,
        uint256 price,
        uint256 reduced,
        uint256 reducedout,
        bool isBuy,
        uint256 strikePrice,
        OpportunityOrders storage order
    ) internal returns (uint256 reducedUpdated, uint256 reducedoutUpdated) {
        
        uint256 amount = order.amount;
        uint256 swappedAmount = order.swappedAmount;
        uint256 unTrade = amount - swappedAmount;
        
        uint256 myAmountOut;
        reducedUpdated = reduced;
        reducedoutUpdated = reducedout;

        if(reducedUpdated >= unTrade){
            myAmountOut = totalAmountOut * unTrade / totalAmount;
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
        _syncStrikeState(strikePrice, isBuy);
        emit OppPerformed(isBuy, price, amount, myAmountOut);
    }

    function _executeUnwind(
        uint256 totalAmountUnwind,
        uint256 amountOutUnwind,
        uint256 price,
        uint256 reduced,
        uint256 reducedout,
        bool isBuy,
        uint256 strikePrice,
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
        _syncStrikeState(strikePrice, isBuy);
        emit OppUnwindPerformed(isBuy, price, unwind, myAmountOut, profit, address(profitToken));
    }

    /// Get settle amount for those striked in bulk
    /// Get interests in bulk 
    function _batchProcess(
        uint8 day,
        uint64 start,
        uint64 end,
        uint256 price
        ) internal {
        
        uint256 totalA;
        uint256 totalB;
        uint256 totalInterestA;
        uint256 totalInterestB;
        
        for (uint64 posId = start; posId <= end; ) {
            bool isInTheMoney;
            bool exist = _posExist(day, posId);
            if(!exist) {
                unchecked { ++posId; }
                continue;
            }
            (DualAssetPosition memory p, bool isBuy) = positions_buy[day][posId].amount > 0 ? (positions_buy[day][posId], true) : (positions_sell[day][posId], false);
            if(isBuy){
                isInTheMoney = price <= p.strikePrice;
                if(isInTheMoney){
                    if(!_isPosTraded(p.strikePrice, p.amount, true)){
                        totalA += p.amount;
                    }
                }
                totalInterestA += p.interest;
            }else{
                isInTheMoney = price >= p.strikePrice;
                if(isInTheMoney){
                    if(!_isPosTraded(p.strikePrice, p.amount, false)){
                        totalB += p.amount;
                    }
                }
                totalInterestB += p.interest;
            }
            unchecked { ++posId; }
        }
        if(totalA > 0){
            uint256 amountOut = (totalA * priceDecimal) / price;
            _doppiSettleCall(totalA, amountOut, price, true);
        }
        if(totalB > 0){
            uint256 amountOut = (totalB * price) / priceDecimal;
            _doppiSettleCall(totalB, amountOut, price, false);
        }
        if(totalInterestA > 0){
            _doppiInterestGet(assetA, totalInterestA, price, true);
        }        
        if(totalInterestB > 0){
            _doppiInterestGet(assetB, totalInterestB, price, false);
        }
    }

    function _syncStrikeState(uint256 strikePrice, bool isBuy) internal {
        OpportunityOrders storage opp = isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
        bool shouldBeActive = opp.amount > 0 || opp.swappedAmount > 0 || opp.outAmount > 0;
        if (isBuy) {
            if (shouldBeActive) {
                _activateStrikeNode(buyStrikeNodes, strikePrice, true);
            } else {
                _deactivateStrikeNode(buyStrikeNodes, strikePrice, true);
            }
        } else {
            if (shouldBeActive) {
                _activateStrikeNode(sellStrikeNodes, strikePrice, false);
            } else {
                _deactivateStrikeNode(sellStrikeNodes, strikePrice, false);
            }
        }
    }

    function _activateStrikeNode(
        mapping(uint256 => StrikeNode) storage strikeNodes,
        uint256 strikePrice,
        bool isBuySide
    ) internal {
        StrikeNode storage node = strikeNodes[strikePrice];
        if (node.active) return;

        node.active = true;
        if (isBuySide) {
            unchecked { ++activeBuyStrikeCount; }
        } else {
            unchecked { ++activeSellStrikeCount; }
        }

        uint256 head = isBuySide ? buyHead : sellHead;
        uint256 tail = isBuySide ? buyTail : sellTail;

        if (head == 0) {
            if (isBuySide) {
                buyHead = strikePrice;
                buyTail = strikePrice;
            } else {
                sellHead = strikePrice;
                sellTail = strikePrice;
            }
            return;
        }

        if (strikePrice <= head) {
            node.next = head;
            strikeNodes[head].prev = strikePrice;
            if (isBuySide) buyHead = strikePrice;
            else sellHead = strikePrice;
            return;
        }

        if (strikePrice >= tail) {
            node.prev = tail;
            strikeNodes[tail].next = strikePrice;
            if (isBuySide) buyTail = strikePrice;
            else sellTail = strikePrice;
            return;
        }

        uint256 current = head;
        while (current != 0 && current < strikePrice) {
            current = strikeNodes[current].next;
        }

        uint256 prevNode = strikeNodes[current].prev;
        node.prev = prevNode;
        node.next = current;
        strikeNodes[prevNode].next = strikePrice;
        strikeNodes[current].prev = strikePrice;
    }

    function _deactivateStrikeNode(
        mapping(uint256 => StrikeNode) storage strikeNodes,
        uint256 strikePrice,
        bool isBuySide
    ) internal {
        StrikeNode storage node = strikeNodes[strikePrice];
        
        if (!node.active) return;

        uint256 prevNode = node.prev;
        uint256 nextNode = node.next;

        if (prevNode != 0) {
            strikeNodes[prevNode].next = nextNode;
        } else if (isBuySide) {
            buyHead = nextNode;
        } else {
            sellHead = nextNode;
        }

        if (nextNode != 0) {
            strikeNodes[nextNode].prev = prevNode;
        } else if (isBuySide) {
            buyTail = prevNode;
        } else {
            sellTail = prevNode;
        }

        delete strikeNodes[strikePrice];
        if (isBuySide) {
            if (activeBuyStrikeCount > 0) {
                unchecked { --activeBuyStrikeCount; }
            }
        } else {
            if (activeSellStrikeCount > 0) {
                unchecked { --activeSellStrikeCount; }
            }
        }
    }

    function getLowerUpperBound() public view returns (uint256, uint256) {
        
        uint256 lower = buyHead == 0
            ? sellHead
            : sellHead == 0
                ? buyHead
                : (buyHead < sellHead ? buyHead : sellHead);

        uint256 upper = buyTail > sellTail ? buyTail : sellTail;
        return (lower, upper);
    }

    function _reduceOpportunityOrder(uint256 strikePrice, uint256 amount, bool isBuy) internal {
        mapping(uint256 => OpportunityOrders) storage opporMap = isBuy ? opportunityBuy : opportunitySell;
        OpportunityOrders storage opp = opporMap[strikePrice];

        if (opp.amount <= amount) {
            opp.amount = 0;
        } else {
            opp.amount -= amount;
        }

        _syncStrikeState(strikePrice, isBuy);
    }

    function _isPosTraded(
        uint256 strikePrice, 
        uint256 orderAmount,
        bool isBuy) internal view returns (bool) 
    {
        OpportunityOrders memory order = isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice]; 
        uint256 swappedAmount = order.swappedAmount;
        return swappedAmount >= orderAmount;
    }

    function _getTargetPrice(uint256 _price, uint8 _zone, bool _isBuy) internal view returns (uint256) {
        uint256 priceGapWithDecimals = doppiOffer.getPriceGapPerOffer() * priceDecimal;
        require(priceGapWithDecimals > 0, "Invalid price gap");
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * (_zone - 1)) : _price + (priceGapWithDecimals * _zone);
    }

    function _safeTransferWithFee(IERC20 _asset, address _to, uint256 _amount) internal {
        
        uint256 amountFee = _amount * treasury_fee / 10000;
        uint256 amountAfterFee = _amount - amountFee;
        _asset.safeTransfer(_to, amountAfterFee);
        if (amountFee > 0) _asset.safeTransfer(treasury, amountFee);
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
        if(price == 0) revert PriceFailed();
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