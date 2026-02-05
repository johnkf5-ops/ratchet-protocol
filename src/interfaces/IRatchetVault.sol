// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRatchetVault {
    event ReactiveSell(address indexed buyer, uint256 buyAmount, uint256 sellAmount, uint256 newRate);
    event RatchetDecreased(uint256 oldRate, uint256 newRate);
    event TeamFeeClaimed(address indexed recipient, uint256 amount);
    event CreatorClaimed(address indexed vault, address indexed newOwner);

    /// @notice Current reactive sell rate in basis points (0-1000 = 0-10%)
    function reactiveSellRate() external view returns (uint256);

    /// @notice Execute reactive sell in response to a buy
    /// @param buyAmount The amount of tokens being bought
    /// @return sellAmount The amount of tokens sold from vault
    function onBuy(uint256 buyAmount) external returns (uint256 sellAmount);

    /// @notice Decrease the reactive sell rate (ratchet down only)
    /// @param newRate New rate in basis points, must be < current rate
    function decreaseRate(uint256 newRate) external;

    /// @notice Claim accumulated ETH fees
    function claimFees() external;

    /// @notice Set the vault as claimed with a new team recipient (only factory)
    /// @param newRecipient The new team recipient address
    function setClaimed(address newRecipient) external;

    /// @notice The creator string associated with this vault
    function creator() external view returns (string memory);
}
