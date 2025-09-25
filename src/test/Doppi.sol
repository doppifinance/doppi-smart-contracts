// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DOPPI is ERC20, Ownable {
    mapping(address => bool) public minters;

    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        // No tokens minted at deployment
    }

    /// @notice Add a new minter (e.g., DoppiClaim contract)
    function addMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "minter=0");
        require(!minters[_minter], "already minter");
        minters[_minter] = true;
        emit MinterAdded(_minter);
    }

    /// @notice Remove a minter
    function removeMinter(address _minter) external onlyOwner {
        require(minters[_minter], "not a minter");
        minters[_minter] = false;
        emit MinterRemoved(_minter);
    }

    /// @notice Mint new tokens, callable only by authorized minters
    function mint(address to, uint256 amount) external {
        require(minters[msg.sender], "not minter");
        _mint(to, amount);
    }
}
