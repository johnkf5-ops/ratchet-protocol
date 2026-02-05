// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ============================================================================
// DEPRECATED: Use DeployRatchetHook.s.sol instead
// ============================================================================
//
// This script is deprecated because Uniswap v4 hooks require address mining.
// The hook's address must have specific permission flags encoded in its
// least significant bits.
//
// See DeployRatchetHook.s.sol for the proper deployment script that:
// 1. Mines a valid hook address with correct permission flags
// 2. Deploys the hook via CREATE2 at the mined address
// 3. Deploys the factory with the pre-deployed hook
//
// Run with:
//   forge script script/DeployRatchetHook.s.sol --rpc-url $RPC_URL --broadcast
//
// ============================================================================

import {Script, console} from "forge-std/Script.sol";

contract DeployScript is Script {
    function run() public pure {
        revert("Deprecated: Use DeployRatchetHook.s.sol instead");
    }
}
