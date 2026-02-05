// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {IRatchetFactory, LaunchParams, LaunchResult} from "./interfaces/IRatchetFactory.sol";
import {RatchetToken} from "./RatchetToken.sol";
import {RatchetVault} from "./RatchetVault.sol";
import {RatchetHook} from "./RatchetHook.sol";

/// @title RatchetFactory
/// @notice One-click token launches with ratcheting team vaults
/// @dev Deploys token + vault, creates Uniswap v4 pool, burns LP.
///      Team allocation sells reactively into buys at a rate that can only decrease.
contract RatchetFactory is IRatchetFactory {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10000;
    /// @notice Maximum team allocation (20%)
    uint256 public constant MAX_TEAM_ALLOCATION = 2000;
    /// @notice Maximum initial reactive sell rate (10%)
    uint256 public constant MAX_REACTIVE_SELL_RATE = 1000;
    /// @notice Address to burn LP tokens (dead address)
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Uniswap v4 pool manager
    IPoolManager public immutable POOL_MANAGER;
    /// @notice The hook contract for all Ratchet pools
    RatchetHook public immutable HOOK;
    /// @notice Uniswap v4 position manager for liquidity operations
    IPositionManager public immutable POSITION_MANAGER;
    /// @notice Permit2 for token approvals
    IAllowanceTransfer public immutable PERMIT2;
    /// @notice Wrapped ETH contract on this chain
    IWETH9 public immutable WETH;

    /// @notice Default swap fee (1%)
    uint24 public constant DEFAULT_FEE = 10000;
    /// @notice Tick spacing for pools
    int24 public constant TICK_SPACING = 200;

    /// @notice Counter for generating unique salts
    uint256 public launchCount;

    error TeamAllocationTooHigh();
    error ReactiveSellRateTooHigh();
    error InsufficientETH();
    error RefundFailed();

    error InvalidHook();

    /// @notice Deploy the factory with a pre-deployed hook
    /// @dev The hook must be deployed at a mined address with correct permission flags.
    ///      Use the DeployRatchetHook script to deploy the hook first.
    /// @param poolManager_ Uniswap v4 pool manager address
    /// @param positionManager_ Uniswap v4 position manager address
    /// @param permit2_ Permit2 address for token approvals
    /// @param weth_ WETH address on this chain
    /// @param hook_ Pre-deployed RatchetHook at a mined address
    constructor(
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        IWETH9 weth_,
        RatchetHook hook_
    ) {
        // Validate hook has correct permissions encoded in address
        if (address(hook_) == address(0)) revert InvalidHook();
        // The hook's constructor validates its own address flags via validateHookPermissions

        POOL_MANAGER = poolManager_;
        POSITION_MANAGER = positionManager_;
        PERMIT2 = permit2_;
        WETH = weth_;
        HOOK = hook_;

        // Approve Permit2 to spend WETH (unlimited, one-time setup)
        IERC20(address(weth_)).approve(address(permit2_), type(uint256).max);
        // Approve PositionManager in Permit2 for WETH
        permit2_.approve(address(weth_), address(positionManager_), type(uint160).max, type(uint48).max);
    }

    /// @notice Launch a new token with Ratchet mechanism
    /// @dev Deploys token, vault, creates pool, adds liquidity, burns LP.
    ///      Any unused ETH is refunded to the caller.
    /// @param params Launch configuration (name, symbol, supply, allocations, price)
    /// @return result Deployed addresses and pool ID
    function launch(LaunchParams calldata params) external payable returns (LaunchResult memory result) {
        if (params.teamAllocationBps > MAX_TEAM_ALLOCATION) revert TeamAllocationTooHigh();
        if (params.initialReactiveSellRate > MAX_REACTIVE_SELL_RATE) revert ReactiveSellRateTooHigh();
        if (msg.value == 0) revert InsufficientETH();

        // Track ETH balance before operations
        uint256 ethBefore = address(this).balance - msg.value;

        // Split supply between LP and team vault
        uint256 vaultSupply = (params.totalSupply * params.teamAllocationBps) / BPS_DENOMINATOR;
        uint256 lpSupply = params.totalSupply - vaultSupply;

        // Generate unique salt for this launch (deterministic based on sender, count, and params)
        bytes32 salt = keccak256(abi.encode(
            msg.sender,
            launchCount++,
            params.name,
            params.symbol,
            params.totalSupply
        ));

        // Compute vault address using CREATE2 (vault doesn't need token in constructor)
        address vaultAddress = _computeCreate2Address(salt, params.initialReactiveSellRate, msg.sender);

        // Deploy token - mints LP portion here, team portion to vault address
        RatchetToken token = new RatchetToken(
            params.name,
            params.symbol,
            lpSupply,
            vaultSupply,
            address(this),
            vaultAddress
        );

        // Deploy vault with CREATE2
        RatchetVault vault = new RatchetVault{salt: salt}(
            address(HOOK),
            msg.sender,
            params.initialReactiveSellRate
        );
        require(address(vault) == vaultAddress, "Vault address mismatch");

        // Initialize vault with token address
        vault.initialize(address(token));

        // Create pool key with sorted currencies
        (Currency currency0, Currency currency1) = _sortCurrencies(
            Currency.wrap(address(WETH)),
            Currency.wrap(address(token))
        );

        // Track whether token is currency0 or currency1 for buy detection
        bool tokenIsCurrency0 = Currency.unwrap(currency0) == address(token);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: DEFAULT_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(HOOK))
        });

        // Register pool with hook before initialization (include token position for buy detection)
        HOOK.registerPool(key, address(token), address(vault), tokenIsCurrency0);

        // Initialize pool at specified price
        POOL_MANAGER.initialize(key, params.initialSqrtPriceX96);

        // Add liquidity and burn LP position
        _addInitialLiquidity(key, lpSupply, params.initialSqrtPriceX96);

        result = LaunchResult({
            token: address(token),
            vault: address(vault),
            poolId: PoolId.unwrap(key.toId())
        });

        emit TokenLaunched(
            address(token),
            address(vault),
            result.poolId,
            params.name,
            params.symbol,
            msg.sender
        );

        // Refund any unused ETH to caller
        uint256 ethAfter = address(this).balance;
        uint256 refund = ethAfter - ethBefore;
        if (refund > 0) {
            (bool success,) = msg.sender.call{value: refund}("");
            if (!success) revert RefundFailed();
        }

        return result;
    }

    /// @notice Add initial liquidity and burn the LP position
    /// @dev Wraps ETH to WETH, approves tokens, mints full-range position to burn address
    /// @param key The pool key for the liquidity position
    /// @param tokenAmount Amount of tokens for LP
    /// @param sqrtPriceX96 Current pool price for liquidity calculation
    function _addInitialLiquidity(
        PoolKey memory key,
        uint256 tokenAmount,
        uint160 sqrtPriceX96
    ) internal {
        // 1. Wrap ETH to WETH
        uint256 ethAmount = msg.value;
        WETH.deposit{value: ethAmount}();

        // 2. Approve Permit2 for the new token and set PositionManager allowance
        address token = Currency.unwrap(key.currency0) == address(WETH)
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);
        IERC20(token).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(token, address(POSITION_MANAGER), type(uint160).max, type(uint48).max);

        // 3. Calculate full-range tick bounds aligned to tick spacing
        int24 tickLower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;

        // 4. Calculate liquidity from available amounts
        // Determine which currency is WETH (amount0 or amount1)
        bool wethIsCurrency0 = Currency.unwrap(key.currency0) == address(WETH);
        (uint256 amount0, uint256 amount1) = wethIsCurrency0
            ? (ethAmount, tokenAmount)
            : (tokenAmount, ethAmount);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        // 5. Build action plan: MINT_POSITION to BURN_ADDRESS, then SETTLE_PAIR
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        // MINT_POSITION params: poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            liquidity,
            type(uint128).max, // amount0Max (no slippage check for initial mint)
            type(uint128).max, // amount1Max
            BURN_ADDRESS,      // LP NFT goes directly to burn address
            ""                 // hookData
        );
        // SETTLE_PAIR params: currency0, currency1
        params[1] = abi.encode(key.currency0, key.currency1);

        // 6. Execute the mint - deadline is current block timestamp + buffer
        bytes memory unlockData = abi.encode(actions, params);
        POSITION_MANAGER.modifyLiquidities(unlockData, block.timestamp + 60);
    }

    /// @notice Compute CREATE2 address for vault deployment
    /// @param salt Unique salt for this deployment
    /// @param initialReactiveSellRate_ Initial sell rate for vault
    /// @param teamRecipient_ Team recipient address
    /// @return Predicted vault address
    function _computeCreate2Address(
        bytes32 salt,
        uint256 initialReactiveSellRate_,
        address teamRecipient_
    ) internal view returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(RatchetVault).creationCode,
            abi.encode(
                address(HOOK),
                teamRecipient_,
                initialReactiveSellRate_
            )
        );

        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(bytecode)
        )))));
    }

    /// @notice Sort two currencies by address for consistent pool key ordering
    /// @param a First currency
    /// @param b Second currency
    /// @return Lower address first, higher address second
    function _sortCurrencies(Currency a, Currency b) internal pure returns (Currency, Currency) {
        return Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
    }

    /// @notice Accept ETH for liquidity provision
    receive() external payable {}
}
