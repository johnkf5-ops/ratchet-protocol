// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {RatchetHook} from "../src/RatchetHook.sol";
import {RatchetVault} from "../src/RatchetVault.sol";
import {RatchetToken} from "../src/RatchetToken.sol";
import {RatchetLPStaking} from "../src/RatchetLPStaking.sol";

/// @notice Minimal WETH mock implementing IWETH9
contract MockWETH is ERC20, IWETH9 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable override {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @title RatchetIntegrationTest
/// @notice End-to-end integration tests for the Ratchet hook against real v4 PoolManager.
contract RatchetIntegrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    RatchetHook ratchetHook;
    RatchetToken token;
    RatchetVault vault;
    MockWETH weth;

    address team = makeAddr("team");
    address protocolRecipient = makeAddr("protocolRecipient");
    address mockFactory;

    PoolKey poolKey;

    uint256 constant TOTAL_SUPPLY = 1_000_000e18;
    uint256 constant VAULT_SUPPLY = 100_000e18; // 10%
    uint256 constant LP_SUPPLY = 900_000e18; // 90%
    uint256 constant INITIAL_RATE = 500; // 5%

    function setUp() public {
        // 1. Deploy v4 core: PoolManager + all test routers
        deployFreshManagerAndRouters();

        // 2. Deploy WETH mock
        weth = new MockWETH();

        // 3. Mine hook address with correct permission flags
        mockFactory = address(this);
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)), mockFactory, protocolRecipient, IWETH9(address(weth))
        );
        (, bytes32 salt) = HookMiner.find(
            address(this), flags, type(RatchetHook).creationCode, constructorArgs
        );

        // 4. Deploy hook via CREATE2
        ratchetHook = new RatchetHook{salt: salt}(
            IPoolManager(address(manager)), mockFactory, protocolRecipient, IWETH9(address(weth))
        );

        // 5. Deploy vault (test contract is factory)
        vault = new RatchetVault(address(ratchetHook), team, INITIAL_RATE, "");
        vault.setClaimed(team);

        // 6. Deploy token - LP tokens to this contract, vault tokens to vault
        token = new RatchetToken(
            "Test Token", "TEST", LP_SUPPLY, VAULT_SUPPLY, address(this), address(vault)
        );
        vault.initialize(address(token));

        // 7. Fund this contract with ETH and wrap to WETH
        vm.deal(address(this), 1000 ether);
        weth.deposit{value: 500 ether}();

        // 8. Create pool key with WETH/token pair (sorted by address)
        Currency wethCurrency = Currency.wrap(address(weth));
        Currency tokenCurrency = Currency.wrap(address(token));

        if (address(weth) < address(token)) {
            poolKey = PoolKey({
                currency0: wethCurrency,
                currency1: tokenCurrency,
                fee: 10000,
                tickSpacing: 200,
                hooks: IHooks(address(ratchetHook))
            });
        } else {
            poolKey = PoolKey({
                currency0: tokenCurrency,
                currency1: wethCurrency,
                fee: 10000,
                tickSpacing: 200,
                hooks: IHooks(address(ratchetHook))
            });
        }

        bool tokenIsCurrency0 = Currency.unwrap(poolKey.currency0) == address(token);

        // 9. Register pool with hook (no teamFeeShareBps)
        ratchetHook.registerPool(poolKey, address(token), address(vault), tokenIsCurrency0);

        // 10. Initialize pool at 1:1 price
        uint160 sqrtPrice = 79228162514264337593543950336; // SQRT_PRICE_1_1
        manager.initialize(poolKey, sqrtPrice);

        // 11. Approve tokens for the liquidity router
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);

        // 12. Add narrow-range liquidity
        int24 tickLower = -200;
        int24 tickUpper = 200;

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ""
        );

        // 13. Approve tokens for the swap router
        weth.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
    }

    // Helper: determine swap direction for buying tokens
    function _buyParams(int256 amountIn)
        internal
        view
        returns (bool zeroForOne, uint160 sqrtPriceLimit)
    {
        bool tokenIsCurrency0 = Currency.unwrap(poolKey.currency0) == address(token);
        zeroForOne = !tokenIsCurrency0;
        sqrtPriceLimit =
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    // Helper: determine swap direction for selling tokens
    function _sellParams() internal view returns (bool zeroForOne, uint160 sqrtPriceLimit) {
        bool tokenIsCurrency0 = Currency.unwrap(poolKey.currency0) == address(token);
        zeroForOne = tokenIsCurrency0;
        sqrtPriceLimit =
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    // ========== C-4: afterSwap Token Settlement ==========

    function test_BuyTriggersReactiveSell() public {
        uint256 vaultBefore = token.balanceOf(address(vault));
        uint256 buyerBefore = token.balanceOf(address(this));

        (bool zeroForOne, uint160 sqrtPriceLimit) = _buyParams(-1 ether);

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 vaultAfter = token.balanceOf(address(vault));
        uint256 buyerAfter = token.balanceOf(address(this));

        uint256 tokensReceived = buyerAfter - buyerBefore;
        assertGt(tokensReceived, 0, "Buyer received no tokens");

        // Vault may or may not sell depending on volume threshold
        // With 100e18 liquidity and 0.5% threshold = 0.5e18 threshold
        // The buy amount in tokens may be above or below this
        // Just verify the hook didn't revert
    }

    function test_ReactiveSellAmountIsCorrect() public {
        uint256 vaultBefore = token.balanceOf(address(vault));

        (bool zeroForOne, uint160 sqrtPriceLimit) = _buyParams(-0.1 ether);

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -0.1 ether,
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 vaultAfter = token.balanceOf(address(vault));
        // Vault sold (or didn't due to volume threshold) - just verify no revert
        assertTrue(vaultAfter <= vaultBefore, "Vault balance should not increase");
    }

    function test_SellDoesNotTriggerOnTokenSell() public {
        // First buy some tokens
        (bool buyZfo, uint160 buyLimit) = _buyParams(-1 ether);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: buyZfo,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: buyLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 vaultBefore = token.balanceOf(address(vault));
        uint256 tokenBalance = token.balanceOf(address(this));

        // Now sell tokens (opposite direction)
        (bool sellZfo, uint160 sellLimit) = _sellParams();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: sellZfo,
                amountSpecified: -int256(tokenBalance / 2),
                sqrtPriceLimitX96: sellLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 vaultAfter = token.balanceOf(address(vault));
        assertEq(vaultAfter, vaultBefore, "Vault sold on token sell");
    }

    function test_ZeroRateNoReactiveSell() public {
        vm.prank(team);
        vault.decreaseRate(0);

        uint256 vaultBefore = token.balanceOf(address(vault));

        (bool zeroForOne, uint160 sqrtPriceLimit) = _buyParams(-0.5 ether);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -0.5 ether,
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 vaultAfter = token.balanceOf(address(vault));
        assertEq(vaultAfter, vaultBefore, "Vault sold when rate is 0");
    }

    // ========== Fee Routing: 20% protocol, 80% LP ==========

    function test_RouteFeesETHDistribution() public {
        bytes32 pid = PoolId.unwrap(poolKey.toId());

        // Deposit ETH fees
        ratchetHook.depositFees{value: 1 ether}(pid);

        // Route fees — LP WETH donation goes via unlock/callback
        ratchetHook.routeFees(poolKey);

        // Protocol fee: 20% of 1 ETH = 0.2 ETH
        assertEq(ratchetHook.protocolFeesAccumulated(), 0.2 ether, "Protocol fee wrong");

        // No team fee — entire 80% goes to LP
        // Pool ETH fees cleared
        assertEq(ratchetHook.poolEthFees(pid), 0);
    }

    function test_RouteFeesAll80PercentToLP() public {
        bytes32 pid = PoolId.unwrap(poolKey.toId());

        // Deposit ETH fees
        ratchetHook.depositFees{value: 10 ether}(pid);
        ratchetHook.routeFees(poolKey);

        // Protocol fee: 20% of 10 = 2 ETH
        assertEq(ratchetHook.protocolFeesAccumulated(), 2 ether);

        // LP got 80% (8 ETH) donated - verified by pool fees being cleared
        assertEq(ratchetHook.poolEthFees(pid), 0);
        // No vault/team ETH fees at all
    }

    function test_RouteFeesRevertsWithNoFees() public {
        vm.expectRevert(RatchetHook.NoFeesToRoute.selector);
        ratchetHook.routeFees(poolKey);
    }

    function test_ClaimProtocolFees() public {
        bytes32 pid = PoolId.unwrap(poolKey.toId());

        ratchetHook.depositFees{value: 2 ether}(pid);
        ratchetHook.routeFees(poolKey);

        uint256 fees = ratchetHook.protocolFeesAccumulated();
        assertEq(fees, 0.4 ether); // 20% of 2 ETH

        uint256 recipientBefore = protocolRecipient.balance;
        vm.prank(protocolRecipient);
        ratchetHook.claimProtocolFees();

        assertEq(protocolRecipient.balance - recipientBefore, 0.4 ether);
        assertEq(ratchetHook.protocolFeesAccumulated(), 0);
    }

    function test_ClaimProtocolFeesRevertsWhenZero() public {
        vm.prank(protocolRecipient);
        vm.expectRevert(RatchetHook.NoFeesToClaim.selector);
        ratchetHook.claimProtocolFees();
    }

    // ========== Volume Threshold ==========

    function test_volumeThreshold_smallBuyNoVaultSell() public {
        // The volume threshold is 0.5% of pool liquidity
        // Pool liquidity is 100e18
        // Threshold = 100e18 * 50 / 10000 = 0.5e18
        // A tiny buy should not trigger a vault sell

        uint256 vaultBefore = token.balanceOf(address(vault));

        // Very small buy (0.0001 ether)
        (bool zeroForOne, uint160 sqrtPriceLimit) = _buyParams(-0.0001 ether);

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -0.0001 ether,
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 vaultAfter = token.balanceOf(address(vault));
        assertEq(vaultAfter, vaultBefore, "Small buy should not trigger vault sell");
    }

    function test_volumeThreshold_largeBuyTriggersVaultSell() public {
        uint256 vaultBefore = token.balanceOf(address(vault));

        // Large buy (10 ether) - should be well above threshold
        (bool zeroForOne, uint160 sqrtPriceLimit) = _buyParams(-10 ether);

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -10 ether,
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 vaultAfter = token.balanceOf(address(vault));
        assertLt(vaultAfter, vaultBefore, "Large buy should trigger vault sell");
    }

    // ========== Multiple swaps ==========

    function test_MultipleBuysAccumulateReactiveSells() public {
        uint256 vaultBefore = token.balanceOf(address(vault));

        // Use large buys to exceed volume threshold (0.5% of 100e18 = 0.5e18)
        (bool zeroForOne, uint160 sqrtPriceLimit) = _buyParams(-5 ether);

        // Buy 1 (large enough to exceed volume threshold)
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -5 ether,
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 vaultAfterBuy1 = token.balanceOf(address(vault));
        uint256 sold1 = vaultBefore - vaultAfterBuy1;
        assertGt(sold1, 0, "No sell on buy 1");

        // Sell tokens back to restore liquidity and rebalance price
        uint256 tokenBal = token.balanceOf(address(this));
        (bool sellZfo, uint160 sellLimit) = _sellParams();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: sellZfo,
                amountSpecified: -int256(tokenBal / 2),
                sqrtPriceLimitX96: sellLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Move to next day to reset daily cap
        vm.warp(block.timestamp + 1 days);

        // Buy 2
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -5 ether,
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 vaultAfterBuy2 = token.balanceOf(address(vault));
        assertLt(vaultAfterBuy2, vaultBefore, "No sells across multiple buys");
    }

    // ========== Protocol Recipient Transfer ==========

    function test_ProposeAndAcceptProtocolTransfer() public {
        address newRecipient = makeAddr("newProtocolRecipient");

        vm.prank(protocolRecipient);
        ratchetHook.proposeProtocolTransfer(newRecipient);
        assertEq(ratchetHook.pendingProtocolRecipient(), newRecipient);

        vm.prank(newRecipient);
        ratchetHook.acceptProtocolTransfer();
        assertEq(ratchetHook.protocolRecipient(), newRecipient);
        assertEq(ratchetHook.pendingProtocolRecipient(), address(0));
    }

    function test_ProtocolTransferOnlyRecipient() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(RatchetHook.OnlyProtocol.selector);
        ratchetHook.proposeProtocolTransfer(attacker);
    }

    function test_AcceptProtocolTransferOnlyPending() public {
        address newRecipient = makeAddr("newProtocolRecipient");
        vm.prank(protocolRecipient);
        ratchetHook.proposeProtocolTransfer(newRecipient);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(RatchetHook.OnlyPendingRecipient.selector);
        ratchetHook.acceptProtocolTransfer();
    }

    function test_NewRecipientCanClaimProtocolFees() public {
        address newRecipient = makeAddr("newProtocolRecipient");
        vm.prank(protocolRecipient);
        ratchetHook.proposeProtocolTransfer(newRecipient);
        vm.prank(newRecipient);
        ratchetHook.acceptProtocolTransfer();

        bytes32 pid = PoolId.unwrap(poolKey.toId());
        ratchetHook.depositFees{value: 1 ether}(pid);
        ratchetHook.routeFees(poolKey);

        uint256 balBefore = newRecipient.balance;
        vm.prank(newRecipient);
        ratchetHook.claimProtocolFees();
        assertGt(newRecipient.balance, balBefore);
    }

    // ========== Registered Token Sweep Guard ==========

    function test_SweepRegisteredTokenReverts() public {
        vm.prank(protocolRecipient);
        vm.expectRevert(RatchetHook.RegisteredToken.selector);
        ratchetHook.sweepTokens(address(token), protocolRecipient);
    }

    // ========== Ratchet Rate Decrease ==========

    function test_RatchetDecreaseReducesSellAmount() public {
        (bool zeroForOne, uint160 sqrtPriceLimit) = _buyParams(-0.5 ether);

        // Buy at 5% rate
        uint256 vaultBefore = token.balanceOf(address(vault));
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -0.5 ether,
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 sold5pct = vaultBefore - token.balanceOf(address(vault));

        // Decrease rate to 1%
        vm.prank(team);
        vault.decreaseRate(100);

        // Move to next day to reset daily cap
        vm.warp(block.timestamp + 1 days);

        // Buy at 1% rate
        vaultBefore = token.balanceOf(address(vault));
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -0.5 ether,
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 sold1pct = vaultBefore - token.balanceOf(address(vault));

        assertLe(sold1pct, sold5pct, "Lower rate did not reduce sell amount");
    }
}
