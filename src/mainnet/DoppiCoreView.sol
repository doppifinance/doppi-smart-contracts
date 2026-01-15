// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import "./DoppiCoreTypes.sol";
// import "forge-std/console.sol";

abstract contract DoppiCoreView {
    
    uint256 public totalBuyDeposits;
    uint256 public totalSellDeposits;
    uint256 public totalInterestLiabilityA; 
    uint256 public totalInterestLiabilityB;
    uint64 public nextPositionId = 1; 
    uint64 public nextProcessId = 1; 

    IDoppiLiquidity public immutable doppiLP; // Made immutable
    
    mapping(uint64 => DualAssetPosition) public positions_buy; 
    mapping(uint64 => DualAssetPosition) public positions_sell; 
    mapping(uint256 => OpportunityOrders) public opportunityBuy;
    mapping(uint256 => OpportunityOrders) public opportunitySell;
    
    // View functions for positions    
    function get_positions_buy(address _owner) external view returns (DualAssetPosition[] memory) {
        uint256 count = 0;
        uint256 length = getPositionLength();
        uint64 end = nextProcessId + uint64(length);
        DualAssetPosition[] memory tempresult = new DualAssetPosition[](length);
        for (uint64 i = nextProcessId; i < end; ) {
            if (positions_buy[i].owner == _owner) {
                tempresult[count] = positions_buy[i];
                count++;
            }
            unchecked { ++i; }
        }

        uint256 resultSize = count < tempresult.length ? count : tempresult.length;
        DualAssetPosition[] memory result = new DualAssetPosition[](resultSize);
        for (uint256 i = 0; i < resultSize;) {
            result[i] = tempresult[i];
            unchecked { ++i; }
        }        
        return result;
    }

    function get_positions_sell(address _owner) external view returns (DualAssetPosition[] memory) {
        uint256 count = 0;
        uint256 length = getPositionLength();
        uint64 end = nextProcessId + uint64(length);
        DualAssetPosition[] memory tempresult = new DualAssetPosition[](length);
        for (uint64 i = nextProcessId; i < end; ) {
            if (positions_sell[i].owner == _owner) {
                tempresult[count] = positions_sell[i];
                count++;
            }
            unchecked { ++i; }
        }
        uint256 resultSize = count < tempresult.length ? count : tempresult.length;
        DualAssetPosition[] memory result = new DualAssetPosition[](resultSize);
        for (uint256 i = 0; i < resultSize;) {
            result[i] = tempresult[i];
            unchecked { ++i; }
        }        
        return result;
    }

    function getBuyPositionCount(address _owner) external view returns (uint256 count) {
        
        uint256 length = getPositionLength();
        uint64 end = nextProcessId + uint64(length);
        for (uint64 i = nextProcessId; i < end; ) {
            if (positions_buy[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        return count;
    }

    function getSellPositionCount(address _owner) external view returns (uint256 count) {
        uint256 length = getPositionLength();
        uint64 end = nextProcessId + uint64(length);
        for (uint64 i = nextProcessId; i < end; ) {
            if (positions_sell[i].owner == _owner) {
                count++;
            }
            unchecked { ++i; }
        }
        return count;
    }

    function getCurrentDeposits(bool isBuy) public view returns (uint256 currentDeposits) {

        uint256 price = doppiLP.getPrice();
        uint256 priceDecimal = 10 ** doppiLP.getPriceDecimals();
        if(isBuy) {
            uint256 sellInA = totalSellDeposits * price / priceDecimal;
            currentDeposits = totalBuyDeposits + sellInA;
        }else{
            uint256 buyInB = totalBuyDeposits * priceDecimal / price;
            currentDeposits = totalSellDeposits + buyInB;
        }
    }

    function getPositionLength() public view returns (uint64){
        return nextPositionId - nextProcessId;
    } 

    function canAcceptDeposit(bool isBuy, uint256 depositAmount) public view returns (bool) {
        uint256 maxDeposit = doppiLP.getMaxDepositAmount(isBuy);
        uint256 currentDeposits = getCurrentDeposits(isBuy); 
        return (currentDeposits + depositAmount) <= maxDeposit;
    }

    function acceptedDeposit(bool isBuy) public view returns (uint256 acceptedAmount) {
        uint256 maxDeposit = doppiLP.getMaxDepositAmount(isBuy);
        if(maxDeposit == 0) return 0;
        uint256 currentDeposits = getCurrentDeposits(isBuy); 
        acceptedAmount = maxDeposit > currentDeposits ? maxDeposit - currentDeposits : 0;
    }

    function getInterestLiabilities() external view returns (uint256, uint256) {
        return (totalInterestLiabilityA, totalInterestLiabilityB);
    }

    function getOpportunityOrders(bool isBuy, uint256 strikePrice) external view returns (OpportunityOrders memory) {
        return isBuy ? opportunityBuy[strikePrice] : opportunitySell[strikePrice];
    }
}
