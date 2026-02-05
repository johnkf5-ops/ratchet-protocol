// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {RatchetHook} from "../src/RatchetHook.sol";
import {RatchetFactory} from "../src/RatchetFactory.sol";

/// @title DeployRatchetHook
/// @notice Deploys the complete Ratchet protocol with proper hook address mining
///
/// ## Hook Address Mining Explained
///
/// Uniswap v4 uses a novel approach where hook permissions are encoded in the hook's
/// address itself. The least significant 14 bits of the address determine which
/// callbacks the PoolManager will invoke:
///
/// ```
/// Address: 0x...XXXX
///              ^^^^-- These 14 bits are permission flags
/// ```
///
/// ### Permission Flag Bits (from Hooks.sol)
///
/// | Bit | Flag                            | Value  |
/// |-----|--------------------------------|--------|
/// | 13  | BEFORE_INITIALIZE              | 0x2000 |
/// | 12  | AFTER_INITIALIZE               | 0x1000 |
/// | 11  | BEFORE_ADD_LIQUIDITY           | 0x0800 |
/// | 10  | AFTER_ADD_LIQUIDITY            | 0x0400 |
/// |  9  | BEFORE_REMOVE_LIQUIDITY        | 0x0200 |
/// |  8  | AFTER_REMOVE_LIQUIDITY         | 0x0100 |
/// |  7  | BEFORE_SWAP                    | 0x0080 |
/// |  6  | AFTER_SWAP                     | 0x0040 |
/// |  5  | BEFORE_DONATE                  | 0x0020 |
/// |  4  | AFTER_DONATE                   | 0x0010 |
/// |  3  | BEFORE_SWAP_RETURNS_DELTA      | 0x0008 |
/// |  2  | AFTER_SWAP_RETURNS_DELTA       | 0x0004 |
/// |  1  | AFTER_ADD_LIQ_RETURNS_DELTA    | 0x0002 |
/// |  0  | AFTER_REMOVE_LIQ_RETURNS_DELTA | 0x0001 |
///
/// ### RatchetHook Requirements
///
/// RatchetHook needs:
/// - AFTER_SWAP (bit 6) = 0x0040 - to intercept buys and trigger reactive sells
/// - AFTER_SWAP_RETURNS_DELTA (bit 2) = 0x0004 - to return additional tokens
///
/// Combined flags = 0x0044 (decimal 68)
///
/// This means the hook address must end in `...0044` or any pattern where
/// bits 6 and 2 are set, and other flag bits are cleared.
///
/// Example valid addresses:
/// - 0x...00000044
/// - 0x...12340044
/// - 0x...ABCD0044
///
/// ### Why Address-Based Permissions?
///
/// 1. **Gas Efficiency**: No storage reads needed to check permissions
/// 2. **Immutability**: Permissions can't be changed after deployment
/// 3. **Transparency**: Anyone can verify hook capabilities from the address
/// 4. **Security**: Hooks can't lie about their capabilities
///
/// ### How Mining Works
///
/// Since CREATE doesn't allow choosing addresses, we use CREATE2:
///
/// ```
/// address = keccak256(0xFF ++ deployer ++ salt ++ keccak256(bytecode))[12:]
/// ```
///
/// By iterating through different salt values, we find one that produces
/// an address with the required flag bits. The HookMiner library handles this.
///
/// ### Deployment Flow
///
/// 1. Calculate required permission flags from hook's getHookPermissions()
/// 2. Mine a salt that produces a valid address
/// 3. Deploy hook via CREATE2 at the mined address
/// 4. Deploy factory with the hook address
///
contract DeployRatchetHookScript is Script {
    /// @notice The deterministic CREATE2 deployer (available on most EVM chains)
    /// @dev See: https://github.com/Arachnid/deterministic-deployment-proxy
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    // Base Mainnet addresses (from https://docs.uniswap.org/contracts/v4/deployments)
    address constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant BASE_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address constant BASE_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    // Base Sepolia addresses (from https://docs.uniswap.org/contracts/v4/deployments)
    address constant SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant SEPOLIA_POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address constant SEPOLIA_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant SEPOLIA_WETH = 0x4200000000000000000000000000000000000006;

    /// @notice Default team fee share (5%)
    uint256 constant DEFAULT_TEAM_FEE_SHARE = 500;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bool isTestnet = vm.envOr("TESTNET", true);

        address poolManager = isTestnet ? SEPOLIA_POOL_MANAGER : BASE_POOL_MANAGER;
        address positionManager = isTestnet ? SEPOLIA_POSITION_MANAGER : BASE_POSITION_MANAGER;
        address permit2 = isTestnet ? SEPOLIA_PERMIT2 : BASE_PERMIT2;
        address weth = isTestnet ? SEPOLIA_WETH : BASE_WETH;

        require(poolManager != address(0), "Pool manager address not set");
        require(positionManager != address(0), "Position manager address not set");

        console.log("=== Ratchet Protocol Deployment ===");
        console.log("");

        // Step 1: Calculate required hook flags
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        console.log("Step 1: Hook Permission Flags");
        console.log("  AFTER_SWAP (bit 6):", Hooks.AFTER_SWAP_FLAG);
        console.log("  AFTER_SWAP_RETURNS_DELTA (bit 2):", Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        console.log("  Combined flags:", flags);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 2: Compute factory address (needed for hook constructor)
        // The hook deployment via CREATE2 uses nonce 0, so factory will be at nonce 1
        address deployer = vm.addr(deployerPrivateKey);
        uint64 currentNonce = vm.getNonce(deployer);
        uint64 factoryNonce = currentNonce + 1; // +1 because CREATE2 call uses one nonce
        address predictedFactoryAddress = vm.computeCreateAddress(deployer, factoryNonce);

        console.log("Step 2: Address Prediction");
        console.log("  Deployer:", deployer);
        console.log("  Current nonce:", currentNonce);
        console.log("  Factory nonce (after hook deploy):", factoryNonce);
        console.log("  Predicted factory address:", predictedFactoryAddress);
        console.log("");

        // Step 3: Mine hook address
        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManager),
            predictedFactoryAddress,
            DEFAULT_TEAM_FEE_SHARE
        );

        console.log("Step 3: Mining Hook Address...");
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(RatchetHook).creationCode,
            constructorArgs
        );

        console.log("  Mined address:", hookAddress);
        console.log("  Salt:", vm.toString(salt));
        console.log("  Address flags:", uint160(hookAddress) & Hooks.ALL_HOOK_MASK);
        console.log("");

        // Step 4: Deploy hook via CREATE2 Deployer
        console.log("Step 4: Deploying Hook via CREATE2...");
        bytes memory hookBytecode = abi.encodePacked(
            type(RatchetHook).creationCode,
            constructorArgs
        );

        // CREATE2 Deployer expects: salt (32 bytes) ++ bytecode
        (bool success,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, hookBytecode));
        require(success, "Hook deployment failed");

        RatchetHook hook = RatchetHook(payable(hookAddress));
        require(address(hook).code.length > 0, "Hook not deployed");
        console.log("  RatchetHook deployed at:", address(hook));
        console.log("");

        // Step 5: Deploy factory with the mined hook
        console.log("Step 5: Deploying Factory...");
        RatchetFactory factory = new RatchetFactory(
            IPoolManager(poolManager),
            IPositionManager(positionManager),
            IAllowanceTransfer(permit2),
            IWETH9(weth),
            hook
        );

        require(address(factory) == predictedFactoryAddress, "Factory address mismatch!");
        console.log("  RatchetFactory deployed at:", address(factory));
        console.log("");

        // Verify hook ownership
        require(hook.FACTORY() == address(factory), "Hook factory mismatch");

        vm.stopBroadcast();

        console.log("=== Deployment Complete ===");
        console.log("Hook:", address(hook));
        console.log("Factory:", address(factory));
    }

}
