# Isolated per-bot trading contracts

The contracts in this directory provide isolated bot instances alongside the
shared contracts in the parent directory. "Private" describes trading-instance
isolation, not source confidentiality.

## Components

- [DoppiSimpleTrader](DoppiSimpleTrader.sol) and
  [PrivateDoppiSimpleTraderFactory](PrivateDoppiSimpleTraderFactory.sol):
  simple trader implementation and its factory.
- [DoppiGridTrader](DoppiGridTrader.sol) and
  [PrivateDoppiGridTraderFactory](PrivateDoppiGridTraderFactory.sol):
  grid trader implementation and its factory.
- [PrivateAutomationHub](PrivateAutomationHub.sol) and
  [PrivateAutomationHubTypes](PrivateAutomationHubTypes.sol):
  automation coordination and shared types.

Factories initialize bot instances using the shared protocol components.
Refer to the actual factory constructors and initialization methods for their
current configuration; no deployment script is provided in this distribution.

## Tests

The public unit suites are `test/PrivateDoppiSimpleTrader.t.sol`,
`test/PrivateDoppiGridTrader.t.sol`, and `test/PrivateAutomationHub.t.sol`.
Run them with `forge test` from the repository root. They use local fixtures,
not live-network credentials.
