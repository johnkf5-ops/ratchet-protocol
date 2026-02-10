// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title RatchetToken
/// @notice Simple ERC20 token deployed by Ratchet factory
/// @dev Entire supply minted at deployment, split between LP and team vault
contract RatchetToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 lpSupply,
        uint256 vaultSupply,
        address lpRecipient,
        address vault_
    ) ERC20(name_, symbol_) {
        _mint(lpRecipient, lpSupply);
        _mint(vault_, vaultSupply);
    }
}
