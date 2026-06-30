# Private DoppiCore Architecture

## Overview

The private DoppiCore system enables each trader bot to have its own isolated trading core with dedicated:
- **DoppiCore** - Private trading engine (proxy)
- **DoppiOpportunity** - Private opportunity storage (proxy)
- **DoppiLiquidity** - Private liquidity pool (new instance)
- **DoppiLiquidityRouter** - Private liquidity router (new instance)

This architecture preserves the existing shared pool while enabling truly private trading environments.

## Architecture Diagram

```
Shared (Unchanged in mainnet/):
├─ DoppiCore (direct deployment)
├─ DoppiOffer (global)
├─ DoppiPoints (global)
└─ DoppiReferral (global)

Per Trader Bot (Private Instances):
├─ DoppiCore proxy (via Clones.clone)
├─ DoppiOpportunity proxy (via Clones.clone)
├─ DoppiLiquidity instance
├─ DoppiLiquidityRouter instance
└─ DoppiTrader proxy (references private core)
```

## Key Design Decisions

### 1. **Proxy Pattern for Cores**
- One implementation contract, multiple proxy instances
- Each proxy has isolated storage
- Reduced bytecode size and deployment costs
- Clean upgrade path for core logic

### 2. **Separate DoppiOpportunity Contract**
- Previously: Opportunity orders stored in DoppiCoreView
- Now: External contract per private core
- Benefits:
  - Prevents opportunity data mixing
  - Allows independent opportunity management
  - Can be upgraded separately
  - Shared core still uses local storage for backward compat

### 3. **LP and Router Deployment**
- Each private bot gets brand new instances of:
  - `DoppiLiquidity` - Private liquidity pool
  - `DoppiLiquidityRouter` - Private router for deposits/redemptions
- Factory accepts `ConfigParam` with LP configuration
- All bots share same config (can be updated via factory)
- Complete isolation: No cross-bot liquidity sharing

### 4. **Initialization Pattern**
```solidity
// Shared core (direct deployment):
new DoppiCore(_assetA, _assetB, _doppiLP, _doppiOffer, _doppiPoints)

// Private core (proxy deployment):
address coreProxy = Clones.clone(doppiCoreImplementation);
IDoppiCore(coreProxy).initialize(
    _assetA, _assetB, _doppiLP, _doppiOffer, _doppiPoints, 
    _owner, _doppiOpportunity
);

// Private LP (new instance per bot):
DoppiLiquidity privateLiquidity = new DoppiLiquidity(
    "Private-LP-Symbol",
    "PRIV-LP",
    assetA,
    assetB
);
privateLiquidity.setDoppiCore(address(privateCore));
privateLiquidity.setConfig(lpConfig);

// Private Router (new instance per bot):
DoppiLiquidityRouter privateRouter = new DoppiLiquidityRouter(
    assetA, assetB, privateLiquidity
);
privateRouter.setDoppiCore(address(privateCore));
```

## File Structure

### New Files Created
```
src/mainnet/private/
├─ PrivateDoppiTraderFactory.sol     # Factory for deploying private bots
└─ README.md                         # This file

Note: private deployments now use cloneable `DoppiOpportunity` as a combined
upkeep executor and opportunity storage backend per private bot.
```

### Modified Files (mainnet/)
- `DoppiCore.sol` - Added proxy initialization
- `DoppiCoreView.sol` - Added opportunity delegation
- `DoppiCoreAdmin.sol` - No changes (inherited)
- `DoppiCoreTypes.sol` - No changes (inherited)
- `DoppiTrader.sol` - Parameter rename for clarity
- `DoppiTraderFactory.sol` - Added implementation refs

### New Interfaces (src/Interface/)
- `IDoppiOpportunity.sol` - External opportunity contract interface

## Implementation Details

### DoppiCore Changes

1. **Initializable Inheritance**
   ```solidity
   import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
   
   contract DoppiCore is Initializable, DoppiCoreView, DoppiCoreAdmin {
   ```

2. **Removed Immutables**
   - `assetA`, `assetB`, `doppiOffer`, `doppiPoints` - Now regular state vars
   - Allows initialization via proxy pattern

