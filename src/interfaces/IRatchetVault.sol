// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRatchetVault {
    event ReactiveSell(
        address indexed buyer, uint256 buyAmount, uint256 sellAmount, uint256 currentRate
    );
    event RatchetDecreased(uint256 oldRate, uint256 newRate);
    event CreatorClaimed(address indexed vault, address indexed newOwner);
    event TeamTransferProposed(
        address indexed currentRecipient, address indexed proposedRecipient
    );
    event TeamTransferAccepted(address indexed oldRecipient, address indexed newRecipient);
    event VaultFinished(address indexed vault);
    event FinalTokensReleased(address indexed recipient, uint256 amount);

    /// @notice Current reactive sell rate in basis points (0-1000 = 0-10%)
    function reactiveSellRate() external view returns (uint256);

    /// @notice Execute reactive sell in response to a buy
    /// @param buyAmount The amount of tokens being bought
    /// @return sellAmount The amount of tokens sold from vault
    function onBuy(uint256 buyAmount) external returns (uint256 sellAmount);

    /// @notice Decrease the reactive sell rate (ratchet down only)
    /// @param newRate New rate in basis points, must be < current rate
    function decreaseRate(uint256 newRate) external;

    /// @notice Release final tokens to team after vault is finished
    function releaseFinalTokens() external;

    /// @notice Set the vault as claimed with a new team recipient (only factory)
    /// @param newRecipient The new team recipient address
    function setClaimed(address newRecipient) external;

    /// @notice Initialize the token address (only factory)
    function initialize(address token_) external;

    /// @notice The creator string associated with this vault
    function creator() external view returns (string memory);

    /// @notice Whether the vault has been claimed
    function claimed() external view returns (bool);

    /// @notice The token address
    function token() external view returns (address);

    /// @notice The hook address
    function hook() external view returns (address);

    /// @notice Propose a new team recipient (first step of two-step transfer)
    /// @param newRecipient The proposed new team recipient
    function proposeTeamTransfer(address newRecipient) external;

    /// @notice Accept the team recipient role (second step of two-step transfer)
    function acceptTeamTransfer() external;

    /// @notice The team recipient address
    function teamRecipient() external view returns (address);

    /// @notice Pending team recipient for two-step transfer
    function pendingTeamRecipient() external view returns (address);

    /// @notice The factory that deployed this vault
    function FACTORY() external view returns (address);

    /// @notice The hook contract authorized to trigger reactive sells
    function HOOK() external view returns (address);

    /// @notice The starting token balance of the vault (set on initialize)
    function vaultStartingBalance() external view returns (uint256);

    /// @notice Cumulative tokens sold from the vault
    function totalSold() external view returns (uint256);

    /// @notice Whether the vault has finished selling (<=1% remaining)
    function vaultFinished() external view returns (bool);

    /// @notice Cumulative tokens sold within the current day
    function dailySold() external view returns (uint256);

    /// @notice The day number (block.timestamp / 1 days) of the last sell
    function lastSellDay() external view returns (uint256);
}
