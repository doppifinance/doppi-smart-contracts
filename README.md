# Doppi Contracts

Solidity contracts for Doppi's trading, liquidity, pricing, referral, and
automation components. This repository is the public source distribution;
internal deployment scripts and live-network/scenario tests are not included.

## Layout

| Directory | Contents |
| --- | --- |
| `src/mainnet` | Production contracts |
| `src/mainnet/private` | Per-bot isolated trading contracts and factories |
| `src/Interface` | Contract interfaces |
| `src/Library` | Shared Solidity libraries |
| `src/test` | Mocks and test fixtures, not production deployments |
| `test` | Local unit tests and their helper contracts |
| `lib` | Vendored dependencies, including their license notices |

Here, "private" means isolated bot instances; it does not mean confidential
source or a separate access-controlled repository.
`src/Library/TestParamLib_BSC.sol` contains BSC-specific test configuration.
The internal localhost registry fixture is not distributed.

## Prerequisites and setup

Install [Foundry](https://getfoundry.sh/) **v1.7.1** and Git. Solidity **0.8.26**
is selected by the configuration and downloaded automatically if necessary.
The normal build uses viaIR and 200 optimizer runs.

```sh
git clone https://github.com/doppifinance/doppi-smart-contract.git
cd doppi-smart-contract
forge --version
forge build
```

Dependencies are already vendored. No `forge install`, submodule initialization,
`.env` file, RPC URL, or signing key is needed. Initial toolchain/compiler
downloads require internet access.

On Windows, add `%USERPROFILE%\.foundry\bin` to PATH or invoke
`& "$env:USERPROFILE\.foundry\bin\forge.exe"` in PowerShell.

## Local development commands

```sh
forge build
forge test
forge fmt --check
forge snapshot
forge snapshot --check
```

Build contract sizes
```sh
forge build --sizes 2>/dev/null
```

## Licensing and dependencies

See [DEPENDENCIES.md](DEPENDENCIES.md) for vendored versions and upstream links.
File-level SPDX identifiers and bundled dependency licenses are preserved.
Sources have mixed license identifiers, including `UNLICENSED`; there is no
blanket MIT license or grant covering the entire repository. Public visibility
alone does not grant unrestricted reuse rights.
