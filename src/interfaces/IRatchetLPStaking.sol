// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

interface IRatchetLPStaking {
    event YieldClaimed(address indexed recipient, uint256 ethAmount, uint256 tokenAmount);
    event StakeRegistered(uint256 indexed tokenId, address indexed creator);
    event CreatorClaimed(address indexed newRecipient);
    event YieldTransferProposed(address indexed currentRecipient, address indexed proposedRecipient);
    event YieldTransferAccepted(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Register the LP NFT stake (only factory, called once)
    function registerStake(uint256 tokenId_, PoolKey calldata poolKey_, address creator_, bool tokenIsCurrency0_)
        external;

    /// @notice Set the yield recipient as claimed (only factory)
    function setClaimed(address newRecipient) external;

    /// @notice Claim accumulated swap fee yield as ETH + token
    function claimYield() external;

    /// @notice Propose a new yield recipient (first step of two-step transfer)
    function proposeYieldTransfer(address newRecipient) external;

    /// @notice Accept the yield recipient role (second step of two-step transfer)
    function acceptYieldTransfer() external;

    /// @notice Factory that deployed this staking contract
    function FACTORY() external view returns (address);

    /// @notice Position manager for LP operations
    function POSITION_MANAGER() external view returns (IPositionManager);

    /// @notice WETH contract address
    function WETH() external view returns (IWETH9);

    /// @notice Address that can claim yield
    function yieldRecipient() external view returns (address);

    /// @notice Pending yield recipient for two-step transfer
    function pendingYieldRecipient() external view returns (address);

    /// @notice Whether the creator has been claimed
    function claimed() external view returns (bool);

    /// @notice The staked LP NFT token ID
    function tokenId() external view returns (uint256);

    /// @notice Whether the token is currency0 in the pool
    function tokenIsCurrency0() external view returns (bool);

    /// @notice Whether the staking contract has been initialized
    function initialized() external view returns (bool);
}
