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

// import "forge-std/console.sol";


abstract contract DoppiTraderAdminView is Ownable, Pausable {

    using SafeERC20 for IERC20;
    struct StrikePnLView {
        uint256 strikePrice;
        uint256 unwindAmount;
        uint256 currentValue;
        uint256 entryValue;
        uint256 averageCost;
        int256 pnl;
    }
    
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
    uint256 public maxOrderPerRoundA;
    uint256 public maxOrderPerRoundB;
    uint256 priceDecimals;

    error NotValidTrader();
    error NotValidTraderOrUpkeep();
    error InsufficientTopUpAmount();
    
    function getTotalBalancesInLP() external view returns (uint256 totalAssetA, uint256 totalAssetB) {
        return doppiLP.getBalances(address(this));
    }

    function getTotalValueInA() public view returns (uint256 totalInA) {
        uint256 price = doppiLP.getPrice();
        return _getTotalValueInA(price);
    }

    function getUnitPrice() external view returns (uint256) {
        if (totalUnits == 0) return 1e18;
        return getTotalValueInA() * 1e18 / totalUnits;
    }

    function getUnitPriceInB() external view returns (uint256) {
        if (totalUnitsB == 0) return 1e18;
        uint256 price = doppiLP.getPrice();
        uint256 totalInB = _getTotalValueInB(price);
        return totalInB * 1e18 / totalUnitsB;
    }

    function getTotalBalances() public view returns (uint256 totalAssetA, uint256 totalAssetB, uint256 price) {
        
        price = doppiLP.getPrice();
        
        totalAssetA = assetA.balanceOf(address(this));
        totalAssetB = assetB.balanceOf(address(this));
        
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

    function _getTotalValueInA(uint256 price) internal view returns (uint256 totalInA) {
        (uint256 balA, uint256 balB, ) = getTotalBalances();
        (uint256 lpA, uint256 lpB) = doppiLP.getBalances(address(this));
        totalInA = balA + lpA;
        uint256 totalB = balB + lpB;
        if (price > 0) {
            totalInA += totalB * price / priceDecimals;
        }
    }

    function _getTotalValueInB(uint256 price) internal view returns (uint256 totalInB) {
        (uint256 balA, uint256 balB, ) = getTotalBalances();
        (uint256 lpA, uint256 lpB) = doppiLP.getBalances(address(this));
        totalInB = balB + lpB;
        uint256 totalA = balA + lpA;
        if (price > 0) {
            totalInB += totalA * priceDecimals / price;
        }
    }

    function get_unrealized_PNL() external view returns (int256 pnl) {
        uint256 price = doppiLP.getPrice();
        int256 pnlprofit = _calcPnL(price, true);
        int256 pnlloss = _calcPnL(price, false);
        pnl = pnlprofit + pnlloss;  
    }

    function getStrikePnL(bool isBuy)
        external
        view
        returns (StrikePnLView[] memory items, int256 totalPnl, uint256 currentPrice)
    {
        currentPrice = doppiLP.getPrice();
        return _buildStrikePnLView(isBuy, currentPrice);
    }

    function getStrikePnLAtPrice(bool isBuy, uint256 price)
        external
        view
        returns (StrikePnLView[] memory items, int256 totalPnl)
    {
        (items, totalPnl, ) = _buildStrikePnLView(isBuy, price);
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

}
