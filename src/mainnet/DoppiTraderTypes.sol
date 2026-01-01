// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct OrderConfig {
    uint8 strikeZone;
    uint24 weight;
}

struct UndoStat {
    uint256 undo_assetB;
    uint256 undo_assetA;
}
