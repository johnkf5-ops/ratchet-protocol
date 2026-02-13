// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RatchetVault} from "../src/RatchetVault.sol";
import {RatchetToken} from "../src/RatchetToken.sol";

contract RatchetVaultTest is Test {
    RatchetVault public vault;
    RatchetToken public token;

    address public hook = makeAddr("hook");
    address public team = makeAddr("team");

    uint256 constant TOTAL_SUPPLY = 1_000_000e18;
    uint256 constant VAULT_SUPPLY = 100_000e18;
    uint256 constant LP_SUPPLY = 900_000e18;
    uint256 constant INITIAL_RATE = 1000; // 10%

    function setUp() public {
        // Deploy vault first (no token needed in constructor)
        vault = new RatchetVault(hook, team, INITIAL_RATE, "");

        // Deploy token - it mints to vault
        token = new RatchetToken(
            "Test Token", "TEST", LP_SUPPLY, VAULT_SUPPLY, address(this), address(vault)
        );

        // Initialize vault with token address (sets vaultStartingBalance)
        vault.initialize(address(token));

        // Auto-claim: test contract acts as factory
        vault.setClaimed(team);
    }

    function test_InitialState() public view {
        assertEq(vault.reactiveSellRate(), INITIAL_RATE);
        assertEq(vault.teamRecipient(), team);
        assertEq(vault.hook(), hook);
        assertEq(vault.token(), address(token));
    }

    function test_initializeSetsStartingBalance() public view {
        assertEq(vault.vaultStartingBalance(), VAULT_SUPPLY);
    }

    function test_sellBasedOnBuyAmountWithRate() public {
        uint256 buyAmount = 10_000e18;
        uint256 expectedSell = (buyAmount * INITIAL_RATE) / 10000; // 10% of buy = 1000e18
        // But capped at per-trigger max: 0.1% of 100_000e18 = 100e18
        uint256 maxTrigger = (VAULT_SUPPLY * 10) / 10000;

        vm.prank(hook);
        uint256 sellAmount = vault.onBuy(buyAmount);

        // Since expectedSell (1000e18) > maxTrigger (100e18), it should be capped
        assertEq(sellAmount, maxTrigger);
    }

    function test_ReactiveSell() public {
        // Use a small buy so per-trigger cap doesn't kick in
        // Per-trigger cap: 0.1% of 100,000e18 = 100e18
        // At 10% rate, buyAmount of 500e18 → sell = 50e18 (within cap)
        uint256 buyAmount = 500e18;
        uint256 expectedSell = (buyAmount * INITIAL_RATE) / 10000; // 50e18

        vm.prank(hook);
        uint256 sellAmount = vault.onBuy(buyAmount);

        assertEq(sellAmount, expectedSell);
        assertEq(token.balanceOf(hook), expectedSell);
        assertEq(token.balanceOf(address(vault)), VAULT_SUPPLY - expectedSell);
    }

    function test_RatchetDecrease() public {
        uint256 newRate = 500;

        vm.prank(team);
        vault.decreaseRate(newRate);

        assertEq(vault.reactiveSellRate(), newRate);
    }

    function test_RatchetCannotIncrease() public {
        vm.prank(team);
        vault.decreaseRate(500);

        vm.prank(team);
        vm.expectRevert(RatchetVault.RateCanOnlyDecrease.selector);
        vault.decreaseRate(600);
    }

    function test_OnlyHookCanTriggerSell() public {
        vm.prank(team);
        vm.expectRevert(RatchetVault.OnlyHook.selector);
        vault.onBuy(1000e18);
    }

    function test_OnlyTeamCanDecreaseRate() public {
        vm.prank(hook);
        vm.expectRevert(RatchetVault.OnlyTeam.selector);
        vault.decreaseRate(500);
    }

    function test_ZeroRateMeansNoSell() public {
        vm.prank(team);
        vault.decreaseRate(0);

        vm.prank(hook);
        uint256 sellAmount = vault.onBuy(10_000e18);

        assertEq(sellAmount, 0);
    }

    function test_InitializeOnlyOnce() public {
        vm.expectRevert(RatchetVault.AlreadyInitialized.selector);
        vault.initialize(address(token));
    }

    function test_InitializeOnlyByFactory() public {
        RatchetVault newVault = new RatchetVault(hook, team, INITIAL_RATE, "");

        vm.prank(team);
        vm.expectRevert(RatchetVault.OnlyFactory.selector);
        newVault.initialize(address(token));
    }

    function test_ConstructorRevertsOnZeroHook() public {
        vm.expectRevert(RatchetVault.ZeroAddress.selector);
        new RatchetVault(address(0), team, INITIAL_RATE, "");
    }

    function test_InitializeRevertsOnZeroToken() public {
        RatchetVault newVault = new RatchetVault(hook, team, INITIAL_RATE, "");

        vm.expectRevert(RatchetVault.ZeroAddress.selector);
        newVault.initialize(address(0));
    }

    // ===== Per-trigger cap tests =====

    function test_onBuy_capsAt0Point1PercentPerTrigger() public {
        // Per-trigger cap: 0.1% of 100,000e18 = 100e18
        // With 10% rate and large buy: sellAmount would be large but capped at 100e18
        uint256 buyAmount = 100_000e18;
        uint256 maxTrigger = (VAULT_SUPPLY * 10) / 10000; // 100e18

        vm.prank(hook);
        uint256 sellAmount = vault.onBuy(buyAmount);

        assertEq(sellAmount, maxTrigger, "Should be capped at 0.1% per trigger");
    }

    // ===== Daily cap tests =====

    function test_onBuy_dailyCapAt0Point135Percent() public {
        // Daily cap: 0.135% of 100,000e18 = 135e18
        // Per-trigger cap: 0.1% of 100,000e18 = 100e18
        // First trigger: 100e18, second trigger: 35e18 (daily cap - first)
        uint256 buyAmount = 100_000e18;
        uint256 maxTrigger = (VAULT_SUPPLY * 10) / 10000; // 100e18
        uint256 maxDaily = (VAULT_SUPPLY * 135) / 100_000; // 135e18

        vm.prank(hook);
        uint256 sell1 = vault.onBuy(buyAmount);
        assertEq(sell1, maxTrigger);

        vm.prank(hook);
        uint256 sell2 = vault.onBuy(buyAmount);
        assertEq(sell2, maxDaily - maxTrigger, "Second sell should be capped by daily remaining");

        // Third trigger should give 0
        vm.prank(hook);
        uint256 sell3 = vault.onBuy(buyAmount);
        assertEq(sell3, 0, "Third sell should be 0 (daily cap hit)");
    }

    function test_onBuy_dailyResets() public {
        uint256 buyAmount = 100_000e18;
        uint256 maxTrigger = (VAULT_SUPPLY * 10) / 10000; // 100e18
        uint256 maxDaily = (VAULT_SUPPLY * 135) / 100_000; // 135e18

        // Exhaust daily cap
        vm.prank(hook);
        vault.onBuy(buyAmount);
        vm.prank(hook);
        vault.onBuy(buyAmount);

        // Warp to next day
        vm.warp(block.timestamp + 1 days);

        // Should be able to sell again
        vm.prank(hook);
        uint256 sellAmount = vault.onBuy(buyAmount);
        assertEq(sellAmount, maxTrigger, "Daily cap should reset on new day");

        // Verify dailySold is reset
        assertEq(vault.dailySold(), maxTrigger);
    }

    // ===== Shutoff threshold tests =====

    function test_onBuy_shutoffAt1Percent() public {
        // Use deal to set vault balance near the shutoff threshold
        // Starting balance: VAULT_SUPPLY = 100,000e18
        // Shutoff reserve: 1% = 1,000e18
        uint256 shutoffReserve = (VAULT_SUPPLY * 100) / 10000; // 1,000e18

        // Set vault balance to just above shutoff (1,050e18)
        deal(address(token), address(vault), shutoffReserve + 50e18);

        // Next buy should sell some but then trigger shutoff
        // Per-trigger cap: 0.1% of 100,000e18 = 100e18 > remaining above reserve (50e18)
        // So sell is capped at 50e18 and vault finishes
        vm.warp(block.timestamp + 1 days);
        vm.prank(hook);
        uint256 sold = vault.onBuy(100_000e18);

        assertEq(sold, 50e18, "Should sell exactly the amount above reserve");
        assertTrue(vault.vaultFinished(), "Vault should be finished");

        // Verify no more selling
        vm.warp(block.timestamp + 1 days);
        vm.prank(hook);
        uint256 sold2 = vault.onBuy(100_000e18);
        assertEq(sold2, 0, "Should not sell after finished");
    }

    function test_onBuy_shutoffTriggeredWhenBalanceAtReserve() public {
        // Set balance to exactly the shutoff reserve
        uint256 shutoffReserve = (VAULT_SUPPLY * 100) / 10000; // 1,000e18
        deal(address(token), address(vault), shutoffReserve);

        vm.warp(block.timestamp + 1 days);
        vm.prank(hook);
        uint256 sold = vault.onBuy(100_000e18);

        // balance <= shutoffReserve → sets vaultFinished, returns 0
        assertEq(sold, 0);
        assertTrue(vault.vaultFinished());
    }

    function test_onBuy_returnsZeroWhenFinished() public {
        // Set vault to near shutoff so it finishes
        uint256 shutoffReserve = (VAULT_SUPPLY * 100) / 10000;
        deal(address(token), address(vault), shutoffReserve + 10e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(hook);
        vault.onBuy(100_000e18); // This sells 10e18 and sets vaultFinished

        assertTrue(vault.vaultFinished());

        // Now any buy should return 0
        vm.warp(block.timestamp + 1 days);
        vm.prank(hook);
        uint256 sellAmount = vault.onBuy(100_000e18);
        assertEq(sellAmount, 0, "Finished vault should always return 0");
    }

    // ===== Release final tokens tests =====

    function test_releaseFinalTokens() public {
        // Set vault to near shutoff so it finishes
        uint256 shutoffReserve = (VAULT_SUPPLY * 100) / 10000; // 1,000e18
        deal(address(token), address(vault), shutoffReserve + 10e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(hook);
        vault.onBuy(100_000e18); // sells 10e18, vault finishes

        assertTrue(vault.vaultFinished());
        uint256 remaining = token.balanceOf(address(vault));
        assertEq(remaining, shutoffReserve, "Should have shutoff reserve remaining");

        uint256 teamBefore = token.balanceOf(team);
        vm.prank(team);
        vault.releaseFinalTokens();

        assertEq(token.balanceOf(team), teamBefore + remaining);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_releaseFinalTokens_revertsBeforeFinished() public {
        vm.prank(team);
        vm.expectRevert(RatchetVault.VaultNotFinished.selector);
        vault.releaseFinalTokens();
    }

    // ===== Creator mechanic tests =====

    function test_NotYetClaimedBlocksDecreaseRate() public {
        RatchetVault unclaimed = new RatchetVault(hook, team, INITIAL_RATE, "someCreator");
        unclaimed.initialize(address(token));

        vm.prank(team);
        vm.expectRevert(RatchetVault.NotYetClaimed.selector);
        unclaimed.decreaseRate(500);
    }

    function test_SetClaimedByFactory() public {
        RatchetVault unclaimed = new RatchetVault(hook, team, INITIAL_RATE, "someCreator");
        unclaimed.initialize(address(token));

        address newOwner = makeAddr("newOwner");
        unclaimed.setClaimed(newOwner);

        assertTrue(unclaimed.claimed());
        assertEq(unclaimed.teamRecipient(), newOwner);
    }

    function test_SetClaimedRevertsForNonFactory() public {
        RatchetVault unclaimed = new RatchetVault(hook, team, INITIAL_RATE, "someCreator");

        vm.prank(team);
        vm.expectRevert(RatchetVault.OnlyFactory.selector);
        unclaimed.setClaimed(team);
    }

    function test_SetClaimedRevertsIfAlreadyClaimed() public {
        RatchetVault unclaimed = new RatchetVault(hook, team, INITIAL_RATE, "someCreator");
        unclaimed.initialize(address(token));

        address owner1 = makeAddr("owner1");
        unclaimed.setClaimed(owner1);
        assertTrue(unclaimed.claimed());

        address owner2 = makeAddr("owner2");
        vm.expectRevert(RatchetVault.AlreadyClaimed.selector);
        unclaimed.setClaimed(owner2);

        assertEq(unclaimed.teamRecipient(), owner1);
    }

    function test_OnBuyWorksWhenUnclaimed() public {
        RatchetVault unclaimed = new RatchetVault(hook, team, INITIAL_RATE, "someCreator");

        RatchetToken token2 = new RatchetToken(
            "Test Token 2", "TEST2", LP_SUPPLY, VAULT_SUPPLY, address(this), address(unclaimed)
        );
        unclaimed.initialize(address(token2));

        // Use small buy to stay within per-trigger cap
        uint256 buyAmount = 500e18;
        uint256 expectedSell = (buyAmount * INITIAL_RATE) / 10000;

        vm.prank(hook);
        uint256 sellAmount = unclaimed.onBuy(buyAmount);

        assertEq(sellAmount, expectedSell);
    }

    function test_CreatorFieldIsSet() public {
        RatchetVault v = new RatchetVault(hook, team, INITIAL_RATE, "myCreatorHandle");
        assertEq(v.creator(), "myCreatorHandle");
    }

    // ===== Two-step team transfer =====

    function test_ProposeAndAcceptTeamTransfer() public {
        address newTeam = makeAddr("newTeam");

        vm.prank(team);
        vault.proposeTeamTransfer(newTeam);
        assertEq(vault.pendingTeamRecipient(), newTeam);

        vm.prank(newTeam);
        vault.acceptTeamTransfer();
        assertEq(vault.teamRecipient(), newTeam);
        assertEq(vault.pendingTeamRecipient(), address(0));
    }

    function test_ProposeTeamTransferOnlyTeam() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(RatchetVault.OnlyTeam.selector);
        vault.proposeTeamTransfer(attacker);
    }

    function test_ProposeTeamTransferRevertsZeroAddress() public {
        vm.prank(team);
        vm.expectRevert(RatchetVault.ZeroAddress.selector);
        vault.proposeTeamTransfer(address(0));
    }

    function test_ProposeTeamTransferRevertsWhenUnclaimed() public {
        RatchetVault unclaimed = new RatchetVault(hook, team, INITIAL_RATE, "creator");
        unclaimed.initialize(address(token));

        vm.prank(team);
        vm.expectRevert(RatchetVault.NotYetClaimed.selector);
        unclaimed.proposeTeamTransfer(makeAddr("newTeam"));
    }

    function test_AcceptTeamTransferOnlyPending() public {
        address newTeam = makeAddr("newTeam");
        vm.prank(team);
        vault.proposeTeamTransfer(newTeam);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(RatchetVault.OnlyPendingTeam.selector);
        vault.acceptTeamTransfer();
    }

    function test_NewTeamCanDecreaseRate() public {
        address newTeam = makeAddr("newTeam");

        vm.prank(team);
        vault.proposeTeamTransfer(newTeam);
        vm.prank(newTeam);
        vault.acceptTeamTransfer();

        vm.prank(newTeam);
        vault.decreaseRate(500);
        assertEq(vault.reactiveSellRate(), 500);
    }
}
