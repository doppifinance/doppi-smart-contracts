// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IDoppiCore} from "../Interface/IDoppiCore.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IDoppiOffer} from "../Interface/IDoppiOffer.sol";
import {IDoppiLiquidityRouter} from "../Interface/IDoppiLiquidityRouter.sol";
import {IPrivateAutomationHub} from "../Interface/IPrivateAutomationHub.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DualAssetPosition, StrikeNode, BulkDepositParam, DualAssetOffer} from "./DoppiCoreTypes.sol";
import {BotBillingState} from "./private/PrivateAutomationHubTypes.sol";
import {OrderConfig, UndoStat} from "./DoppiTraderTypes.sol";

// import "forge-std/console.sol";


abstract contract DoppiTraderAdminView is Ownable, Pausable {

    using SafeERC20 for IERC20;
    uint16 private constant FEE_BPS_DENOMINATOR = 10000;
    uint16 private constant BUDGET_BPS_DENOMINATOR = 10000;
    bytes4 private constant FEE_POOL_NOTIFY_SELECTOR = bytes4(keccak256("onFeeReceived(address,uint256)"));

    struct StrikePnLView {
        uint256 strikePrice;
        uint256 unwindAmount;
        uint256 currentValue;
        uint256 entryValue;
        uint256 averageCost;
        int256 pnl;
    }

    event FeePaid(address indexed token, uint256 amount);
    
    IERC20 public assetA;
    IERC20 public assetB;
    IPrivateAutomationHub public privateAutomationHub;
    IDoppiLiquidity public doppiLP;
    IDoppiCore public doppiCore;
    IDoppiLiquidityRouter public doppiRouter;
    IDoppiOffer public impliedVol;

    mapping(uint256 => uint256) public unWindBuy;
    mapping(uint256 => uint256) public unWindSell;
    mapping(uint256 => StrikeNode) internal buyStrikeNodes;
    mapping(uint256 => StrikeNode) internal sellStrikeNodes;

    address public validTrader;
    address public s_forwarderAddress;
    uint8 public traderDefaultDay;
    uint24 public maxOrder;
    uint32 public ratioLP;
    uint256 public totalUnits;   // scaled 1e18; cumulative units issued across all start() calls
    uint256 public totalUnitsB;   // scaled 1e18; cumulative units issued across all start() calls
    uint256 public costBasis;    // lifetime deposits converted to assetA terms
    uint256 public costBasisB;    // lifetime deposits converted to assetB terms
    uint256 internal buyHead;
    uint256 internal buyTail;
    uint256 internal sellHead;
    uint256 internal sellTail;
    uint256 internal activeBuyStrikeCount;
    uint256 internal activeSellStrikeCount;
    uint256 public maxSwap;
    uint8 public unwindGapMultiplier;
    uint16 public profitFeeBps;
    uint256 public maxOrderPerRoundA;
    uint256 public maxOrderPerRoundB;
    uint256 priceDecimals;
    UndoStat public undoStat;
    OrderConfig[] public orderConfigs;
    

    error NotValidTrader();
    error NotValidTraderOrUpkeep();
    error InsufficientTopUpAmount();
    error InvalidPrice();
    
    function getTotalBalancesInLP() external view returns (uint256 totalAssetA, uint256 totalAssetB) {
        return doppiLP.getBalances(address(this));
    }

    function getTotalBalances() public view returns (uint256 totalAssetA, uint256 totalAssetB, uint256 price) {
        
        price = doppiLP.getPrice();
        
        totalAssetA = assetA.balanceOf(address(this));
        totalAssetB = assetB.balanceOf(address(this));
        
        (uint256 totalLPAssetA, uint256 totalLPAssetB) = doppiLP.getBalances(address(this));
        totalAssetA += totalLPAssetA;
        totalAssetB += totalLPAssetB;

        if(address(doppiCore) != address(0)) {
            DualAssetPosition[] memory buyPositions = doppiCore.get_positions_buy(address(this));
            uint256 length = buyPositions.length;
            for (uint256 i = 0; i < length; ) {
                totalAssetA += buyPositions[i].amount;
                unchecked { ++i; }
            }
            DualAssetPosition[] memory sellPositions = doppiCore.get_positions_sell(address(this));
            length = sellPositions.length;
            for (uint256 i = 0; i < length; ) {
                totalAssetB += sellPositions[i].amount;
                unchecked { ++i; }
            }
        }
        
    }

    function getPerformanceMultipliers() external view returns (uint256 multiplierA, uint256 multiplierB, uint256 unitPriceA, uint256 unitPriceB) {
        
        uint256 price = doppiLP.getPrice();
        if(price == 0) return (1e18, 1e18, 1e18, 1e18);

        (uint256 currentA, uint256 currentB, ) = getTotalBalances();

        // Convert B values to A using current price
        uint256 currentBInA = (currentB * price) / priceDecimals;
        uint256 currentAInB = (currentA * priceDecimals ) / price;

        uint256 totalValueA = currentA + currentBInA;
        uint256 totalValueB = currentB + currentAInB;

        multiplierA = (costBasis == 0) ? 0 : currentA * 1e18 / costBasis;
        multiplierB = (costBasisB == 0) ? 0 : currentB * 1e18 / costBasisB;
        unitPriceA = (totalUnits == 0) ? 1e18 : (totalValueA * 1e18) / totalUnits;
        unitPriceB = (totalUnitsB == 0) ? 1e18 : (totalValueB * 1e18) / totalUnitsB;
    }

    function get_unrealized_PNL() external view returns (int256 pnl) {
        uint256 price = doppiLP.getPrice();

        (, int256 buyPnl, ) = _buildStrikePnLView(true, price);
        (, int256 sellPnl, ) = _buildStrikePnLView(false, price);

        pnl = buyPnl + (sellPnl * int256(price)) / int256(priceDecimals);
    }

    function getStrikePnL(bool isBuy)
        external
        view
        returns (StrikePnLView[] memory items, int256 totalPnl, uint256 currentPrice)
    {
        currentPrice = doppiLP.getPrice();
        return _buildStrikePnLView(isBuy, currentPrice);
    }

    function getOrderConfigs() external view returns (OrderConfig[] memory) {
        return orderConfigs;
    }

    function setPause() external {
        _onlyTrader();
        _pause();
    }

    function setUnPause() external {
        _onlyTrader();
        _unpause();
    }

    function setDefaultDay(uint8 _day) external {
        _onlyTrader();
        bool valid;
        uint8[] memory supportDays = doppiCore.supportDays();
        for (uint8 x = 0; x < supportDays.length; ) {
            if (supportDays[x] == _day) { valid = true; break; }
            unchecked { ++x; }
        }
        if(valid){
            traderDefaultDay = _day;
        }
    }

    function setMaxOrder(uint24 _maxOrder) external {
        _onlyTrader();
        require(_maxOrder > 0 && _maxOrder <= impliedVol.TOTAL_OFFER(), "exceeds total offers");
        maxOrder = _maxOrder;
    }

    function setMaxSwap(uint256 _maxSwap) external {
        _onlyTrader();
        maxSwap = _maxSwap;
    }

    function setUnwindGapMultiplier(uint8 _multiplier) external {
        _onlyTrader();
        unwindGapMultiplier = _multiplier;
    }

    function setMaxOrderPerRound(uint256 _maxOrderPerRoundA, uint256 _maxOrderPerRoundB) external {
        _onlyTrader();
        maxOrderPerRoundA = _maxOrderPerRoundA;
        maxOrderPerRoundB = _maxOrderPerRoundB;
    }

    function _getRoundBudget(bool isBuy, uint256 availableBalance, uint256 minOrder, uint256 length)
        internal
        view
        returns (uint256 budget)
    {
        if (availableBalance == 0) return 0;

        uint256 sideMaxSwap = _getSideMaxSwap(isBuy);
        if (sideMaxSwap == 0) return 0;

        uint256 cap = isBuy ? maxOrderPerRoundA : maxOrderPerRoundB;
        if (cap > 0) {
            uint256 available = availableBalance < cap ? availableBalance : cap;
            return available > sideMaxSwap ? sideMaxSwap : available;
        }

        uint256 autoBudget = _getAutoRoundBudget(availableBalance, minOrder, length);
        return autoBudget > sideMaxSwap ? sideMaxSwap : autoBudget;
    }

    function _initializeOrderConfigs(uint24[] memory _weights) internal {
        uint256 length = _weights.length;

        for (uint256 i = length; i > 0; ) {
            unchecked { --i; }
            if(_weights[i] > 0) {
                orderConfigs.push(OrderConfig(uint8(i), _weights[i]));
            }
        }
    }

    function _availableBalance(bool _isBuy) internal view returns (uint256 availableAmount) {
        uint256 balance;
        uint256 undoAmount;
        if (_isBuy) {
            balance = assetA.balanceOf(address(this));
            undoAmount = undoStat.undo_assetA;
        } else {
            balance = assetB.balanceOf(address(this));
            undoAmount = undoStat.undo_assetB;
        }
        if (balance <= undoAmount) return 0;
        availableAmount = balance - undoAmount;
    }

    function setForwarderAddress(address forwarderAddress) external {
        _onlyTraderOrOwner();
        s_forwarderAddress = forwarderAddress;
    }

    function setPrivateAutomationHub(address _privateHub) external onlyOwner {
        privateAutomationHub = IPrivateAutomationHub(_privateHub);
    }

    function getUnwindInfo(bool isBuy, uint256 strikePrice) external view returns (uint256) {
        return isBuy ? unWindBuy[strikePrice] : unWindSell[strikePrice];
    }

    function getLowerUpperBound() public view returns (uint256 lower, uint256 upper) {
        
        lower = buyHead == 0
            ? sellHead
            : sellHead == 0
                ? buyHead
                : (buyHead < sellHead ? buyHead : sellHead);

        upper = buyTail > sellTail ? buyTail : sellTail;
        return (lower, upper);
    }


    function _calcPnL(uint256 price, bool isBuy)
        internal view returns (int256 pnl) {
        
        // uint256 decimals = 10 ** doppiLP.getPriceDecimals();
        mapping(uint256 => StrikeNode) storage strikeNodes = isBuy ? buyStrikeNodes : sellStrikeNodes;
        uint256 strikePrice = isBuy ? buyHead : sellHead;
        
        while (strikePrice != 0) {
            uint256 nextStrike = strikeNodes[strikePrice].next;
            uint256 unwindAmount = _getUnwindAmount(isBuy, strikePrice);
            uint256 currentValue = _getUnwindCurrentValue(isBuy, unwindAmount, price);
            uint256 entryValue = _getUnwindEntryValue(isBuy, strikePrice, unwindAmount);
            pnl += int256(currentValue) - int256(entryValue);
            strikePrice = nextStrike;
        }
    }

    function _buildStrikePnLView(bool isBuy, uint256 price)
        internal
        view
        returns (StrikePnLView[] memory items, int256 totalPnl, uint256 usedPrice)
    {
        mapping(uint256 => StrikeNode) storage strikeNodes = isBuy ? buyStrikeNodes : sellStrikeNodes;
        uint256 strikePrice = isBuy ? buyHead : sellHead;
        usedPrice = price;

        uint256 count;
        while (strikePrice != 0) {
            unchecked { ++count; }
            strikePrice = strikeNodes[strikePrice].next;
        }

        items = new StrikePnLView[](count);
        strikePrice = isBuy ? buyHead : sellHead;
        for (uint256 i = 0; i < count; ) {
            uint256 nextStrike = strikeNodes[strikePrice].next;
            uint256 unwindAmount = _getUnwindAmount(isBuy, strikePrice);
            uint256 currentValue = _getUnwindCurrentValue(isBuy, unwindAmount, price);
            uint256 entryValue = _getUnwindEntryValue(isBuy, strikePrice, unwindAmount);
            uint256 averageCost = _getUnwindAverageCost(isBuy, unwindAmount, entryValue);

            int256 pnl = int256(currentValue) - int256(entryValue);
            totalPnl += pnl;
            items[i] = StrikePnLView({
                strikePrice: strikePrice,
                unwindAmount: unwindAmount,
                currentValue: currentValue,
                entryValue: entryValue,
                averageCost: averageCost,
                pnl: pnl
            });

            strikePrice = nextStrike;
            unchecked { ++i; }
        }
    }

    function _getUnwindAmount(bool isBuy, uint256 strikePrice) internal view returns (uint256) {
        return isBuy ? unWindBuy[strikePrice] : unWindSell[strikePrice];
    }

    function _getUnwindCurrentValue(bool isBuy, uint256 unwindAmount, uint256 price) internal view returns (uint256) {
        return isBuy ? unwindAmount * price / priceDecimals : unwindAmount * priceDecimals / price;
    }

    function _getUnwindEntryValue(bool isBuy, uint256 strikePrice, uint256 unwindAmount)
        internal
        view
        virtual
        returns (uint256)
    {
        return isBuy ? unwindAmount * strikePrice / priceDecimals : unwindAmount * priceDecimals / strikePrice;
    }

    function _getStopProfitEntryValue(bool isBuy, uint256 strikePrice, uint256 unwindAmount)
        internal
        view
        virtual
        returns (uint256)
    {
        return _getUnwindEntryValue(isBuy, strikePrice, unwindAmount);
    }

    function _payFee(address token, uint256 profitAmount) internal {
        uint16 feeBps = profitFeeBps;
        if (_getFeePool() == address(0) || feeBps == 0 || profitAmount == 0) return;
        uint256 fee = (profitAmount * feeBps) / FEE_BPS_DENOMINATOR;
        _payFeeAmount(token, fee);
    }

    function _payFeeAmount(address token, uint256 fee) internal {
        address feePool = _getFeePool();
        if (feePool == address(0) || fee == 0) return;
        IERC20(token).safeTransfer(feePool, fee);
        if (feePool.code.length > 0) {
            (bool ok, ) = feePool.call(abi.encodeWithSelector(FEE_POOL_NOTIFY_SELECTOR, token, fee));
            if (!ok) {
                revert("FeePool notify failed");
            }
        }
        emit FeePaid(token, fee);
    }

    function _payStopProfitFees() internal {
        address feePool = _getFeePool();
        uint16 feeBps = profitFeeBps;
        if (feePool == address(0) || feeBps == 0) return;
        if (activeBuyStrikeCount == 0 && activeSellStrikeCount == 0) return;

        uint256 price = doppiLP.getPrice();
        if (price == 0) revert InvalidPrice();

        _payStopBuyProfitFees(price, feeBps);
        _payStopSellProfitFees(price, feeBps);
    }

    function _payStopBuyProfitFees(uint256 price, uint16 feeBps) internal {
        uint256 strike = buyHead;
        while (strike != 0) {
            uint256 nextStrike = buyStrikeNodes[strike].next;
            uint256 amountB = unWindBuy[strike];
            uint256 entryValueA = _getStopProfitEntryValue(true, strike, amountB);
            uint256 currentValueA = (amountB * price) / priceDecimals;

            if (currentValueA > entryValueA) {
                uint256 profitA = currentValueA - entryValueA;
                uint256 feeA = (profitA * feeBps) / FEE_BPS_DENOMINATOR;
                uint256 feeB = (feeA * priceDecimals) / price;
                _payFeeAmount(address(assetB), feeB);
            }

            strike = nextStrike;
        }
    }

    function _payStopSellProfitFees(uint256 price, uint16 feeBps) internal {
        uint256 strike = sellHead;
        while (strike != 0) {
            uint256 nextStrike = sellStrikeNodes[strike].next;
            uint256 amountA = unWindSell[strike];
            uint256 entryValueB = _getStopProfitEntryValue(false, strike, amountA);
            uint256 currentValueB = (amountA * priceDecimals) / price;

            if (currentValueB > entryValueB) {
                uint256 profitB = currentValueB - entryValueB;
                uint256 feeB = (profitB * feeBps) / FEE_BPS_DENOMINATOR;
                uint256 feeA = (feeB * price) / priceDecimals;
                _payFeeAmount(address(assetA), feeA);
            }

            strike = nextStrike;
        }
    }

    function _performTopUp(uint256 amountA, uint256 amountB)
        internal
        returns (uint256 finalAmountA, uint256 finalAmountB)
    {
        finalAmountA = amountA;
        finalAmountB = amountB;

        if (address(privateAutomationHub) == address(0)) return (finalAmountA, finalAmountB);

        BotBillingState memory botBilling = privateAutomationHub.getBotBilling(address(this));
        uint256 minCreditThreshold = privateAutomationHub.minCreditThreshold();
        if (botBilling.creditBalance > minCreditThreshold) return (finalAmountA, finalAmountB);

        uint256 defaultTopUp = privateAutomationHub.defaultTopUp();
        if (defaultTopUp == 0) return (finalAmountA, finalAmountB);

        IERC20 fundToken = privateAutomationHub.fundToken();
        
        if (address(fundToken) == address(assetA)) {
            if (amountA < defaultTopUp) revert InsufficientTopUpAmount();
            finalAmountA = amountA - defaultTopUp;
            assetA.safeIncreaseAllowance(address(privateAutomationHub), defaultTopUp);
        } else if (address(fundToken) == address(assetB)) {
            if (amountB < defaultTopUp) revert InsufficientTopUpAmount();
            finalAmountB = amountB - defaultTopUp;
            assetB.safeIncreaseAllowance(address(privateAutomationHub), defaultTopUp);
        } else {
            return (finalAmountA, finalAmountB);
        }

        privateAutomationHub.deposit(address(this), defaultTopUp);
    }

    function _getUnwindAverageCost(bool isBuy, uint256 unwindAmount, uint256 entryValue) internal view returns (uint256) {
        if (unwindAmount == 0 || entryValue == 0) return 0;
        return isBuy ? entryValue * priceDecimals / unwindAmount : unwindAmount * priceDecimals / entryValue;
    }

    function _getUnwindTargetPrice(uint256 _price, uint8 _zone, bool _isBuy) internal view returns (uint256) {
        
        uint256 priceGapWithDecimals = impliedVol.getPriceGapPerOffer() * priceDecimals;
        _price = (_price / priceGapWithDecimals) * priceGapWithDecimals;
        return _isBuy ? _price - (priceGapWithDecimals * (_zone - 1)) : _price + (priceGapWithDecimals * _zone);
    }

    function _syncStrikeState(uint256 strikePrice, bool isBuy) internal {
        uint256 unwindAmount = isBuy ? unWindBuy[strikePrice] : unWindSell[strikePrice];
        bool shouldBeActive = unwindAmount > 0;
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

    function _updateUnitAndCostBasis(
        uint256 depositAmountA,
        uint256 depositAmountB,
        uint256 currentBalanceA,
        uint256 currentBalanceB,
        uint256 price
    ) internal {
        uint256 depositValueInA = depositAmountA + ((depositAmountB * price) / priceDecimals);
        uint256 currentValueInA = currentBalanceA + ((currentBalanceB * price) / priceDecimals);
        if (depositValueInA > 0) {
            if (totalUnits == 0) {
                totalUnits = depositValueInA;
            } else if (currentValueInA > 0) {
                totalUnits += (depositValueInA * totalUnits) / currentValueInA;
            }
        }

        uint256 depositValueInB = depositAmountB + ((depositAmountA * priceDecimals) / price);
        uint256 currentValueInB = currentBalanceB + ((currentBalanceA * priceDecimals) / price);
        if (depositValueInB > 0) {
            if (totalUnitsB == 0) {
                totalUnitsB = depositValueInB;
            } else if (currentValueInB > 0) {
                totalUnitsB += (depositValueInB * totalUnitsB) / currentValueInB;
            }
        }

        costBasis += depositAmountA;
        costBasisB += depositAmountB;
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

    function _onlyTrader() internal view {
        if(msg.sender != validTrader) revert NotValidTrader();
    }

    function _onlyTraderOrOwner() internal view {
        if(msg.sender != validTrader && msg.sender != owner()) revert NotValidTrader();
    }

    function _getAutoRoundBudget(uint256 availableBalance, uint256 minOrder, uint256 length)
        internal
        view
        virtual
        returns (uint256 budget)
    {
        if (length == 0) return 0;
        uint256 configLength = orderConfigs.length;
        uint256 effectiveSlots = configLength < length ? configLength : length;
        if (effectiveSlots == 0) return 0;

        uint256 activeWeightSlots;
        for (uint256 i = 0; i < effectiveSlots; ) {
            if (_getOrderWeight(i) > 0) {
                unchecked { ++activeWeightSlots; }
            }
            unchecked { ++i; }
        }
        if (activeWeightSlots == 0) return 0;

        uint256 maxSplit = length < 5 ? length : 5;
        for (uint256 split = maxSplit; split > 0; ) {
            uint256 candidateBudget = availableBalance / split;
            if (candidateBudget > 0) {
                uint256 validCount = 0;
                for (uint256 i = 0; i < effectiveSlots; ) {
                    uint256 weight = _getOrderWeight(i);
                    uint256 depositAmount = (candidateBudget * weight) / BUDGET_BPS_DENOMINATOR;
                    if (depositAmount >= minOrder) {
                        unchecked { ++validCount; }
                    }
                    unchecked { ++i; }
                }
                uint256 requiredValid = split < activeWeightSlots ? split : activeWeightSlots;
                if (validCount >= requiredValid) {
                    return candidateBudget;
                }
            }
            unchecked { --split; }
        }

        return 0;
    }

    function _getSideMaxSwap(bool isBuy) internal view returns (uint256) {
        if (isBuy) return maxSwap;

        uint256 price = doppiLP.getPrice();
        if (price == 0) return 0;
        return (maxSwap * priceDecimals) / price;
    }

    function _getOrderWeight(uint256 index) internal view virtual returns (uint256);

    function _getFeePool() internal view virtual returns (address);

}
