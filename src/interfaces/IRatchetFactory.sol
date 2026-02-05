// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct LaunchParams {
    string name;
    string symbol;
    uint256 totalSupply;
    uint256 teamAllocationBps; // Basis points for team vault (e.g., 1000 = 10%)
    uint256 initialReactiveSellRate; // Initial reactive sell rate in bps (max 1000 = 10%)
    uint256 teamFeeShareBps; // Team's share of ETH fees in bps
    uint160 initialSqrtPriceX96; // Initial price for the pool
}

struct LaunchResult {
    address token;
    address vault;
    bytes32 poolId;
}

interface IRatchetFactory {
    event TokenLaunched(
        address indexed token,
        address indexed vault,
        bytes32 indexed poolId,
        string name,
        string symbol,
        address creator
    );

    /// @notice Launch a new token with Ratchet mechanism
    /// @param params Launch parameters
    /// @return result Addresses of deployed contracts and pool ID
    function launch(LaunchParams calldata params) external payable returns (LaunchResult memory result);
}
