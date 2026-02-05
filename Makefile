.PHONY: install build test clean deploy

install:
	forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts Uniswap/v4-core Uniswap/v4-periphery

build:
	forge build

test:
	forge test -vvv

test-gas:
	forge test --gas-report

coverage:
	forge coverage

clean:
	forge clean

deploy-testnet:
	TESTNET=true forge script script/Deploy.s.sol:DeployScript --rpc-url $(BASE_SEPOLIA_RPC_URL) --broadcast --verify

deploy-mainnet:
	TESTNET=false forge script script/Deploy.s.sol:DeployScript --rpc-url $(BASE_RPC_URL) --broadcast --verify

# Format
fmt:
	forge fmt

# Lint
lint:
	forge fmt --check
