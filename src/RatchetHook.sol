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
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IRatchetHook} from "./interfaces/IRatchetHook.sol";
import {IRatchetVault} from "./interfaces/IRatchetVault.sol";

/// @title RatchetHook
/// @notice Uniswap v4 hook that triggers reactive vault sells on token buys
/// @dev Intercepts afterSwap to detect buys and route fees appropriately.
///      ETH fees go to team (configurable %), token fees return to LP.
contract RatchetHook is BaseHook, IRatchetHook, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant PROTOCOL_FEE_BPS = 2000; // 20%
    uint256 public constant MAX_TEAM_FEE_SHARE = 5000; // 50%

    /// @notice Factory that deployed this hook, only factory can register pools
    address public immutable FACTORY;
    /// @notice Protocol fee recipient address (transferable via two-step)
    address public protocolRecipient;
    /// @notice Pending protocol recipient for two-step transfer
    address public pendingProtocolRecipient;
    /// @notice Wrapped ETH contract for LP fee donations
    IWETH9 public immutable WETH;

    /// @notice Accumulated protocol fees available for claiming
    uint256 public protocolFeesAccumulated;

    /// @notice Maps pool ID to its associated vault
    mapping(bytes32 => address) public poolVaults;
    /// @notice Maps pool ID to its token address (non-ETH side)
    mapping(bytes32 => address) public poolTokens;
    /// @notice Maps pool ID to whether token is currency0 (true) or currency1 (false)
    mapping(bytes32 => bool) public tokenIsCurrency0;
    /// @notice Maps pool ID to accumulated ETH fees for that pool
    mapping(bytes32 => uint256) public poolEthFees;
    /// @notice Maps pool ID to team's share of ETH fees in basis points (max 5000 = 50%)
    mapping(bytes32 => uint256) public poolTeamFeeShare;
    /// @notice Total ETH fees tracked across all pools (for sweep accounting)
    uint256 public totalPoolEthFees;
    /// @notice Tracks tokens registered to pools (prevents accidental sweep)
    mapping(address => bool) public registeredTokens;
    /// @notice ETH pending for vaults after failed transfers (bypasses protocol fee on retry)
    mapping(address => uint256) public vaultPendingFees;
    /// @notice Total vault pending fees (for sweep accounting)
    uint256 public totalVaultPendingFees;

    error OnlyFactory();
    error OnlyProtocol();
    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error OnlyPoolManager();
    error TeamFeeShareTooHigh();
    error NoFeesToClaim();
    error NoFeesToRoute();
    error ZeroValue();
    error OnlyPendingRecipient();
    error ZeroAddress();
    error RegisteredToken();

    modifier onlyFactory() {
        _checkFactory();
        _;
    }

    modifier onlyProtocol() {
        if (msg.sender != protocolRecipient) revert OnlyProtocol();
        _;
    }

    function _checkFactory() internal view {
        if (msg.sender != FACTORY) revert OnlyFactory();
    }

    /// @notice Deploy the hook
    /// @param poolManager_ Uniswap v4 pool manager
    /// @param factory_ Factory contract authorized to register pools
    /// @param protocolRecipient_ Address that receives protocol fees
    /// @param weth_ Wrapped ETH contract for LP fee donations
    constructor(
        IPoolManager poolManager_,
        address factory_,
        address protocolRecipient_,
        IWETH9 weth_
    )
        BaseHook(poolManager_)
    {
        FACTORY = factory_;
        protocolRecipient = protocolRecipient_;
        WETH = weth_;
    }

    /// @notice Register a new pool with its vault. Called by factory during launch.
    /// @param key The Uniswap v4 pool key
    /// @param token_ The token address (non-ETH side of pair)
    /// @param vault The vault that holds team tokens for this pool
    /// @param tokenIsCurrency0_ Whether the token is currency0 (affects buy detection)
    /// @param teamFeeShareBps_ Team's share of ETH fees in basis points (max 10000 = 100%)
    function registerPool(
        PoolKey calldata key,
        address token_,
        address vault,
        bool tokenIsCurrency0_,
        uint256 teamFeeShareBps_
    ) external onlyFactory {
        if (teamFeeShareBps_ > MAX_TEAM_FEE_SHARE) revert TeamFeeShareTooHigh();

        bytes32 poolId = PoolId.unwrap(key.toId());
        if (poolVaults[poolId] != address(0)) revert PoolAlreadyInitialized();

        poolVaults[poolId] = vault;
        poolTokens[poolId] = token_;
        tokenIsCurrency0[poolId] = tokenIsCurrency0_;
        poolTeamFeeShare[poolId] = teamFeeShareBps_;
        registeredTokens[token_] = true;

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

        // Only trigger on exact-input buys (amountSpecified < 0)
        // For exact-output buys, the hookDelta applies to the input (ETH) currency,
        // not the output (token), which would cause incorrect behavior.
        if (isBuy && params.amountSpecified < 0) {
            // Get the amount of tokens being bought
            // In v4 delta convention: positive = credit (swapper receives tokens)
            // When buying tokens, the token delta is POSITIVE for the swapper
            int128 tokenDelta = _tokenIsCurrency0 ? delta.amount0() : delta.amount1();

            if (tokenDelta > 0) {
                uint256 buyAmount = uint256(int256(tokenDelta));

                // Trigger reactive sell - vault transfers tokens to this hook
                uint256 sellAmount = IRatchetVault(vault).onBuy(buyAmount);

                if (sellAmount > 0) {
                    // Settle the token debt with the pool manager.
                    // The vault transferred sellAmount tokens to this hook via onBuy().
                    // We must sync → transfer → settle before returning the hookDelta.
                    Currency tokenCurrency = _tokenIsCurrency0 ? key.currency0 : key.currency1;
                    poolManager.sync(tokenCurrency);
                    IERC20(poolTokens[poolId]).safeTransfer(address(poolManager), sellAmount);
                    poolManager.settle();

                    // Return negative delta = more tokens going out to buyer
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
        if (msg.value == 0) revert ZeroValue();
        if (poolVaults[poolId] == address(0)) revert PoolNotInitialized();
        poolEthFees[poolId] += msg.value;
        totalPoolEthFees += msg.value;

        emit FeesDeposited(poolId, msg.sender, msg.value);
    }

    /// @notice Distribute accumulated ETH fees for a specific pool
    /// @dev Takes 20% protocol fee first, then sends teamFeeShare% of remaining to vault,
    ///      donates LP share as WETH via poolManager.unlock(). Protected against reentrancy.
    /// @param key The pool to route fees for
    function routeFees(PoolKey calldata key) external nonReentrant {
        bytes32 poolId = PoolId.unwrap(key.toId());
        address vault = poolVaults[poolId];
        if (vault == address(0)) revert PoolNotInitialized();

        uint256 ethFees = poolEthFees[poolId];
        if (ethFees == 0) revert NoFeesToRoute();

        // Clear balance before transfers (checks-effects-interactions)
        poolEthFees[poolId] = 0;
        totalPoolEthFees -= ethFees;

        // Protocol takes 20% off the top
        uint256 protocolFee = (ethFees * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        protocolFeesAccumulated += protocolFee;

        // Remaining 80% is split between team and LP
        uint256 remaining = ethFees - protocolFee;
        uint256 toTeam = (remaining * poolTeamFeeShare[poolId]) / BPS_DENOMINATOR;
        uint256 lpEth = remaining - toTeam;

        if (toTeam > 0) {
            (bool success,) = vault.call{value: toTeam}("");
            if (!success) {
                // Store in vault-specific pending fees (bypasses protocol fee on retry)
                vaultPendingFees[vault] += toTeam;
                totalVaultPendingFees += toTeam;
            }
        }

        // Donate LP ETH to LP via pool manager unlock callback
        if (lpEth > 0) {
            bool _tokenIsCurrency0 = tokenIsCurrency0[poolId];
            poolManager.unlock(
                abi.encode(key, _tokenIsCurrency0, lpEth)
            );
        }

        emit FeesRouted(poolId, toTeam, lpEth);
    }

    /// @notice Callback from pool manager during unlock, used to donate LP ETH as WETH
    /// @dev Only callable by the pool manager as part of the unlock flow.
    /// @param data ABI-encoded (PoolKey, bool tokenIsCurrency0, uint256 lpEth)
    /// @return Empty bytes (no return data needed)
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        (PoolKey memory key, bool _tokenIsCurrency0, uint256 lpEth) =
            abi.decode(data, (PoolKey, bool, uint256));

        // Wrap ETH to WETH and donate to LP on the WETH side.
        // donate() creates a debt (positive delta) that we settle afterward.
        // This is valid because v4 checks net-zero deltas at the end of unlock, not per-operation.
        WETH.deposit{value: lpEth}();
        if (_tokenIsCurrency0) {
            poolManager.donate(key, 0, lpEth, "");
        } else {
            poolManager.donate(key, lpEth, 0, "");
        }
        Currency wethCurrency = _tokenIsCurrency0 ? key.currency1 : key.currency0;
        poolManager.sync(wethCurrency);
        IERC20(address(WETH)).safeTransfer(address(poolManager), lpEth);
        poolManager.settle();

        return "";
    }

    /// @notice Retry sending pending ETH fees to a vault
    /// @dev Bypasses protocol fee since these were already taxed. Anyone can call.
    /// @param vault The vault to retry sending fees to
    function retryVaultFees(address vault) external nonReentrant {
        uint256 amount = vaultPendingFees[vault];
        if (amount == 0) revert NoFeesToClaim();

        vaultPendingFees[vault] = 0;
        totalVaultPendingFees -= amount;

        (bool success,) = vault.call{value: amount}("");
        if (!success) {
            // Still failing — put back for another retry
            vaultPendingFees[vault] = amount;
            totalVaultPendingFees += amount;
        }
    }

    /// @notice Claim accumulated protocol fees
    /// @dev Only callable by PROTOCOL_RECIPIENT. Transfers all accumulated protocol fees.
    function claimProtocolFees() external onlyProtocol nonReentrant {
        uint256 amount = protocolFeesAccumulated;
        if (amount == 0) revert NoFeesToClaim();
        protocolFeesAccumulated = 0;

        (bool success,) = protocolRecipient.call{value: amount}("");
        require(success, "ETH transfer failed");

        emit ProtocolFeeClaimed(protocolRecipient, amount);
    }

    /// @notice Sweep tokens accidentally sent to the hook
    /// @dev Only callable by protocol recipient. Cannot sweep tokens registered to pools.
    /// @param token_ The token to sweep
    /// @param to The recipient address
    function sweepTokens(address token_, address to) external onlyProtocol {
        if (registeredTokens[token_]) revert RegisteredToken();
        uint256 balance = IERC20(token_).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token_).safeTransfer(to, balance);
        }
    }

    /// @notice Sweep untracked ETH to protocol recipient
    /// @dev Recovers ETH sent directly to the hook without using depositFees
    function sweepETH() external onlyProtocol nonReentrant {
        uint256 tracked = protocolFeesAccumulated + totalPoolEthFees + totalVaultPendingFees;
        uint256 balance = address(this).balance;
        if (balance > tracked) {
            uint256 untracked = balance - tracked;
            (bool success,) = protocolRecipient.call{value: untracked}("");
            require(success, "ETH transfer failed");
        }
    }

    /// @notice Propose a new protocol recipient (first step of two-step transfer)
    /// @dev Only callable by current protocol recipient
    /// @param newRecipient The proposed new protocol recipient
    function proposeProtocolTransfer(address newRecipient) external onlyProtocol {
        if (newRecipient == address(0)) revert ZeroAddress();
        pendingProtocolRecipient = newRecipient;
        emit ProtocolTransferProposed(protocolRecipient, newRecipient);
    }

    /// @notice Accept the protocol recipient role (second step of two-step transfer)
    /// @dev Only callable by the pending protocol recipient
    function acceptProtocolTransfer() external {
        if (msg.sender != pendingProtocolRecipient) revert OnlyPendingRecipient();
        emit ProtocolTransferAccepted(protocolRecipient, msg.sender);
        protocolRecipient = msg.sender;
        pendingProtocolRecipient = address(0);
    }

    /// @notice Accept ETH but require explicit pool association via depositFees
    /// @dev ETH sent directly without pool ID goes to untracked balance (recoverable via sweepETH)
    receive() external payable {}
}
