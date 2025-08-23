// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IShares is IERC20 {
    function mintShares(address to, uint256 amount) external;
    function burnShares(address from, uint256 amount) external;
    function spendAllowance(address owner, address spender, uint256 amount) external;
}
