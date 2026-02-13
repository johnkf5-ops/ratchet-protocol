// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct LaunchParams {
    string name;
    string symbol;
    uint256 totalSupply;
    uint256 teamAllocationBps; // Basis points for team vault (e.g., 1000 = 10%)
    uint256 initialReactiveSellRate; // Initial reactive sell rate in bps (max 1000 = 10%)
    uint160 initialSqrtPriceX96; // Initial price for the pool
    string creator; // Creator identifier (empty string = auto-claim to msg.sender)
}

struct LaunchResult {
    address token;
    address vault;
    address staking;
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

    event CreatorClaimed(address indexed vault, address indexed newOwner, string creator);

    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);

    event VerifierProposed(address indexed currentVerifier, address indexed proposedVerifier);

    /// @notice Launch a new token with Ratchet mechanism
    /// @param params Launch parameters
    /// @return result Addresses of deployed contracts and pool ID
    function launch(LaunchParams calldata params)
        external
        payable
        returns (LaunchResult memory result);

    /// @notice Verify and claim a vault for a creator (only verifier)
    /// @param vault The vault to claim
    /// @param newOwner The new owner address
    function verifyClaim(address vault, address newOwner) external;

    /// @notice Propose a new verifier address (first step of two-step transfer)
    /// @param newVerifier The proposed new verifier address
    function proposeVerifier(address newVerifier) external;

    /// @notice Accept the verifier role (second step of two-step transfer)
    function acceptVerifier() external;

    /// @notice Current verifier address
    function verifier() external view returns (address);

    /// @notice Pending verifier address (awaiting acceptance)
    function pendingVerifier() external view returns (address);

    /// @notice Whether a vault was deployed by this factory
    function deployedVaults(address vault) external view returns (bool);

    /// @notice Get the staking contract associated with a vault
    function vaultStaking(address vault) external view returns (address);

    /// @notice Sweep tokens accidentally sent to the factory (only verifier)
    function sweepTokens(address token_, address to) external;
}
