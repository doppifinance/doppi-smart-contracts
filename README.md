## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Script

```shell
$ forge script script/DA.s.sol
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

## Local Development Setup

### 1. Start Local Blockchain with Anvil

Start a local Ethereum node with Anvil:

```shell
anvil
```

This will start a local blockchain at `http://127.0.0.1:8545` with 10 pre-funded accounts. Note the private keys shown in the output.

### 2. Set Environment Variables

Set your private key in .env file:

```shell
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### 3. Deploy BlackScholes and ImpliedVol Contracts

Deploy the core contracts to your local blockchain:

```shell
forge script script/local/DeployBlackScholesAndImpliedVol.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

This will deploy both BlackScholes and ImpliedVol contracts and output their addresses.

### 4. Set Regression Parameters for ImpliedVol

Set the ImpliedVol contract address from the deployment output:

```shell
export IMPLIED_VOL_ADDRESS=<deployed_implied_vol_address>
```

Then run the regression setup script:

```shell
forge script script/local/SetImpliedVolRegression.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

```shell
forge build --sizes 2>/dev/null
```

This will configure the regression parameters for the ImpliedVol contract.
