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
        vault = new RatchetVault(hook, team, INITIAL_RATE);

        // Deploy token - it mints to vault
        token = new RatchetToken(
            "Test Token",
            "TEST",
            LP_SUPPLY,
            VAULT_SUPPLY,
            address(this),
            address(vault)
        );

        // Initialize vault with token address
        vault.initialize(address(token));
    }

    function test_InitialState() public view {
        assertEq(vault.reactiveSellRate(), INITIAL_RATE);
        assertEq(vault.teamRecipient(), team);
        assertEq(vault.hook(), hook);
        assertEq(vault.token(), address(token));
    }

    function test_ReactiveSell() public {
        // Vault should already have VAULT_SUPPLY tokens from deployment
        assertEq(token.balanceOf(address(vault)), VAULT_SUPPLY);

        uint256 buyAmount = 10_000e18;
        uint256 expectedSell = (buyAmount * INITIAL_RATE) / 10000; // 10% of buy

        vm.prank(hook);
        uint256 sellAmount = vault.onBuy(buyAmount);

        assertEq(sellAmount, expectedSell);
        assertEq(token.balanceOf(hook), expectedSell);
        assertEq(token.balanceOf(address(vault)), VAULT_SUPPLY - expectedSell);
    }

    function test_RatchetDecrease() public {
        uint256 newRate = 500; // 5%

        vm.prank(team);
        vault.decreaseRate(newRate);

        assertEq(vault.reactiveSellRate(), newRate);
    }

    function test_RatchetCannotIncrease() public {
        // First decrease
        vm.prank(team);
        vault.decreaseRate(500);

        // Try to increase - should revert
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

    function test_ClaimFees() public {
        // Send ETH to vault via receive() to accumulate fees
        vm.deal(address(this), 1 ether);
        (bool success,) = address(vault).call{value: 1 ether}("");
        require(success, "ETH send failed");

        assertEq(vault.accumulatedFees(), 1 ether);

        uint256 teamBalanceBefore = team.balance;

        vm.prank(team);
        vault.claimFees();

        assertEq(team.balance, teamBalanceBefore + 1 ether);
        assertEq(vault.accumulatedFees(), 0);
    }

    function test_ClaimFeesRevertsWhenNoFees() public {
        vm.prank(team);
        vm.expectRevert(RatchetVault.NoFeesToClaim.selector);
        vault.claimFees();
    }

    function test_ZeroRateMeansNoSell() public {
        // Decrease rate to zero
        vm.prank(team);
        vault.decreaseRate(0);

        vm.prank(hook);
        uint256 sellAmount = vault.onBuy(10_000e18);

        assertEq(sellAmount, 0);
    }

    function test_SellCappedByBalance() public {
        // Try to trigger a sell larger than vault balance
        uint256 hugeAmount = VAULT_SUPPLY * 100; // Would result in 10x vault balance at 10% rate
        uint256 expectedSell = VAULT_SUPPLY; // Capped at actual balance

        vm.prank(hook);
        uint256 sellAmount = vault.onBuy(hugeAmount);

        assertEq(sellAmount, expectedSell);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_InitializeOnlyOnce() public {
        // Try to initialize again - should revert
        vm.expectRevert(RatchetVault.AlreadyInitialized.selector);
        vault.initialize(address(token));
    }

    function test_InitializeOnlyByFactory() public {
        // Deploy new vault
        RatchetVault newVault = new RatchetVault(hook, team, INITIAL_RATE);

        // Try to initialize from a different address
        vm.prank(team);
        vm.expectRevert(RatchetVault.OnlyFactory.selector);
        newVault.initialize(address(token));
    }

    function test_ConstructorRevertsOnZeroHook() public {
        vm.expectRevert(RatchetVault.ZeroAddress.selector);
        new RatchetVault(address(0), team, INITIAL_RATE);
    }

    function test_ConstructorRevertsOnZeroTeam() public {
        vm.expectRevert(RatchetVault.ZeroAddress.selector);
        new RatchetVault(hook, address(0), INITIAL_RATE);
    }

    function test_InitializeRevertsOnZeroToken() public {
        RatchetVault newVault = new RatchetVault(hook, team, INITIAL_RATE);

        vm.expectRevert(RatchetVault.ZeroAddress.selector);
        newVault.initialize(address(0));
    }
}
