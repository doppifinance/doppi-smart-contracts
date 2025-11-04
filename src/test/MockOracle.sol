// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MockOracle {
    int256 private _price;
    uint8 private _decimals;
    uint256 private _updatedAt;

    event PriceUpdated(int256 newPrice, uint256 updatedAt);

    constructor(int256 initialPrice, uint8 decimals_) {
        _price = initialPrice;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
        _updatedAt = block.timestamp;
        emit PriceUpdated(newPrice, _updatedAt);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (
            0, // roundId
            _price, // answer
            block.timestamp, // startedAt
            block.timestamp, // updatedAt
            0 // answeredInRound
        );
    }

    function latestAnswer() external view returns (int256) {
        return _price;
    }
}
