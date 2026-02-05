# Uniswap v4 Hook Address Mining

## Overview

Uniswap v4 uses a novel mechanism where a hook's permissions are encoded directly in its
contract address. This document explains why this is necessary and how Ratchet handles it.

## The Problem

In Uniswap v4, hooks can implement various callbacks (beforeSwap, afterSwap, etc.). The
PoolManager needs to know which callbacks to invoke for each hook. Traditional approaches
would store this in a mapping or have the hook report its capabilities, but v4 takes a
different approach.

## Address-Based Permissions

The **least significant 14 bits** of a hook's address encode its permission flags:

```
Hook Address: 0x1234567890ABCDEF1234567890ABCDEF12340044
                                                   ^^^^
                                                   Permission flags (14 bits)
```

### Permission Flag Layout

| Bit | Permission                       | Hex    | Decimal |
|-----|----------------------------------|--------|---------|
| 13  | BEFORE_INITIALIZE                | 0x2000 | 8192    |
| 12  | AFTER_INITIALIZE                 | 0x1000 | 4096    |
| 11  | BEFORE_ADD_LIQUIDITY             | 0x0800 | 2048    |
| 10  | AFTER_ADD_LIQUIDITY              | 0x0400 | 1024    |
| 9   | BEFORE_REMOVE_LIQUIDITY          | 0x0200 | 512     |
| 8   | AFTER_REMOVE_LIQUIDITY           | 0x0100 | 256     |
| 7   | BEFORE_SWAP                      | 0x0080 | 128     |
| 6   | AFTER_SWAP                       | 0x0040 | 64      |
| 5   | BEFORE_DONATE                    | 0x0020 | 32      |
| 4   | AFTER_DONATE                     | 0x0010 | 16      |
| 3   | BEFORE_SWAP_RETURNS_DELTA        | 0x0008 | 8       |
| 2   | AFTER_SWAP_RETURNS_DELTA         | 0x0004 | 4       |
| 1   | AFTER_ADD_LIQUIDITY_RETURNS_DELTA| 0x0002 | 2       |
| 0   | AFTER_REMOVE_LIQ_RETURNS_DELTA   | 0x0001 | 1       |

### RatchetHook Requirements

RatchetHook needs two permissions:

1. **AFTER_SWAP (bit 6)** = 0x0040
   - Intercepts swaps to detect token buys
   - Triggers reactive selling from the vault

2. **AFTER_SWAP_RETURNS_DELTA (bit 2)** = 0x0004
   - Allows the hook to modify the swap output
   - Returns additional tokens from vault to buyer

**Combined flags: 0x0044 (decimal 68)**

Valid RatchetHook addresses must end in `...0044`, `...1044`, `...2044`, etc.
(any address where bits 6 and 2 are set, and other flag bits match the hook's
actual permissions)

## Why This Design?

### 1. Gas Efficiency
The PoolManager doesn't need to read storage to check permissions. A single
bitwise AND operation on the address reveals all capabilities.

### 2. Immutability
Once deployed, a hook's permissions cannot change. The address is fixed.

### 3. Transparency
Anyone can verify a hook's capabilities just by looking at its address.

### 4. Security
Hooks cannot lie about their capabilities. If a hook claims to implement
`afterSwap` but its address doesn't have bit 6 set, the PoolManager won't
call it.

## Address Mining Process

Since regular `CREATE` doesn't allow choosing addresses, we use `CREATE2`:

```solidity
address = keccak256(0xFF ++ deployer ++ salt ++ keccak256(bytecode))[12:]
```

By iterating through different salt values, we find one that produces an
address with the required permission bits.

### Mining Algorithm

```solidity
function find(address deployer, uint160 flags, bytes memory bytecode)
    returns (address hookAddress, bytes32 salt)
{
    for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
        bytes32 salt = bytes32(i);
        address addr = computeCreate2Address(deployer, salt, bytecode);

        // Check if the address has the correct flags
        if (uint160(addr) & FLAG_MASK == flags) {
            return (addr, salt);
        }
    }
    revert("Could not find valid salt");
}
```

### Deployment Steps

1. **Calculate required flags** from the hook's `getHookPermissions()`
2. **Mine a salt** that produces a valid address
3. **Deploy via CREATE2** using the deterministic deployer
4. **Validate** the deployed address matches expectations

## Deterministic CREATE2 Deployer

We use the standard deterministic deployment proxy at:
```
0x4e59b44847b379578588920cA78FbF26c0B4956C
```

This contract is deployed at the same address on most EVM chains, enabling
consistent deployments across networks.

To deploy via this proxy, send a transaction with:
- **to**: `0x4e59b44847b379578588920cA78FbF26c0B4956C`
- **data**: `salt (32 bytes) ++ creationCode`

## Ratchet Deployment

Run the deployment script:

```bash
# Set environment variables
export PRIVATE_KEY=your_private_key
export TESTNET=true  # or false for mainnet

# Deploy
forge script script/DeployRatchetHook.s.sol \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify
```

The script will:
1. Calculate the factory's future address (needed for hook constructor)
2. Mine a valid hook address with flags 0x0044
3. Deploy the hook via CREATE2
4. Deploy the factory with the pre-deployed hook

## Verification

After deployment, verify the hook address:

```solidity
// Check that address has correct flags
uint160 flags = uint160(hookAddress) & 0x3FFF;
require(flags == 0x0044, "Invalid hook flags");

// Verify hook recognizes factory
require(hook.FACTORY() == factory, "Factory mismatch");
```

## Common Issues

### "HookMiner: could not find salt"
The miner has a maximum iteration limit. Try:
- Changing constructor arguments
- Using a different deployer address
- Increasing MAX_LOOP in HookMiner

### "HookAddressNotValid"
The hook was deployed at an address without correct permission flags.
This usually means CREATE was used instead of CREATE2 with the mined salt.

### "Hook not called"
The PoolManager checks the hook address before calling. If the address
doesn't have the required bit set, the callback is silently skipped.

## References

- [Uniswap v4 Hooks Documentation](https://docs.uniswap.org/contracts/v4/concepts/hooks)
- [HookMiner.sol](../lib/v4-periphery/src/utils/HookMiner.sol)
- [Hooks.sol](../lib/v4-core/src/libraries/Hooks.sol)
- [CREATE2 Deployer](https://github.com/Arachnid/deterministic-deployment-proxy)
