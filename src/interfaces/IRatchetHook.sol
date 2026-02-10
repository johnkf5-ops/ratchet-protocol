// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IRatchetHook {
    event PoolInitialized(PoolKey key, address token, address vault);
    event FeesDeposited(bytes32 indexed poolId, address indexed sender, uint256 amount);
    event FeesRouted(bytes32 indexed poolId, uint256 ethToTeam, uint256 ethToLp);
    event ProtocolFeeClaimed(address recipient, uint256 amount);

    /// @notice Register a new pool with its vault (only factory)
    function registerPool(
        PoolKey calldata key,
        address token_,
        address vault,
        bool tokenIsCurrency0_,
        uint256 teamFeeShareBps_
    ) external;

    /// @notice Deposit ETH fees for a specific pool
    function depositFees(bytes32 poolId) external payable;

    /// @notice Distribute accumulated ETH fees for a specific pool
    function routeFees(PoolKey calldata key) external;

    /// @notice Claim accumulated protocol fees (only callable by protocol recipient)
    function claimProtocolFees() external;

    /// @notice Sweep tokens accidentally sent to the hook
    function sweepTokens(address token_, address to) external;

    /// @notice Sweep untracked ETH to protocol recipient
    function sweepETH() external;

    /// @notice Fee share to team in basis points for a specific pool
    function poolTeamFeeShare(bytes32 poolId) external view returns (uint256);

    /// @notice Get the vault associated with a pool
    function poolVaults(bytes32 poolId) external view returns (address);

    /// @notice Get the token associated with a pool
    function poolTokens(bytes32 poolId) external view returns (address);

    /// @notice Whether token is currency0 for a pool
    function tokenIsCurrency0(bytes32 poolId) external view returns (bool);

    /// @notice ETH fees accumulated for a pool
    function poolEthFees(bytes32 poolId) external view returns (uint256);

    /// @notice Total tracked ETH fees across all pools
    function totalPoolEthFees() external view returns (uint256);

    /// @notice Accumulated protocol fees
    function protocolFeesAccumulated() external view returns (uint256);

    /// @notice Factory address
    function FACTORY() external view returns (address);

    /// @notice Protocol fee recipient address
    function PROTOCOL_RECIPIENT() external view returns (address);
}
