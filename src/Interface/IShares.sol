// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IShares {
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function mintShares(address to, uint256 amount) external;
    function burnShares(address from, uint256 amount) external;
    function spendAllowance(address owner, address spender, uint256 amount) external;
}
