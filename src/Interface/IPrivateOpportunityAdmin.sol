// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPrivateOpportunityAdmin {
    function setOpportunityBufferParams(uint16 _bufferCutBps, uint16 _minBufferBps) external;
}