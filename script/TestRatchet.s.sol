// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {RatchetVault} from "../src/RatchetVault.sol";

/// @title TestRatchet
/// @notice Script to test the ratchet mechanism on a deployed vault
contract TestRatchetScript is Script {
    // Deployed RatchetVault on Base Sepolia
    address constant VAULT = 0x1996C44E586f7EA014C7FD124A7250525be1bF2b;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        RatchetVault vault = RatchetVault(payable(VAULT));

        console.log("=== Testing Ratchet Mechanism ===");
        console.log("");
        console.log("Vault:", VAULT);
        console.log("Team Recipient:", vault.teamRecipient());
        console.log("");

        // Step 1: Read current rate
        uint256 currentRate = vault.reactiveSellRate();
        console.log("Step 1: Current reactive sell rate:", currentRate, "bps");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 2: Decrease rate to 400 (4%)
        console.log("Step 2: Decreasing rate to 400 bps (4%)...");
        vault.decreaseRate(400);
        console.log("        Transaction successful!");

        vm.stopBroadcast();

        // Step 3: Read rate again to confirm
        uint256 newRate = vault.reactiveSellRate();
        console.log("");
        console.log("Step 3: New reactive sell rate:", newRate, "bps");
        console.log("");
        console.log("=== Decrease Test Complete ===");
        console.log("  - Original rate:", currentRate, "bps");
        console.log("  - New rate:", newRate, "bps");
    }
}

/// @title TestRatchetRevert
/// @notice Script to test that increasing the rate reverts
contract TestRatchetRevertScript is Script {
    address constant VAULT = 0x1996C44E586f7EA014C7FD124A7250525be1bF2b;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        RatchetVault vault = RatchetVault(payable(VAULT));

        console.log("=== Testing Ratchet Revert ===");
        console.log("");
        console.log("Current rate:", vault.reactiveSellRate(), "bps");
        console.log("");
        console.log("Attempting to increase rate to 500 bps...");
        console.log("This SHOULD revert with RateCanOnlyDecrease!");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // This should revert!
        vault.decreaseRate(500);

        vm.stopBroadcast();

        console.log("ERROR: Should have reverted but didn't!");
    }
}
