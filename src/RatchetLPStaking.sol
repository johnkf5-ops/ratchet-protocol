// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {IRatchetLPStaking} from "./interfaces/IRatchetLPStaking.sol";

/// @title RatchetLPStaking
/// @notice Holds an LP NFT forever. Creator claims accumulated swap fee yield as ETH.
/// @dev The LP NFT cannot be withdrawn, transferred, or approved. Only fee yield is claimable.
contract RatchetLPStaking is IRatchetLPStaking, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The factory that deployed this staking contract
    address public immutable FACTORY;
    /// @notice Uniswap v4 position manager for fee collection
    IPositionManager public immutable POSITION_MANAGER;
    /// @notice WETH contract for unwrapping
    IWETH9 public immutable WETH;

    /// @notice Address that can claim yield
    address public yieldRecipient;
    /// @notice Pending yield recipient for two-step transfer
    address public pendingYieldRecipient;
    /// @notice Whether the creator has been claimed
    bool public claimed;
    /// @notice The staked LP NFT token ID
    uint256 public tokenId;
    /// @notice Stored pool key for fee collection
    PoolKey public poolKey;
    /// @notice Whether the token is currency0 in the pool
    bool public tokenIsCurrency0;
    /// @notice Whether the staking contract has been initialized
    bool public initialized;

    error OnlyFactory();
    error OnlyYieldRecipient();
    error OnlyPendingRecipient();
    error AlreadyInitialized();
    error NotInitialized();
    error AlreadyClaimed();
    error ZeroAddress();
    error NoPendingTransfer();
    error NotClaimed();
    error OnlyWETH();

    modifier onlyFactory() {
        if (msg.sender != FACTORY) revert OnlyFactory();
        _;
    }

    modifier onlyYieldRecipient() {
        if (msg.sender != yieldRecipient) revert OnlyYieldRecipient();
        _;
    }

    constructor(address positionManager_, address weth_) {
        FACTORY = msg.sender;
        POSITION_MANAGER = IPositionManager(positionManager_);
        WETH = IWETH9(weth_);
    }

    /// @notice Register the LP NFT stake. Called once by factory after LP mint.
    function registerStake(
        uint256 tokenId_,
        PoolKey calldata poolKey_,
        address creator_,
        bool tokenIsCurrency0_
    ) external onlyFactory {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        tokenId = tokenId_;
        poolKey = poolKey_;
        yieldRecipient = creator_;
        tokenIsCurrency0 = tokenIsCurrency0_;

        emit StakeRegistered(tokenId_, creator_);
    }

    /// @notice Set the yield recipient as claimed (only factory, mirrors vault pattern)
    function setClaimed(address newRecipient) external onlyFactory {
        if (claimed) revert AlreadyClaimed();
        if (newRecipient == address(0)) revert ZeroAddress();
        yieldRecipient = newRecipient;
        claimed = true;

        emit CreatorClaimed(newRecipient);
    }

    /// @notice Claim accumulated swap fee yield as ETH + token
    function claimYield() external onlyYieldRecipient nonReentrant {
        if (!initialized) revert NotInitialized();

        // 1. Collect fees: DECREASE_LIQUIDITY with 0 liquidity credits accumulated fees
        //    Then TAKE_PAIR to send both currencies to this contract
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        // DECREASE_LIQUIDITY: tokenId, 0 liquidity, 0 amount0Min, 0 amount1Min, ""
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), "");
        // TAKE_PAIR: currency0, currency1, recipient (this contract)
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        bytes memory unlockData = abi.encode(actions, params);
        POSITION_MANAGER.modifyLiquidities(unlockData, block.timestamp + 60);

        // 2. Unwrap any WETH balance to ETH
        uint256 wethBalance = IERC20(address(WETH)).balanceOf(address(this));
        if (wethBalance > 0) {
            WETH.withdraw(wethBalance);
        }

        // 3. Send ETH to yield recipient
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool success,) = yieldRecipient.call{value: ethBalance}("");
            require(success, "ETH transfer failed");
        }

        // 4. Send any token balance to yield recipient
        address tokenAddr = tokenIsCurrency0
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);
        uint256 tokenBalance = IERC20(tokenAddr).balanceOf(address(this));
        if (tokenBalance > 0) {
            IERC20(tokenAddr).safeTransfer(yieldRecipient, tokenBalance);
        }

        emit YieldClaimed(yieldRecipient, ethBalance, tokenBalance);
    }

    /// @notice Propose a new yield recipient (first step of two-step transfer)
    function proposeYieldTransfer(address newRecipient) external onlyYieldRecipient {
        if (newRecipient == address(0)) revert ZeroAddress();
        pendingYieldRecipient = newRecipient;

        emit YieldTransferProposed(yieldRecipient, newRecipient);
    }

    /// @notice Accept the yield recipient role (second step of two-step transfer)
    function acceptYieldTransfer() external {
        if (msg.sender != pendingYieldRecipient) revert OnlyPendingRecipient();

        emit YieldTransferAccepted(yieldRecipient, msg.sender);
        yieldRecipient = msg.sender;
        pendingYieldRecipient = address(0);
    }

    /// @notice Accept ETH from WETH.withdraw() only
    receive() external payable {
        if (msg.sender != address(WETH)) revert OnlyWETH();
    }

    // Expose poolKey fields for external access
    function getPoolKey() external view returns (PoolKey memory) {
        return poolKey;
    }
}
