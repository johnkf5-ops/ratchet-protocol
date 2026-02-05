// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IRatchetHook {
    event PoolInitialized(PoolKey key, address token, address vault);
    event FeesRouted(uint256 ethToTeam, uint256 tokensToLp);

    /// @notice Fee share to team in basis points (e.g., 500 = 5%)
    function teamFeeShare() external view returns (uint256);

    /// @notice Get the vault associated with a pool
    function poolVaults(bytes32 poolId) external view returns (address);
}