3. **Constructor (Still for Shared Core)**
   ```solidity
   constructor(
       IERC20 _assetA,
       IERC20 _assetB,
       address _doppiLP,
       address _doppiOffer,
       address _doppiPoints
   ) {
       // Calls _initializeDoppiCore internally
   }
   ```

4. **Initialize Function (For Proxies)**
   ```solidity
   function initialize(
       address _assetA,
       address _assetB,
       address _doppiLP,
       address _doppiOffer,
       address _doppiPoints,
       address owner,
       address _doppiOpportunity
   ) public initializer {
       // Same logic as constructor
   }
   ```

### DoppiCoreView Changes

1. **Opportunity Delegation**
   ```solidity
   function getOpportunityOrders(uint256 strikePrice)
       external
       view
       returns (OpportunityOrders memory)
   {
       if (address(doppiOpportunity) != address(0)) {
           // Delegate to external opportunity contract
           return doppiOpportunity.getOpportunityOrders(strikePrice);
       }
       // Otherwise use local storage (shared core)
       return opportunityBuy[strikePrice];
   }
   ```

### DoppiOpportunity (New Contract)

Stores opportunity orders in external contract:
- Per-core opportunity data isolation
- Reduces shared core state pressure
- Can be managed independently

```solidity
contract DoppiOpportunity is Initializable {
    IDoppiCore public doppiCore;
    mapping(uint256 => OpportunityOrders) public opportunityBuy;
    mapping(uint256 => OpportunityOrders) public opportunitySell;
    
    function initialize(address _doppiCore) public initializer {
        doppiCore = IDoppiCore(_doppiCore);
    }
    
    // ... getter/setter functions
}
```

### PrivateDoppiTraderFactory

Deploys complete private trading environment with all components:

```solidity
function deployPrivateBot(
    uint24[] calldata _weights,
    string calldata _lpName,
    string calldata _lpSymbol
) external returns (uint32) {
    // 1. Deploy new DoppiLiquidity instance
    DoppiLiquidity privateLiquidity = new DoppiLiquidity(
        _lpName, _lpSymbol, assetA, assetB
    );
    
    // 2. Deploy new DoppiLiquidityRouter instance
    DoppiLiquidityRouter privateRouter = new DoppiLiquidityRouter(
        assetA, assetB, privateLiquidity
    );
    
    // 3-8. Configure LP and Router
    privateLiquidity.setConfig(lpConfig);
    privateLiquidity.setDoppiLiquidityRouter(address(privateRouter));
    privateRouter.setDoppiCore(address(privateCore)); // After core created
    
    // 9-14. Deploy and initialize core proxies
    address privateOpportunity = Clones.clone(doppiOpportunityImplementation);
    address privateCore = Clones.clone(doppiCoreImplementation);
    
    // 15. Deploy and initialize bot
    address privateBot = Clones.clone(traderBotImplementation);
    DoppiTrader(privateBot).initialize(...);
    
    // 16. Return bot ID
    return botRegistry.deployBot(msg.sender, privateBot);
}
```

## Deployment Flow

### Shared Infrastructure (Deployed Once)
```
Mainnet Deployment Setup:
├─ DoppiCore (direct deployment, shared by all)
├─ DoppiOffer (global)
├─ DoppiPoints (global)
├─ DoppiReferral (global)
├─ DoppiTraderFactory (for shared bots)
└─ PrivateDoppiTraderFactory (gateway for private bots)
    ├─ Stores: doppiCoreImplementation
    ├─ Stores: doppiTraderImplementation
    ├─ Stores: doppiOpportunityImplementation
    └─ Stores: lpConfig
```

