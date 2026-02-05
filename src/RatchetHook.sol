// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IRatchetHook} from "./interfaces/IRatchetHook.sol";
import {IRatchetVault} from "./interfaces/IRatchetVault.sol";

/// @title RatchetHook
/// @notice Uniswap v4 hook that triggers reactive vault sells on token buys
/// @dev Intercepts afterSwap to detect buys and route fees appropriately.
///      ETH fees go to team (configurable %), token fees return to LP.
contract RatchetHook is BaseHook, IRatchetHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Factory that deployed this hook, only factory can register pools
    address public immutable FACTORY;
    /// @notice Team's share of ETH fees in basis points (e.g., 500 = 5%)
    uint256 public teamFeeShare;

    /// @notice Maps pool ID to its associated vault
    mapping(bytes32 => address) public poolVaults;
    /// @notice Maps pool ID to its token address (non-ETH side)
    mapping(bytes32 => address) public poolTokens;
    /// @notice Maps pool ID to whether token is currency0 (true) or currency1 (false)
    mapping(bytes32 => bool) public tokenIsCurrency0;
    /// @notice Maps pool ID to accumulated ETH fees for that pool
    mapping(bytes32 => uint256) public poolEthFees;

    error OnlyFactory();
    error PoolAlreadyInitialized();
    error PoolNotInitialized();

    modifier onlyFactory() {
        _checkFactory();
        _;
    }

    function _checkFactory() internal view {
        if (msg.sender != FACTORY) revert OnlyFactory();
    }

    /// @notice Deploy the hook
    /// @param poolManager_ Uniswap v4 pool manager
    /// @param factory_ Factory contract authorized to register pools
    /// @param defaultTeamFeeShare_ Default team fee share in basis points
    constructor(IPoolManager poolManager_, address factory_, uint256 defaultTeamFeeShare_)
        BaseHook(poolManager_)
    {
        FACTORY = factory_;
        teamFeeShare = defaultTeamFeeShare_;
    }

    /// @notice Register a new pool with its vault. Called by factory during launch.
    /// @param key The Uniswap v4 pool key
    /// @param token_ The token address (non-ETH side of pair)
    /// @param vault The vault that holds team tokens for this pool
    /// @param tokenIsCurrency0_ Whether the token is currency0 (affects buy detection)
    function registerPool(
        PoolKey calldata key,
        address token_,
        address vault,
        bool tokenIsCurrency0_
    ) external onlyFactory {
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (poolVaults[poolId] != address(0)) revert PoolAlreadyInitialized();

        poolVaults[poolId] = vault;
        poolTokens[poolId] = token_;
        tokenIsCurrency0[poolId] = tokenIsCurrency0_;

        // Set max approval once to avoid repeated approvals on each swap
        IERC20(token_).approve(address(poolManager), type(uint256).max);

        emit PoolInitialized(key, token_, vault);
    }

    /// @notice Declare which hook callbacks are enabled
    /// @return Permissions struct with afterSwap and afterSwapReturnDelta enabled
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Hook callback after each swap. Triggers reactive sell on buys.
    /// @dev Detects buys based on token position and swap direction
    /// @param key The pool being swapped
    /// @param params Swap parameters (direction, amount)
    /// @param delta Balance changes from the swap
    /// @return selector Function selector for validation
    /// @return hookDelta Additional tokens to add to swap (from vault reactive sell)
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        bytes32 poolId = PoolId.unwrap(key.toId());
        address vault = poolVaults[poolId];

        // Skip if pool not registered with this hook
        if (vault == address(0)) {
            return (this.afterSwap.selector, 0);
        }

        bool _tokenIsCurrency0 = tokenIsCurrency0[poolId];

        // Detect buy: user is spending ETH to receive tokens
        // zeroForOne=true means spending currency0 to get currency1
        // zeroForOne=false means spending currency1 to get currency0
        //
        // If token is currency0: buy = zeroForOne=false (spending ETH/currency1 to get token/currency0)
        // If token is currency1: buy = zeroForOne=true (spending ETH/currency0 to get token/currency1)
        bool isBuy = _tokenIsCurrency0 ? !params.zeroForOne : params.zeroForOne;

        if (isBuy) {
            // Get the amount of tokens being bought
            // When buying, tokens flow out of pool (negative delta for that currency)
            int128 tokenDelta = _tokenIsCurrency0 ? delta.amount0() : delta.amount1();

            if (tokenDelta < 0) {
                uint256 buyAmount = int256(-tokenDelta).toUint256();

                // Trigger reactive sell - vault transfers tokens to this hook
                uint256 sellAmount = IRatchetVault(vault).onBuy(buyAmount);

                if (sellAmount > 0) {
                    // Return negative delta = more tokens going out to buyer
                    // The delta must be for the same currency as the token
                    // (approval set to max in registerPool)
                    return (this.afterSwap.selector, -sellAmount.toInt256().toInt128());
                }
            }
        }

        return (this.afterSwap.selector, 0);
    }

    /// @notice Deposit ETH fees for a specific pool
    /// @dev Use this instead of direct transfers to ensure proper per-pool accounting
    /// @param poolId The pool to credit the fees to
    function depositFees(bytes32 poolId) external payable {
        if (poolVaults[poolId] == address(0)) revert PoolNotInitialized();
        poolEthFees[poolId] += msg.value;
    }

    /// @notice Distribute accumulated fees for a specific pool
    /// @dev Sends teamFeeShare% of tracked ETH fees to vault, donates tokens to LP
    /// @param key The pool to route fees for
    function routeFees(PoolKey calldata key) external {
        bytes32 poolId = PoolId.unwrap(key.toId());
        address vault = poolVaults[poolId];
        if (vault == address(0)) revert PoolNotInitialized();

        // Send team's share of tracked ETH fees to vault
        uint256 ethFees = poolEthFees[poolId];
        if (ethFees > 0) {
            // Clear balance before transfer to prevent reentrancy
            poolEthFees[poolId] = 0;

            uint256 toTeam = (ethFees * teamFeeShare) / BPS_DENOMINATOR;
            if (toTeam > 0) {
                (bool success,) = vault.call{value: toTeam}("");
                require(success, "ETH transfer failed");
            }
            // Note: remaining ETH (ethFees - toTeam) stays in contract as protocol revenue
            // or could be donated back to LP in a future implementation
        }

        // Donate token fees back to LP (increases LP value)
        // Token balance is pool-specific since each pool has unique token
        // (approval set to max in registerPool)
        address token_ = poolTokens[poolId];
        uint256 tokenFees = IERC20(token_).balanceOf(address(this));
        if (tokenFees > 0) {
            poolManager.donate(key, 0, tokenFees, "");
        }

        emit FeesRouted(ethFees * teamFeeShare / BPS_DENOMINATOR, tokenFees);
    }

    /// @notice Accept ETH but require explicit pool association via depositFees
    /// @dev ETH sent directly without pool ID goes to untracked balance (recoverable by admin)
    receive() external payable {}
}
