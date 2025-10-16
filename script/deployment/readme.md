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

This will configure the regression parameters for the ImpliedVol contract.