### Single Bot Deployment (One Function Call)
```
PrivateDoppiTraderFactory.deployPrivateBot(weights, lpName, lpSymbol)
    ↓
    Step 1-2: Deploy new LP instances
    ├─ new DoppiLiquidity()
    └─ new DoppiLiquidityRouter()
    ↓
    Step 3-8: Configure LP & Router
    ├─ setConfig(), setRouter(), setEntryPoint()
    └─ Router.setDoppiCore()
    ↓
    Step 9-10: Deploy core proxies
    ├─ Clones.clone(opportunityImplementation)
    └─ Clones.clone(coreImplementation)
    ↓
    Step 11-12: Initialize cores
    ├─ Opportunity.initialize(core)
    └─ Core.initialize(assetA, assetB, LP, offer, points, owner, opportunity)
    ↓
    Step 13: Deploy TraderBot proxy
    └─ Clones.clone(traderBotImplementation)
    ↓
    Step 14: Initialize TraderBot
    └─ TraderBot.initialize(trader, assets, LP, router, core, upkeep, weights)
    ↓
    Step 15: Store mappings & emit event
    └─ Returns botId
```

## Backward Compatibility

✅ **Preserved**
- Shared DoppiCore deployment unchanged
- All existing tests continue to work
- Shared pool remains isolated from private pools
- Local opportunity storage still works for shared core

❌ **Breaking Changes**
- None for existing deployments
- New contracts require Foundry 0.8.26+
- New factory must be deployed separately

## Testing Strategy

1. **Existing Tests** - All run unchanged on shared core
2. **New Tests** - Validate private core:
   - Proxy creation and initialization
   - Opportunity isolation
   - Private bot trading
   - Factory deployment flow

## TODO / Known Limitations

- [ ] Write integration tests for private bot deployment
- [ ] Document gas costs comparison (shared vs private)
- [ ] Consider LP configuration optimization per bot

## Migration Guide (For End Users)

### Using Shared Pool (Unchanged)
```solidity
// Same as before
IPrivateDoppiTraderFactory factory = ...;
uint32 botId = factory.deployTraderBot(weights);
```

### Using Private Pool (New)
```solidity
// New factory for private deployment
PrivateDoppiTraderFactory privateFactory = ...;
uint32 botId = privateFactory.deployPrivateBot(weights);

// Bot now has isolated core, opportunity, LP, and router
address core = privateFactory.getPrivateCore(bot);
address opportunity = privateFactory.getPrivateOpportunity(bot);
```

## Code Examples

### Deploy Private Bot
```solidity
PrivateDoppiTraderFactory factory = PrivateDoppiTraderFactory(...);

// Prepare order weights
uint24[] memory weights = new uint24[](5);
weights[0] = 2000;  // 20%
weights[1] = 2000;  // 20%
weights[2] = 2000;  // 20%
weights[3] = 2000;  // 20%
weights[4] = 2000;  // 20%

// Deploy bot (caller becomes trader)
uint32 botId = factory.deployPrivateBot(
    weights,
    "DoppiBot-LP",      // LP token name
    "DBL"               // LP token symbol
);

// Returns botId for tracking
```

### Access Private Components
```solidity
PrivateDoppiTraderFactory factory = PrivateDoppiTraderFactory(...);
address bot = ...; // from deployPrivateBot

// Get all private components
address privateCore = factory.getPrivateCore(bot);
address privateOpportunity = factory.getPrivateOpportunity(bot);
address privateLiquidity = factory.getPrivateLiquidity(bot);
address privateRouter = factory.getPrivateRouter(bot);

// Verify which core is private
IDoppiCore core = IDoppiCore(privateCore);
if (address(core.doppiOpportunity()) != address(0)) {
    // This is a private core with external opportunity storage
}
```

## Security Considerations

1. **Proxy Security**
   - Uses battle-tested OpenZeppelin Clones
   - No delegatecall risks (clone creates new contracts)
   - Initializer prevents replay attacks

2. **Isolation**
   - Each core has isolated state
   - Opportunity mixing impossible
   - LP funds completely separate

3. **Access Control**
   - Cores initialized with owner
   - Only owner can perform privileged ops
   - Factory controls deployment

## Performance Notes

- Private cores scale independently of shared core
- Each core has own storage (no contention)
- Clones reduce gas vs new deployments
- Initialization happens once per deployment

## References

- OpenZeppelin Clones: https://docs.openzeppelin.com/contracts/4.x/api/proxy#Clones
- OpenZeppelin Initializable: https://docs.openzeppelin.com/contracts/4.x/api/proxy#Initializable
- EIP-1167 Minimal Proxy: https://eips.ethereum.org/EIPS/eip-1167
