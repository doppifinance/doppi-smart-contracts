// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AutomationCompatibleInterface} from "../Interface/AutomationCompatibleInterface.sol";
import {IDoppiTrader} from "../Interface/IDoppiTrader.sol";
import {IDoppiPoints} from "../Interface/IDoppiPoints.sol";
import {IDoppiOffer} from "../Interface/IDoppiOffer.sol";
import {IDoppiOpportunity} from "../Interface/IDoppiOpportunity.sol";
import {DoppiOpportunity} from "./DoppiOpportunity.sol";
import {DALiquidityLib} from "../Library/DALiquidityLib.sol";
import "./DoppiCoreTypes.sol";
import "./DoppiCoreAdmin.sol";
import "./DoppiCoreView.sol";
// import "forge-std/console.sol";

contract DoppiCore is DoppiCoreAdmin, DoppiCoreView, ReentrancyGuard, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    bytes4 constant SWAP_SELECTOR = bytes4(keccak256("swap(uint256,uint256,bool)"));
    bytes4 constant PRICE_SELECTOR = bytes4(keccak256("getPrice()"));
    bytes4 constant SETTLE_SELECTOR = bytes4(keccak256("settle(uint256,uint256,uint256,bool)"));
    bytes4 constant INTEREST_SELECTOR = bytes4(keccak256("interestGet(address,uint256,uint256)"));
    bytes4 constant RECORD_SELECTOR = bytes4(keccak256("recordTrade(address,uint256)"));
    bytes4 constant OPP_SET_BUY_SELECTOR = bytes4(keccak256("setOpportunityBuy(uint256,uint256,uint256,uint256)"));
    bytes4 constant OPP_SET_SELL_SELECTOR = bytes4(keccak256("setOpportunitySell(uint256,uint256,uint256,uint256)"));
    bytes4 constant OPP_ADD_BUY_SELECTOR = bytes4(keccak256("addOpportunityBuyAmount(uint256,uint256)"));
    bytes4 constant OPP_ADD_SELL_SELECTOR = bytes4(keccak256("addOpportunitySellAmount(uint256,uint256)"));
    bytes4 constant OPP_SUB_BUY_SELECTOR = bytes4(keccak256("subtractOpportunityBuy(uint256,uint256,uint256)"));
    bytes4 constant OPP_SUB_SELL_SELECTOR = bytes4(keccak256("subtractOpportunitySell(uint256,uint256,uint256)"));
    bytes4 constant OPP_GET_SELECTOR = bytes4(keccak256("getOpportunityOrders(bool,uint256)"));
    bytes4 constant OPP_REDUCE_SELECTOR = bytes4(keccak256("reduceOpportunityOrder(bool,uint256,uint256)"));
    bytes4 constant FEE_POOL_NOTIFY_SELECTOR = bytes4(keccak256("onFeeReceived(address,uint256)"));

    IERC20 public assetA;
    IERC20 public assetB;
    IDoppiOffer public doppiOffer;
    IDoppiPoints public doppiPoints;

    // Tracks unsettled per-token liabilities stored in pending settlements.
    uint256 public totalPendingLiabilityA;
    uint256 public totalPendingLiabilityB;

    uint32 private constant SECONDS_PER_YEAR = 31536000;
    uint24 private constant SECONDS_PER_DAY = 86400;
    uint16 private constant BASIS_POINTS = 10000;
    
    event Deposited(address indexed trader, uint64 positionId, address asset, uint256 amount, uint256 interest, uint256 strikePrice, uint32 apr, uint8 numDays);
    event Settled(address indexed trader, uint64 positionId, bool striked, uint256 strikePrice, uint256 marketPrice, bool isProfit, uint256 profitLoss, uint256 payout, uint256 interest, address payoutToken, address interestToken);
    event EmergencyWithdraw(bool isBuy, address indexed trader, uint64 positionId, uint256 amount);
    event OppPerformed(bool isBuy, uint256 price, uint256 amount, uint256 amountOut);
    event OppUnwindPerformed(bool isBuy, uint256 price, uint256 swappedAmount, uint256 amountOut, uint256 profit, address profitToken);
    event PendingSettlementCreated(
        uint256 indexed pendingId,
        address indexed owner
    );
    event PendingSettlementClaimed(
        uint256 indexed pendingId,
        address indexed owner,
        uint256 paidPayout,
        uint256 paidInterest,
        bool fullyClaimed
    );
    event EmergencySnapshotLocked(uint256 priceE8, uint256 assetA, uint256 assetB, uint256 totalBuy, uint256 totalSell, uint256 totalWeightA);
    event EmergencyCoreWithdraw(address indexed owner, uint256 buyPrincipal, uint256 sellPrincipal, uint256 payoutA, uint256 payoutB, uint256 processed);
    
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
    error NoPositionsToSettle();
    error DayAlreadyRegistered();
    error OpportunityMutateFailed();
    error PendingNotFound();
    error NotPendingOwner();
    error NotEmergencyMode();
    error EmergencySnapshotNotLocked();
    error InvalidEmergencyConfig();

    constructor(address _assetA, address _assetB, IDoppiLiquidity _doppiLP, IDoppiOffer _doppiOffer, address _doppiPoints)
        Ownable(msg.sender)
    {
        DoppiOpportunity opportunityStore = new DoppiOpportunity(address(this), address(_doppiLP));
        _initializeDoppiCore(
            _assetA,
            _assetB,
            _doppiLP,
            _doppiOffer,
            _doppiPoints,
            msg.sender,
            address(opportunityStore)
        );
    }

    /// @notice Internal initialization logic used by constructor deployment.
    function _initializeDoppiCore(
        address _assetA,
        address _assetB,
        IDoppiLiquidity _doppiLP,
        IDoppiOffer _doppiOffer,
        address _doppiPoints,
        address _owner,
        address _doppiOpportunity
    ) internal {
        assetA = IERC20(_assetA);
        assetB = IERC20(_assetB);
        doppiLP = _doppiLP;
        doppiOffer = _doppiOffer;
        priceDecimal = 10 ** _doppiLP.getPriceDecimals();
        doppiPoints = IDoppiPoints(_doppiPoints);
        doppiOpportunity = IDoppiOpportunity(_doppiOpportunity);
        opportunityBots[_owner] = true;

        supportDays.push(1);
        nextProcessId[1] = 1;
        nextPositionId[1] = 1;

        minOrderA = 50 ether; 
        minOrderB = 0.0005 ether; 
        UPKEEPS_PER_CHECK = 10; 
        aprToleranceBP = 1000; 
        maxSwap = 100000 ether;
        
        _transferOwnership(_owner);
    }

    // Single deposit functionality
    function deposit_buy(DepositParams calldata params) 
        external nonReentrant whenNotPaused {
        
        if (emergencyMode) revert EmergencyModeActive();
        if(params.amount < minOrderA) revert InvalidAmount(); 
        if (!canAcceptDeposit(true, params.amount)) {
            revert ExceedsPoolCap();
        }
        DualAssetOffer memory buyOffer = doppiOffer.getOffer(true, params.numDays, params.strikeZone);
        if(buyOffer.strikePrice != params.strikePrice || buyOffer.price == 0) revert InvalidStrikePriceOrPrice();
        if(!_isAPRWithinTolerance(buyOffer.apr, params.apr)) revert InvalidAPR();
        
        _depositBuy(params, buyOffer);
        // record for points
        if(!doppiPoints.paused()){
            _recordTradePoints(msg.sender, params.amount);
        }
    }

    function deposit_sell(DepositParams calldata params) 
        external nonReentrant whenNotPaused {
        
        if (emergencyMode) revert EmergencyModeActive();
        if(params.amount < minOrderB) revert InvalidAmount(); 
        if (!canAcceptDeposit(false, params.amount)) {
            revert ExceedsPoolCap();
        }
        DualAssetOffer memory sellOffer = doppiOffer.getOffer(false, params.numDays, params.strikeZone);
        if(sellOffer.strikePrice != params.strikePrice) revert InvalidStrikePriceOrPrice();
        if(!_isAPRWithinTolerance(sellOffer.apr, params.apr)) revert InvalidAPR();
        _depositSell(params, sellOffer);
        // record for points
        if(!doppiPoints.paused()){
            uint256 tradeVolume = (params.amount * sellOffer.price) / priceDecimal; 
            _recordTradePoints(msg.sender, tradeVolume);
        }
    }

    function bulkDeposit(bool isBuy, BulkDepositParam[] calldata params, uint256 total) external whenNotPaused nonReentrant {
        
        _onlyTraderBot();
        uint256 length = params.length;
        if (length == 0) revert InvalidOfferLength();

        // Fetch price once — all per-slot getSingleOffer calls below are pure math
        uint256 price = _getPriceFromLP();
        uint256 zeroZoneAPR;
        DualAssetOffer memory offer;

        for (uint256 i = 0; i < length; ) {
            BulkDepositParam calldata param = params[i];
            if (param.amount == 0) revert InvalidAmount();
            // get the zone zero apr first
            if(param.strikeZone == 0){
                offer = doppiOffer.getSingleOffer(isBuy, param.numDays, param.strikeZone, price);
                zeroZoneAPR = offer.apr;
            }else{
                offer = doppiOffer.verifyOffer(isBuy, param.numDays, param.strikeZone, price, zeroZoneAPR);
            }
            if (offer.price == 0) revert InvalidStrikePriceOrPrice();
            if (offer.apr == 0) revert InvalidAPR();

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
        if(emergencyMode) return (false, bytes(""));
        uint256 price = doppiLP.getPrice();
        if(price == 0) return (false, bytes(""));

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
        if (emergencyMode) revert EmergencyModeActive(); 
        uint256 price = _getPriceFromLP();
        uint64 endPosId = _getReadyAllPositions(day);
        uint64 start = nextProcessId[day];
        if (!(endPosId >= start && endPosId != 0)) revert NoPositionsToSettle();
        _settlePositionsAggregated(day, start, endPosId, price);
    }

    function claimPendingSettlement(uint256 pendingId) external nonReentrant {
        PendingSettlement storage pending = pendingSettlements[pendingId];
        if (pending.owner == address(0)) revert PendingNotFound();

        address receiver = pending.owner;
        if (
            address(doppiTraderFactory) != address(0) &&
            doppiTraderFactory.isTraderBot(pending.owner)
        ) {
            address resolvedTrader = IDoppiTrader(pending.owner).validTrader();
            if (resolvedTrader != address(0)) {
                receiver = resolvedTrader;
            }
        }

        if (msg.sender != pending.owner && msg.sender != receiver) revert NotPendingOwner();
        if (pending.claimed) return;

        uint256 paidPayout;
        uint256 paidInterest;

        uint256 payoutToClaim = pending.pendingPayout;
        if (payoutToClaim > 0 && _attemptDirectTransfer(IERC20(pending.payoutToken), receiver, payoutToClaim)) {
            pending.pendingPayout = 0;
            _decreasePendingLiability(IERC20(pending.payoutToken), payoutToClaim);
            paidPayout = payoutToClaim;
        }

        uint256 interestToClaim = pending.pendingInterest;
        if (interestToClaim > 0 && _attemptTransferWithFee(IERC20(pending.interestToken), receiver, interestToClaim)) {
            pending.pendingInterest = 0;
            _decreasePendingLiability(IERC20(pending.interestToken), interestToClaim);
            paidInterest = interestToClaim;
        }

        if (pending.pendingPayout == 0 && pending.pendingInterest == 0) {
            pending.claimed = true;
        }

        emit PendingSettlementClaimed(
            pendingId,
            receiver,
            paidPayout,
            paidInterest,
            pending.claimed
        );
    }

    function setEmergencyMode(bool _emergency) public override onlyOwner whenPaused {
        super.setEmergencyMode(_emergency);
        if (_emergency) {
            unchecked { ++emergencyEpoch; }
            _lockEmergencySnapshot();
        } else {
            delete emergencySnapshot;
        }
    }

    function emergencyWithdrawCoreOnly(uint256 maxPositions, address receiver)
        external
        whenPaused
        nonReentrant
        returns (uint256 processed, uint256 remaining, uint256 payoutA, uint256 payoutB)
    {
        if (!emergencyMode) revert NotEmergencyMode();
        EmergencySnapshot memory snapshot = emergencySnapshot;
        if (!snapshot.locked) revert EmergencySnapshotNotLocked();
        if (maxPositions == 0) revert InvalidAmount();

        uint256 buyPrincipal;
        uint256 sellPrincipal;
        uint256 inspected;
        EmergencyCursor storage cursor = emergencyCursors[msg.sender];
        if (cursor.epoch != emergencyEpoch) {
            cursor.epoch = emergencyEpoch;
            cursor.dayIndex = 0;
            cursor.positionId = 0;
        }

        while (cursor.dayIndex < supportDays.length && inspected < maxPositions) {
            uint8 day = supportDays[cursor.dayIndex];
            uint64 head = nextProcessId[day];
            uint64 tail = nextPositionId[day];
            if (cursor.positionId < head) cursor.positionId = head;

            if (cursor.positionId >= tail) {
                unchecked { ++cursor.dayIndex; }
                cursor.positionId = 0;
                continue;
            }

            uint64 positionId = cursor.positionId;
            unchecked {
                cursor.positionId = positionId + 1;
                ++inspected;
            }

            DualAssetPosition storage buyPos = positions_buy[day][positionId];
            if (buyPos.owner == msg.sender && buyPos.amount > 0) {
                buyPrincipal += buyPos.amount;
                _removeOwnerPosition(buyPos.owner, buyPos.amount, true);
                _updateTotalDeposit(buyPos.amount, true);
                _removeInterestLiability(buyPos.interest, true);
                delete positions_buy[day][positionId];
                unchecked { ++processed; }
                continue;
            }

            DualAssetPosition storage sellPos = positions_sell[day][positionId];
            if (sellPos.owner == msg.sender && sellPos.amount > 0) {
                sellPrincipal += sellPos.amount;
                _removeOwnerPosition(sellPos.owner, sellPos.amount, false);
                _updateTotalDeposit(sellPos.amount, false);
                _removeInterestLiability(sellPos.interest, false);
                delete positions_sell[day][positionId];
                unchecked { ++processed; }
            }
        }

        remaining = _getBuyPositionCount(msg.sender) + _getSellPositionCount(msg.sender);
        if (buyPrincipal == 0 && sellPrincipal == 0) {
            return (processed, remaining, 0, 0);
        }

        // Defensive guard: snapshot lock already prevents zero totalWeightA,
        // but if storage is ever inconsistent we avoid a panic division by zero.
        if (snapshot.totalWeightA == 0) {
            emit EmergencyCoreWithdraw(msg.sender, buyPrincipal, sellPrincipal, 0, 0, processed);
            return (processed, remaining, 0, 0);
        }

        uint256 userWeightA = buyPrincipal + (sellPrincipal * uint256(snapshot.priceE8)) / 1e8;
        uint256 expectedPayoutA = (snapshot.assetA * userWeightA) / snapshot.totalWeightA;
        uint256 expectedPayoutB = (snapshot.assetB * userWeightA) / snapshot.totalWeightA;

        if (expectedPayoutA > 0) {
            assetA.safeTransfer(receiver, expectedPayoutA);
            payoutA = expectedPayoutA;
        }
        if (expectedPayoutB > 0) {
            assetB.safeTransfer(receiver, expectedPayoutB);
            payoutB = expectedPayoutB;
        }

        emit EmergencyCoreWithdraw(receiver, buyPrincipal, sellPrincipal, payoutA, payoutB, processed);
    }

    function addSupportDay(uint8 _day) external onlyOwner {
        for (uint256 i = 0; i < supportDays.length; i++) {
            if (supportDays[i] == _day) revert DayAlreadyRegistered();
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
        uint64 tail = nextPositionId[day];

        // Scan only inside the currently assigned ID range.
        // This preserves normal behavior while allowing skips over deleted holes.
        if (start >= tail) return 0;

        for (uint64 posId = start; posId < end && posId < tail; ) {
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
                // Deleted positions are safe to process as empty queue slots.
                endPositionId = posId;
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

    function _lockEmergencySnapshot() internal {
        if (emergencySnapshot.locked) return;
        uint256 priceE8 = doppiLP.getPrice();
        if (emergencyV3Pool != address(0) && emergencyTwapDuration > 0) {
            priceE8 = DALiquidityLib.getTWAPPrice(emergencyV3Pool, emergencyTwapDuration);
        }
        if (priceE8 == 0 || priceE8 > type(uint96).max) revert InvalidEmergencyConfig();

        uint256 currentAssetA = assetA.balanceOf(address(this));
        uint256 currentAssetB = assetB.balanceOf(address(this));
        uint256 snapshotAssetA = currentAssetA > totalPendingLiabilityA ? currentAssetA - totalPendingLiabilityA : 0;
        uint256 snapshotAssetB = currentAssetB > totalPendingLiabilityB ? currentAssetB - totalPendingLiabilityB : 0;
        uint256 snapshotTotalBuy = totalBuyDeposits;
        uint256 snapshotTotalSell = totalSellDeposits;
        uint256 snapshotTotalWeightA = snapshotTotalBuy + (snapshotTotalSell * priceE8) / 1e8;
        if (snapshotTotalWeightA == 0) revert InvalidEmergencyConfig();

        emergencySnapshot = EmergencySnapshot({
            assetA: snapshotAssetA,
            assetB: snapshotAssetB,
            totalBuy: snapshotTotalBuy,
            totalSell: snapshotTotalSell,
            totalWeightA: snapshotTotalWeightA,
            priceE8: uint96(priceE8),
            blockNumber: uint64(block.number),
            locked: true
        });

        emit EmergencySnapshotLocked(priceE8, snapshotAssetA, snapshotAssetB, snapshotTotalBuy, snapshotTotalSell, snapshotTotalWeightA);
    }

    function _processNewSettlements(
        uint8[] memory durationDay,
        uint64[] memory supportDaysPositions
    ) internal {
        
        uint256 price = _getPriceFromLP();
        uint256 length = durationDay.length;

        for (uint256 i = 0; i < length; ) {
            uint8 day = durationDay[i];
            uint64 start = nextProcessId[day];
            uint64 endPositionId = supportDaysPositions[i];
            _settlePositionsAggregated(day, start, endPositionId, price);
            unchecked { ++i; }
        }
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
        _addOwnerPosition(sender, amount, true);
        _addOpportunityAmount(_buyOffer.strikePrice, amount, true);
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
        _addOwnerPosition(sender, amount, false);
        _addOpportunityAmount(_sellOffer.strikePrice, amount, false);
        _updateInterestLiability(interest, false);
        emit Deposited(sender, positionId, address(assetB), amount, interest, _sellOffer.strikePrice, _sellOffer.apr, numDays);
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
    
    function _prepareSettlementPlan(
        uint8 day,
        uint64 start,
        uint64 end,
        uint256 price
    ) internal view returns (
        SettlementPlan[] memory plans,
        uint256 planCount,
        uint256 totalA,
        uint256 totalB,
        uint256 totalInterestA,
        uint256 totalInterestB
    ) {
        uint256 maxPositions = uint256(end - start) + 1;
        plans = new SettlementPlan[](maxPositions);

        // In-memory capacity tracking per distinct strike, seeded once from storage.
        // This prevents stale-read bugs when multiple positions share the same strike:
        // each position consumes from the remaining virtual pool, not from raw storage.
        uint256[] memory bStrike   = new uint256[](maxPositions);
        uint256[] memory bRemSwap  = new uint256[](maxPositions);
        uint256[] memory bRemOut   = new uint256[](maxPositions);
        uint256 bCount;
        uint256[] memory sStrike   = new uint256[](maxPositions);
        uint256[] memory sRemSwap  = new uint256[](maxPositions);
        uint256[] memory sRemOut   = new uint256[](maxPositions);
        uint256 sCount;

        for (uint64 posId = start; posId <= end; ) {
            if (_posExist(day, posId)) {
                (DualAssetPosition memory p, bool isBuy) = positions_buy[day][posId].amount > 0
                    ? (positions_buy[day][posId], true)
                    : (positions_sell[day][posId], false);

                bool striked = isBuy ? price <= p.strikePrice : price >= p.strikePrice;

                // Locate or register this strike in the in-memory cache.
                uint256 tradedPortion;
                uint256 myAmountOut;

                if (isBuy) {
                    uint256 idx = bCount; // sentinel: not found
                    for (uint256 k = 0; k < bCount; ) {
                        if (bStrike[k] == p.strikePrice) { idx = k; break; }
                        unchecked { ++k; }
                    }
                    if (idx == bCount) {
                        // First encounter for this buy strike — seed from storage
                        OpportunityOrders memory opp = _getOpportunityOrdersInternal(true, p.strikePrice);
                        bStrike[bCount]  = p.strikePrice;
                        bRemSwap[bCount] = opp.swappedAmount;
                        bRemOut[bCount]  = opp.outAmount;
                        unchecked { ++bCount; }
                        // idx still holds the old bCount value, which is the index just written
                    }
                    tradedPortion = bRemSwap[idx] < p.amount ? bRemSwap[idx] : p.amount;
                    myAmountOut   = bRemSwap[idx] > 0 ? bRemOut[idx] * tradedPortion / bRemSwap[idx] : 0;
                    bRemSwap[idx] -= tradedPortion;
                    bRemOut[idx]  = bRemOut[idx] > myAmountOut ? bRemOut[idx] - myAmountOut : 0;
                } else {
                    uint256 idx = sCount;
                    for (uint256 k = 0; k < sCount; ) {
                        if (sStrike[k] == p.strikePrice) { idx = k; break; }
                        unchecked { ++k; }
                    }
                    if (idx == sCount) {
                        OpportunityOrders memory opp = _getOpportunityOrdersInternal(false, p.strikePrice);
                        sStrike[sCount]  = p.strikePrice;
                        sRemSwap[sCount] = opp.swappedAmount;
                        sRemOut[sCount]  = opp.outAmount;
                        unchecked { ++sCount; }
                    }
                    tradedPortion = sRemSwap[idx] < p.amount ? sRemSwap[idx] : p.amount;
                    myAmountOut   = sRemSwap[idx] > 0 ? sRemOut[idx] * tradedPortion / sRemSwap[idx] : 0;
                    sRemSwap[idx] -= tradedPortion;
                    sRemOut[idx]  = sRemOut[idx] > myAmountOut ? sRemOut[idx] - myAmountOut : 0;
                }

                uint8 tradeState = tradedPortion == 0 ? 0 : (tradedPortion >= p.amount ? 2 : 1);

                plans[planCount] = SettlementPlan({
                    posId:         posId,
                    isBuy:         isBuy,
                    striked:       striked,
                    tradeState:    tradeState,
                    tradedPortion: tradedPortion,
                    myAmountOut:   myAmountOut
                });
                unchecked { ++planCount; }

                // Aggregate settle-call amounts: only the untraded portion of struck positions
                // needs a fresh swap via _doppiSettleCall.
                if (striked) {
                    uint256 untradedPortion = p.amount - tradedPortion;
                    if (untradedPortion > 0) {
                        if (isBuy) { totalA += untradedPortion; } else { totalB += untradedPortion; }
                    }
                }

                if (isBuy) {
                    totalInterestA += p.interest;
                } else {
                    totalInterestB += p.interest;
                }
            }
            unchecked { ++posId; }
        }
    }

    function _settlePositionsAggregated(
        uint8 day,
        uint64 start,
        uint64 end,
        uint256 price
    ) internal {
        (
            SettlementPlan[] memory plans,
            uint256 planCount,
            uint256 totalA,
            uint256 totalB,
            uint256 totalInterestA,
            uint256 totalInterestB
        ) = _prepareSettlementPlan(day, start, end, price);

        if (totalA > 0) {
            uint256 amountOutA = (totalA * priceDecimal) / price;
            _doppiSettleCall(totalA, amountOutA, price, true);
        }
        if (totalB > 0) {
            uint256 amountOutB = (totalB * price) / priceDecimal;
            _doppiSettleCall(totalB, amountOutB, price, false);
        }
        if (totalInterestA > 0) {
            _doppiInterestGet(assetA, totalInterestA, price);
        }
        if (totalInterestB > 0) {
            _doppiInterestGet(assetB, totalInterestB, price);
        }

        for (uint256 i = 0; i < planCount; ) {
            SettlementPlan memory plan = plans[i];
            _settlePositionWithPlan(day, plan.posId, price, plan.isBuy, plan.striked, plan.tradeState, plan.tradedPortion, plan.myAmountOut);
            unchecked { ++i; }
        }

        nextProcessId[day] = end + 1;
    }

    function _settlePositionWithPlan(
        uint8 day,
        uint64 posId,
        uint256 price,
        bool isBuy,
        bool striked,
        uint8 tradeState,
        uint256 tradedPortion,
        uint256 myAmountOut
    ) internal {
        DualAssetPosition memory p;
        if (isBuy) {
            p = positions_buy[day][posId];
            delete positions_buy[day][posId];
        } else {
            p = positions_sell[day][posId];
            delete positions_sell[day][posId];
        }

        if (p.expiryTimestamp > block.timestamp) revert NotExpired();

        _removeOwnerPosition(p.owner, p.amount, isBuy);
        _removeInterestLiability(p.interest, isBuy);
        _updateTotalDeposit(p.amount, isBuy);

        IERC20 payoutToken;
        IERC20 interestToken;
        bool isProfit;
        uint256 profitLoss;

        if (striked) {
            (payoutToken, interestToken) = isBuy ? (assetB, assetA) : (assetA, assetB);
            (isProfit, profitLoss) = _settleStrikePlanned(p, price, isBuy, tradeState, tradedPortion, myAmountOut, payoutToken);
        } else {
            (payoutToken, interestToken) = isBuy ? (assetA, assetA) : (assetB, assetB);
            (isProfit, profitLoss) = _settleNoStrikePlanned(p, price, isBuy, tradeState, tradedPortion, myAmountOut, payoutToken);
        }

        _reduceOpportunityOrder(p.strikePrice, p.amount, isBuy);

        uint256 payoutAmount = striked ? p.payout : p.amount;
        uint256 pendingPayout;
        uint256 pendingInterest;

        if (payoutAmount > 0 && !_attemptDirectTransfer(payoutToken, p.owner, payoutAmount)) {
            pendingPayout = payoutAmount;
        }
        if (p.interest > 0 && !_attemptTransferWithFee(interestToken, p.owner, p.interest)) {
            pendingInterest = p.interest;
        }

        if (pendingPayout > 0 || pendingInterest > 0) {
            _storePendingSettlement(
                p.owner,
                p.strikePrice,
                price,
                payoutToken,
                interestToken,
                pendingPayout,
                pendingInterest
            );
        }

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

    function _settleStrikePlanned(
        DualAssetPosition memory p,
        uint256 price,
        bool isBuy,
        uint8 tradeState,
        uint256 tradedPortion,
        uint256 myAmountOut,
        IERC20 payoutToken
    ) internal returns (bool isProfit, uint256 profitLoss) {
        uint256 payout = p.payout;

        if (tradeState == 0) {
            // Scenario 1: Strike + Not Traded
            // LP sent proceeds for the full amount via the aggregated _doppiSettleCall.
            uint256 amountOut = isBuy ? (p.amount * priceDecimal) / price : (p.amount * price) / priceDecimal;
            uint256 settleprofit = amountOut > payout ? amountOut - payout : 0;
            if (settleprofit > 0) {
                _safeTransferWithFee(payoutToken, address(doppiLP), settleprofit);
                unchecked { profitLoss = settleprofit; }
                isProfit = true;
            }
        } else {
            // Scenario 2 (fully traded) or Scenario partial:
            // myAmountOut and tradedPortion were pre-allocated during planning so they
            // never double-count across positions sharing the same strike.
            uint256 untradedPortion = p.amount - tradedPortion;
            // Proceeds from the untraded slice arrived via the aggregated _doppiSettleCall.
            uint256 payoutFromSettle = untradedPortion > 0
                ? (isBuy ? (untradedPortion * priceDecimal) / price : (untradedPortion * price) / priceDecimal)
                : 0;

            uint256 totalProceeds = myAmountOut + payoutFromSettle;
            uint256 notenough = payout > totalProceeds ? payout - totalProceeds : 0;
            if (notenough > 0) {
                _doppiInterestGet(payoutToken, notenough, price);
            } else {
                uint256 settleprofit = totalProceeds - payout;
                if (settleprofit > 0) {
                    _safeTransferWithFee(payoutToken, address(doppiLP), settleprofit);
                    unchecked { profitLoss = settleprofit; }
                    isProfit = true;
                }
            }

            // Reduce opp storage by the pre-allocated amounts (ordered reduction is safe
            // because planning already consumed exactly these values from the in-memory cache).
            _subtractOpportunityTrade(p.strikePrice, tradedPortion, myAmountOut, isBuy);
        }

        _createTraderBotUnwindPosition(p, isBuy);
    }

    function _settleNoStrikePlanned(
        DualAssetPosition memory p,
        uint256 price,
        bool isBuy,
        uint8 tradeState,
        uint256 tradedPortion,
        uint256 myAmountOut,
        IERC20 payoutToken
    ) internal returns (bool isProfit, uint256 profitLoss) {
        if (tradeState == 0) {

            uint256 bal = payoutToken.balanceOf(address(this));
            uint256 notenough = bal > p.amount ? 0 : p.amount - bal;
            if(notenough > 0) {
                _doppiInterestGet(payoutToken, notenough, price);
            }
        } else {
            // Scenario 4 (fully traded) or partial:
            // myAmountOut and tradedPortion are pre-allocated from the planning phase.
            // For partial: untradedPortion sits in this contract already; only swap back the traded slice.
            // For fully traded: tradedPortion == p.amount, same logic applies uniformly.
            uint256 amountInOrig = _swapLowLevel(myAmountOut, price, !isBuy);

            // Compare recovered against tradedPortion only (untradedPortion needs no swap).
            if (amountInOrig >= tradedPortion) {
                unchecked { profitLoss = amountInOrig - tradedPortion; }
                isProfit = true;
                _safeTransferWithFee(payoutToken, address(doppiLP), profitLoss);
            } else {
                uint256 notenough = tradedPortion - amountInOrig;
                _doppiInterestGet(payoutToken, notenough, price);
            }
            _subtractOpportunityTrade(p.strikePrice, tradedPortion, myAmountOut, isBuy);
        }
    }

    function _storePendingSettlement(
        address owner,
        uint256 strikePrice,
        uint256 settlePrice,
        IERC20 payoutToken,
        IERC20 interestToken,
        uint256 pendingPayout,
        uint256 pendingInterest
    ) internal {
        uint256 pendingId = nextPendingSettlementId;
        unchecked { ++nextPendingSettlementId; }

        pendingSettlements[pendingId] = PendingSettlement({
            owner: owner,
            strikePrice: strikePrice,
            settlePrice: settlePrice,
            payoutToken: address(payoutToken),
            interestToken: address(interestToken),
            pendingPayout: pendingPayout,
            pendingInterest: pendingInterest,
            claimed: false
        });
        pendingSettlementIdsByOwner[owner].push(pendingId);

        if (pendingPayout > 0) {
            _increasePendingLiability(payoutToken, pendingPayout);
        }
        if (pendingInterest > 0) {
            _increasePendingLiability(interestToken, pendingInterest);
        }

        emit PendingSettlementCreated(
            pendingId,
            owner
        );
    }

    function _posExist(uint8 day, uint64 posId) internal view returns (bool) {
        return positions_buy[day][posId].amount > 0 || positions_sell[day][posId].amount > 0;
    }

    function opportunitySwap(uint256 amountIn, uint256 price, bool isBuy)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (emergencyMode) revert EmergencyModeActive();
        _checkOpportunityBot();
        return _swapLowLevel(amountIn, price, isBuy);
    }

    function executeOpportunityStep(
        uint256 totalAmount,
        uint256 totalAmountOut,
        uint256 price,
        uint256 reduced,
        uint256 reducedout,
        bool isBuy,
        uint256 strikePrice
    ) external nonReentrant returns (uint256 reducedUpdated, uint256 reducedoutUpdated) {
        
        if (emergencyMode) revert EmergencyModeActive();
        _checkOpportunityBot();
        return _executeOpportunity(totalAmount, totalAmountOut, price, reduced, reducedout, isBuy, strikePrice);
    }

    function executeUnwindStep(
        uint256 totalAmountUnwind,
        uint256 amountOutUnwind,
        uint256 price,
        uint256 reduced,
        uint256 reducedout,
        bool isBuy,
        uint256 strikePrice
    ) external nonReentrant returns (uint256 reducedUpdated, uint256 reducedoutUpdated) {
        
        if (emergencyMode) revert EmergencyModeActive();
        _checkOpportunityBot();
        return _executeUnwind(totalAmountUnwind, amountOutUnwind, price, reduced, reducedout, isBuy, strikePrice);
    }

    function _increasePendingLiability(IERC20 token, uint256 amount) internal {
        if (address(token) == address(assetA)) {
            totalPendingLiabilityA += amount;
        } else if (address(token) == address(assetB)) {
            totalPendingLiabilityB += amount;
        }
    }

    function _decreasePendingLiability(IERC20 token, uint256 amount) internal {
        if (address(token) == address(assetA)) {
            totalPendingLiabilityA = totalPendingLiabilityA >= amount ? totalPendingLiabilityA - amount : 0;
        } else if (address(token) == address(assetB)) {
            totalPendingLiabilityB = totalPendingLiabilityB >= amount ? totalPendingLiabilityB - amount : 0;
        }
    }

    function _executeOpportunity(
        uint256 totalAmount,
        uint256 totalAmountOut,
        uint256 price,
        uint256 reduced,
        uint256 reducedout,
        bool isBuy,
        uint256 strikePrice
    ) internal returns (uint256 reducedUpdated, uint256 reducedoutUpdated) {
        
        OpportunityOrders memory order = _getOpportunityOrdersInternal(isBuy, strikePrice);
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
        _setOpportunityOrders(strikePrice, order.amount, order.swappedAmount, order.outAmount, isBuy);
        emit OppPerformed(isBuy, price, amount, myAmountOut);
    }

    function _executeUnwind(
        uint256 totalAmountUnwind,
        uint256 amountOutUnwind,
        uint256 price,
        uint256 reduced,
        uint256 reducedout,
        bool isBuy,
        uint256 strikePrice
    ) internal returns (uint256 reducedUpdated, uint256 reducedoutUpdated){

        OpportunityOrders memory order = _getOpportunityOrdersInternal(isBuy, strikePrice);
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
        _setOpportunityOrders(strikePrice, order.amount, order.swappedAmount, order.outAmount, isBuy);
        emit OppUnwindPerformed(isBuy, price, unwind, myAmountOut, profit, address(profitToken));
    }

    function _reduceOpportunityOrder(uint256 strikePrice, uint256 amount, bool isBuy) internal {
        if (address(doppiOpportunity) == address(0)) revert NotExist();
        _opportunityReduceOrderLowLevel(isBuy, strikePrice, amount);
    }

    function _getOpportunityOrdersInternal(bool isBuy, uint256 strikePrice) internal view virtual returns (OpportunityOrders memory) {
        if (address(doppiOpportunity) == address(0)) revert NotExist();
        return _opportunityGetOrdersLowLevel(isBuy, strikePrice);
    }

    function _setOpportunityOrders(
        uint256 strikePrice,
        uint256 amount,
        uint256 swappedAmount,
        uint256 outAmount,
        bool isBuy
    ) internal virtual {
        if (address(doppiOpportunity) == address(0)) revert NotExist();
        _opportunitySetOrdersLowLevel(strikePrice, amount, swappedAmount, outAmount, isBuy);
    }

    function _addOpportunityAmount(uint256 strikePrice, uint256 amount, bool isBuy) internal virtual {
        if (address(doppiOpportunity) == address(0)) revert NotExist();
        _opportunityAddAmountLowLevel(strikePrice, amount, isBuy);
    }

    function _subtractOpportunityTrade(
        uint256 strikePrice,
        uint256 subtractSwapped,
        uint256 subtractOut,
        bool isBuy
    ) internal virtual {
        if (address(doppiOpportunity) == address(0)) revert NotExist();
        _opportunitySubtractTradeLowLevel(strikePrice, subtractSwapped, subtractOut, isBuy);
    }

    function _safeTransferWithFee(IERC20 _asset, address _to, uint256 _amount) internal {
        
        uint256 amountFee = _amount * treasury_fee / 10000;
        uint256 amountAfterFee = _amount - amountFee;
        _asset.safeTransfer(_to, amountAfterFee);
        if (amountFee > 0) {
            _asset.safeTransfer(treasury, amountFee);
            if (treasury.code.length > 0) {
                // Best-effort hook for DoppiFeePool immediate split; ignore failures.
                (bool ok, ) = treasury.call(abi.encodeWithSelector(FEE_POOL_NOTIFY_SELECTOR, address(_asset), amountFee));
                if (!ok) {
                    // no-op
                }
            }
        }
    }

    function selfTransferWithFee(IERC20 token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert NotOpen();
        _safeTransferWithFee(token, to, amount);
    }

    function _attemptDirectTransfer(IERC20 token, address to, uint256 amount) internal returns (bool) {
        if (amount == 0) return true;
        (bool ok, bytes memory ret) = address(token).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    function _attemptTransferWithFee(IERC20 token, address to, uint256 amount) internal returns (bool) {
        if (amount == 0) return true;
        try this.selfTransferWithFee(token, to, amount) {
            return true;
        } catch {
            return false;
        }
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

        IERC20 assetIn = isBuy ? assetA : assetB;
        _ensureLPAllowance(assetIn, amountIn);

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

    function _opportunityGetOrdersLowLevel(bool isBuy, uint256 strikePrice)
        internal
        view
        returns (OpportunityOrders memory order)
    {
        (bool ok, bytes memory ret) = address(doppiOpportunity).staticcall(
            abi.encodeWithSelector(OPP_GET_SELECTOR, isBuy, strikePrice)
        );
        if (!(ok && ret.length >= 96)) revert OpportunityViewFailed();
        order = abi.decode(ret, (OpportunityOrders));
    }

    function _opportunitySetOrdersLowLevel(
        uint256 strikePrice,
        uint256 amount,
        uint256 swappedAmount,
        uint256 outAmount,
        bool isBuy
    ) internal {
        bytes4 selector = isBuy ? OPP_SET_BUY_SELECTOR : OPP_SET_SELL_SELECTOR;
        (bool ok, ) = address(doppiOpportunity).call(
            abi.encodeWithSelector(selector, strikePrice, amount, swappedAmount, outAmount)
        );
        if (!ok) revert OpportunityMutateFailed();
    }

    function _opportunityAddAmountLowLevel(uint256 strikePrice, uint256 amount, bool isBuy) internal {
        bytes4 selector = isBuy ? OPP_ADD_BUY_SELECTOR : OPP_ADD_SELL_SELECTOR;
        (bool ok, ) = address(doppiOpportunity).call(abi.encodeWithSelector(selector, strikePrice, amount));
        if (!ok) revert OpportunityMutateFailed();
    }

    function _opportunitySubtractTradeLowLevel(
        uint256 strikePrice,
        uint256 subtractSwapped,
        uint256 subtractOut,
        bool isBuy
    ) internal {
        bytes4 selector = isBuy ? OPP_SUB_BUY_SELECTOR : OPP_SUB_SELL_SELECTOR;
        (bool ok, ) = address(doppiOpportunity).call(
            abi.encodeWithSelector(selector, strikePrice, subtractSwapped, subtractOut)
        );
        if (!ok) revert OpportunityMutateFailed();
    }

    function _opportunityReduceOrderLowLevel(bool isBuy, uint256 strikePrice, uint256 amount) internal {
        (bool ok, ) = address(doppiOpportunity).call(
            abi.encodeWithSelector(OPP_REDUCE_SELECTOR, isBuy, strikePrice, amount)
        );
        if (!ok) revert OpportunityMutateFailed();
    }

    function _doppiSettleCall(uint256 amount, uint256 payout, uint256 price, bool isBuy) internal returns (uint256 out) {

        IERC20 assetIn = isBuy ? assetA : assetB;
        _ensureLPAllowance(assetIn, amount);

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

    function _ensureLPAllowance(IERC20 token, uint256 required) internal {
        if (required == 0) return;
        token.forceApprove(address(doppiLP), required);
    }

    function _doppiInterestGet(
            IERC20 interestToken,
            uint256 interest,
            uint256 price
        ) internal {

        (bool ok, ) = address(doppiLP).call(
            abi.encodeWithSelector(INTEREST_SELECTOR, address(interestToken), interest, price)
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
}