// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDoppiCore} from "../Interface/IDoppiCore.sol";
import {IDoppiLiquidity} from "../Interface/IDoppiLiquidity.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./DoppiCoreTypes.sol";

abstract contract DoppiTraderAdminView is Ownable {
    
    IERC20 public assetA;
    IERC20 public assetB;
    IDoppiLiquidity public doppiLP;
    IDoppiCore public doppiCore;
    Trade[] public buy_undo_list;
    Trade[] public sell_undo_list;
    address public validTrader;
    address public s_forwarderAddress;
    uint16 public traderDefaultDay;
    uint24 public maxOrder;
    uint32 public ratioLP;
    uint32 public tolerance;
    
    function getTotalBalancesInLP() external view returns (uint256 totalAssetA, uint256 totalAssetB) {
        uint256 totalAssetLP = doppiLP.totalAssetsInAssetA();
        (uint256 ratioA, ) = doppiLP.assetRatio();        
        totalAssetA = totalAssetLP * ratioA / 1e18;
        totalAssetB = totalAssetLP - totalAssetA;
    }

    function getTotalBalances() external view returns (uint256 totalAssetA, uint256 totalAssetB, uint256 price) {
        
        price = doppiLP.getPrice();
        
        totalAssetA = assetA.balanceOf(address(this));
        totalAssetB = assetB.balanceOf(address(this));
        
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

    function get_buy_undos() external view returns (Trade[] memory) {
        if (buy_undo_list.length == 0) return new Trade[](0);
        return buy_undo_list;
    }

    function get_sell_undos() external view returns (Trade[] memory) {
        if (sell_undo_list.length == 0) return new Trade[](0);
        return sell_undo_list;
    }

    function get_buy_unrealized_PNL() external view returns (int256) {
        int256 pnl = 0;
        uint256 price = doppiLP.getPrice();
        uint8 priceDecimals = doppiLP.getPriceDecimals();
        uint256 length = buy_undo_list.length;
        
        for (uint256 i = 0; i < length; ) {
            uint256 currentValue = buy_undo_list[i].payoutAmount * price / (10 ** priceDecimals);
            pnl += int256(currentValue) - int256(buy_undo_list[i].origAmount);
            unchecked { ++i; }
        }
        return pnl;
    }

    function get_sell_unrealized_PNL() external view returns (int256) {
        int256 pnl = 0;
        uint256 price = doppiLP.getPrice();
        uint8 priceDecimals = doppiLP.getPriceDecimals();
        uint256 length = sell_undo_list.length;

        for (uint256 i = 0; i < length; ) {
            uint256 currentValue = sell_undo_list[i].payoutAmount * (10 ** priceDecimals) / price;
            pnl += int256(currentValue) - int256(sell_undo_list[i].origAmount);
            unchecked { ++i; }
        }

        return pnl;
    }

    function get_validTrader() external view returns (address) {
        return validTrader;
    }

    function setDefaultDay(uint16 _day) external onlyTrader {
        traderDefaultDay = _day;
    }

    function setMaxOrder(uint24 _maxOrder) external onlyTrader {
        maxOrder = _maxOrder;
    }

    function setForwarderAddress(address forwarderAddress) external onlyTrader {
        s_forwarderAddress = forwarderAddress;
    }

    function setRatioLP(uint32 _ratioLP) external onlyOwner {
        ratioLP = _ratioLP;
    }

    function setTolerance(uint32 _tolerance) external onlyOwner {
        tolerance = _tolerance;
    }

    modifier onlyTrader() {
        require(msg.sender == validTrader, "invalid trader");
        _;
    }

}
