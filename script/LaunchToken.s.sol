// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IRatchetFactory, LaunchParams, LaunchResult} from "../src/interfaces/IRatchetFactory.sol";

/// @title LaunchToken
/// @notice Script to launch a test token on the deployed RatchetFactory
contract LaunchTokenScript is Script {
    // Deployed RatchetFactory on Base Sepolia
    address constant FACTORY = 0xe562B41c0E1B9260AF721dBFC49478A052A8bA64;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Token parameters
        string memory name = "Test Ratchet Token";
        string memory symbol = "RTEST";
        uint256 totalSupply = 1_000_000_000 * 1e18; // 1 billion tokens
        uint256 teamAllocationBps = 1000; // 10%
        uint256 initialReactiveSellRate = 500; // 5%

        // Initial price calculation:
        // We want 1 ETH = 1,000,000 tokens (each token = 0.000001 ETH)
        uint160 initialSqrtPriceX96 = 79228162514264337593543950336 * 1000; // 1 ETH = 1M tokens

        uint256 ethForLiquidity = 0.001 ether;

        console.log("=== Launching Test Token ===");
        console.log("");
        console.log("Token Parameters:");
        console.log("  Name:", name);
        console.log("  Symbol:", symbol);
        console.log("  Total Supply: 1,000,000,000 tokens");
        console.log("  Team Allocation: 10%");
        console.log("  Reactive Sell Rate: 5%");
        console.log("  ETH for Liquidity:", ethForLiquidity);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        LaunchParams memory params = LaunchParams({
            name: name,
            symbol: symbol,
            totalSupply: totalSupply,
            teamAllocationBps: teamAllocationBps,
            initialReactiveSellRate: initialReactiveSellRate,
            initialSqrtPriceX96: initialSqrtPriceX96,
            creator: ""
        });

        LaunchResult memory result = IRatchetFactory(FACTORY).launch{value: ethForLiquidity}(params);

        vm.stopBroadcast();

        console.log("=== Launch Successful ===");
        console.log("");
        console.log("Deployed Contracts:");
        console.log("  Token:", result.token);
        console.log("  Vault:", result.vault);
        console.log("  Staking:", result.staking);
        console.log("  Pool ID:", vm.toString(result.poolId));
        console.log("");
        console.log("Token Distribution:");
        console.log("  LP Supply: 900,000,000 tokens (90%)");
        console.log("  Vault Supply: 100,000,000 tokens (10%)");
    }
}
