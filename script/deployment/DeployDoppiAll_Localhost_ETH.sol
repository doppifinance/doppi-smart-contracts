// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/Interface/IAutomationRegistrar.sol";
import "../../src/Interface/IAutomationRegistryConsumer.sol";
import {IBlackScholes} from "../../src/Interface/IBlackScholes.sol";
import {DoppiTraderFactory} from "../../src/mainnet/DoppiTraderFactory.sol";
import {DoppiTrader} from "../../src/mainnet/DoppiTrader.sol";
import {DoppiCore} from "../../src/mainnet/DoppiCore.sol";
import {DoppiLiquidity} from "../../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter} from "../../src/mainnet/DoppiLiquidityRouter.sol";
import {BlackScholes} from "../../src/mainnet/BlackScholes.sol";
import {DoppiOffer} from "../../src/mainnet/DoppiOffer.sol";
import {DoppiPoints} from "../../src/mainnet/DoppiPoints.sol";
import {DoppiClaim} from "../../src/mainnet/DoppiClaim.sol";
import {DOPPI} from "../../src/test/Doppi.sol";
import {DoppiOpportunity} from "../../src/mainnet/DoppiOpportunity.sol";
// import {DoppiUpkeepManager} from "../../src/mainnet/DoppiUpkeepManager.sol";
import {MockRegistryConsumer} from "../../src/test/MockRegistryConsumerLocalhost.sol";
import {DoppiReferral} from "../../src/mainnet/DoppiReferral.sol";
import {PrivateDoppiTraderFactory} from "../../src/mainnet/private/PrivateDoppiTraderFactory.sol";
import {PrivateDoppiGridTraderFactory} from "../../src/mainnet/private/PrivateDoppiGridTraderFactory.sol";
import {PrivateDoppiSimpleTraderFactory} from "../../src/mainnet/private/PrivateDoppiSimpleTraderFactory.sol";
import {PrivateAutomationHub} from "../../src/mainnet/private/PrivateAutomationHub.sol";
import {DoppiGridTrader} from "../../src/mainnet/private/DoppiGridTrader.sol";
import {DoppiSimpleTrader} from "../../src/mainnet/private/DoppiSimpleTrader.sol";
import {DoppiFeePool} from "../../src/mainnet/DoppiFeePool.sol";
import "../../src/mainnet/DoppiLiquidityTypes.sol";
import {TestParamLib} from "../../src/Library/TestParamLib.sol";
import {MockOracle} from "../../src/test/MockOracle.sol";
import {MockSwapper} from "../../src/test/MockSwapper.sol";

contract DeployDoppiAll is Script {
    
    uint256 minOrderA = 50 ether;
    uint256 minOrderB = 0.02 ether;
    uint256 botVolumeMultiplier = 1000;
    uint256 botVolumeMultiplierDen = 10000;
    uint16 privateTreasuryFeeBps = 2000;
    uint16 privateFeeToSharedLPBps = 3000;

    address constant BlackS = address(0x82Fd820354f1261c87D575F8d04DeD2731ddEB7B); 
    address constant DoppiRef = address(0x43426C66c0082A5c4F93DFbAAc39B3713DD7aC33);
    address constant DoppiCl = address(0xf5ca7286B033a8B301d18F3F0e3bc514398a82B5);
    address constant DoppiTk = address(0xa85490FeeAa833f8430238A38C33359888deCFa1);
    address constant DoppiPts = address(0xdbA966C8E4da8bff85E700828bbF6b80C409a68F);
    address constant DoppiPrivateHub = address(0x698b7Ef8995c9f4291Ef998e13019F25ED165Dde);
    address constant DoppiFeePoolAddress = address(0x1d63ea45D93135a424DFE975aE41142245AA6532);
    

    address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
    address constant BTC = address(0x2170Ed0880ac9A755fd29B2688956BD959F933F8); // ETH
    address constant CHAINLINK_BNB_USD = address(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE);
    address constant CHAINLINK_BTC_USD = address(0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e); // ETH
    address constant PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    address constant PCSWAP_V3Pool = address(0xBe141893E4c6AD9272e8C04BAB7E6a10604501a5); // ETH USDT Pool
    address constant treasury = address(0x7E8c87Feb8D30706ca43A8049ee654875426A721);
    address constant admin = address(0x6Abb788569C3658b4C4798dEb914e6151D7aFc1C);
    address constant forwarder = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    ConfigParam configLP;
    MockOracle oracle;
    MockSwapper mockSwapper;

    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        configLP = TestParamLib.get_configLP_ETH();
        
        mockSwapper = _deployMockSwapper();
        configLP.router = address(mockSwapper);
        
        BlackScholes blackScholes = _deployBlackScholes(); // Use existing
        DoppiOffer impliedVol = _deployDoppiOffer(address(blackScholes));
        DoppiPoints doppiPoints = _deployDoppiPoints(); // Use existing
        DoppiLiquidity doppiLP = _deployDoppiLiquidity();
        DoppiCore doppiCore = _deployDoppiCore(doppiLP, impliedVol, doppiPoints);
        DoppiOpportunity doppiOpportunity = _deployDoppiOpportunity(address(doppiCore), address(doppiLP));
        DoppiReferral doppiReferral = _deployDoppiReferral(); // Use existing 
    
        console.log("Deploying DoppiLiquidityRouter...");
        DoppiLiquidityRouter doppiRouter = new DoppiLiquidityRouter(IERC20(USDT), IERC20(BTC), doppiLP);
        doppiRouter.setDoppiCore(address(doppiCore));
        doppiLP.setDoppiLiquidityRouter(address(doppiRouter));
        console.log("DoppiLiquidityRouter deployed at:", address(doppiRouter));
        
        console.log("Deploying DoppiTraderFactory...");
        DoppiTraderFactory doppiFactory = new DoppiTraderFactory(IERC20(USDT), IERC20(BTC), address(doppiCore), address(doppiLP), address(doppiRouter), address(impliedVol), address(doppiPoints));
        console.log("DoppiTraderFactory deployed at:", address(doppiFactory));
        
        DoppiClaim doppiClaim = _deployDoppiClaim(); // Use existing
        
        _setDoppiLiquidityProperties(doppiLP, address(doppiCore), doppiRouter, address(doppiFactory));

        _setDoppiCoreProperties(doppiCore, doppiFactory, address(doppiOpportunity));

        doppiPoints.setCoreTraderFactory(address(doppiCore), address(doppiFactory));

        // // Deploy private factory implementations
        DoppiCore privateCoreImpl = new DoppiCore(USDT, BTC, doppiLP, impliedVol, address(doppiPoints));
        DoppiTrader privateTraderImpl = new DoppiTrader();
        DoppiOpportunity privateOpportunityImpl = new DoppiOpportunity(address(0), address(0));

        
        DoppiGridTrader privateGridTraderImpl = new DoppiGridTrader();
        PrivateDoppiGridTraderFactory privateGridFactory = new PrivateDoppiGridTraderFactory(
            IERC20(USDT),
            IERC20(BTC),
            address(doppiLP),
            address(impliedVol),
            address(doppiPoints),
            address(privateGridTraderImpl)
        );
        console.log("PrivateDoppiGridTraderFactory deployed at:", address(privateGridFactory));
        doppiLP.setDoppiTraderFactory(address(privateGridFactory));

        DoppiSimpleTrader privateSimpleTraderImpl = new DoppiSimpleTrader();
        PrivateDoppiSimpleTraderFactory privateSimpleFactory = new PrivateDoppiSimpleTraderFactory(
            IERC20(USDT),
            IERC20(BTC),
            address(doppiLP),
            address(impliedVol),
            address(doppiPoints),
            address(privateSimpleTraderImpl)
        );
        console.log("PrivateDoppiSimpleTraderFactory deployed at:", address(privateSimpleFactory));
        doppiLP.setDoppiTraderFactory(address(privateSimpleFactory));
        

        // Deploy private factory
        PrivateDoppiTraderFactory privateFactory = new PrivateDoppiTraderFactory(
            IERC20(USDT),
            IERC20(BTC),
            address(impliedVol),
            address(doppiPoints),
            address(doppiFactory),
            address(privateTraderImpl),
            address(privateCoreImpl),
            address(privateOpportunityImpl)
        );
        privateFactory.setLPConfig(configLP);


        // Deploy PrivateAutomationHub for private bot job scheduling and billing
        PrivateAutomationHub privateAutomationHub = _deployExistingDoppiHub();
        
        // new pool for ETH USDT pair
        DoppiFeePool doppiFeePool = new DoppiFeePool(
            address(doppiLP),
            treasury,
            privateFeeToSharedLPBps
        );

        doppiFeePool.setCoreAuthorizer(address(privateFactory));
        privateFactory.setDefaultPrivateTreasury(address(doppiFeePool), privateTreasuryFeeBps);

        doppiFeePool.setCoreAuthorizer(address(privateGridFactory));
        privateGridFactory.setDefaultPrivateTreasury(address(doppiFeePool), privateTreasuryFeeBps);

        doppiFeePool.setCoreAuthorizer(address(privateSimpleFactory));
        privateSimpleFactory.setDefaultPrivateTreasury(address(doppiFeePool), privateTreasuryFeeBps);

        // Wire hub to both shared and private factories for auto job registration.
        doppiFactory.setPrivateAutomationHub(address(privateAutomationHub));
        privateFactory.setPrivateAutomationHub(address(privateAutomationHub));
        privateGridFactory.setPrivateAutomationHub(address(privateAutomationHub));
        privateSimpleFactory.setPrivateAutomationHub(address(privateAutomationHub));

        // Register both factories + deployer as registrars in the hub.
        privateAutomationHub.setRegistrar(address(doppiFactory), true);
        privateAutomationHub.setRegistrar(address(privateFactory), true);
        privateAutomationHub.setRegistrar(address(privateGridFactory), true);
        privateAutomationHub.setRegistrar(address(privateSimpleFactory), true);

        doppiPoints.setCoreRegistrar(address(privateFactory), true);
        doppiPoints.setCoreRegistrar(address(privateGridFactory), true);
        doppiPoints.setCoreRegistrar(address(privateSimpleFactory), true);


        oracle = new MockOracle(int256(1920 * 1e8), 8);

        doppiLP.setForwarderAddress(forwarder);
        
        vm.stopBroadcast();

        // Log deployment addresses for easy access
        console.log("\n=== Deployment Summary ===");
        console.log("BlackScholes:", address(blackScholes));
        console.log("DoppiOffer:", address(impliedVol));
        console.log("DoppiPoints:", address(doppiPoints));
        console.log("DoppiLiquidity:", address(doppiLP));
        console.log("DoppiCore:", address(doppiCore));
        console.log("DoppiOpportunity:", address(doppiOpportunity));
        console.log("DoppiLiquidityRouter:", address(doppiRouter));
        console.log("DoppiTraderFactory:", address(doppiFactory));
        console.log("DoppiReferral:", address(doppiReferral));
        console.log("DoppiClaim:", address(doppiClaim));
        console.log("PrivateDoppiFactory:", address(privateFactory));
        console.log("PrivateAutomationHub:", address(privateAutomationHub));
        console.log("DoppiFeePool:", address(doppiFeePool));
        console.log("PrivateGridFactory:", address(privateGridFactory));
        console.log("PrivateSimpleFactory:", address(privateSimpleFactory));
        console.log("PrivateCoreImpl:", address(privateCoreImpl));
        console.log("PrivateTraderImpl:", address(privateTraderImpl));
        console.log("PrivateOpportunityImpl:", address(privateOpportunityImpl));
        console.log("PrivateGridTraderImpl:", address(privateGridTraderImpl));
        console.log("PrivateSimpleTraderImpl:", address(privateSimpleTraderImpl));
        console.log("MockOracle:", address(oracle));
        console.log("MockSwapper:", address(mockSwapper));

    }

    function _deployMockSwapper() internal returns (MockSwapper) {
        console.log("Deploying MockSwapper...");
        MockSwapper deployedMockSwapper = new MockSwapper(USDT, BTC);
        console.log("MockSwapper deployed at:", address(deployedMockSwapper));
        return deployedMockSwapper;
    }

    function _setDoppiCoreProperties(
        DoppiCore _doppiCore, 
        DoppiTraderFactory _doppiFactory,
        address _doppiOpportunity
        ) internal {
        
        console.log("Setting DoppiCore Properties...");
        _doppiCore.setForwarderAddress(forwarder);
        _doppiCore.setOpportunityBot(_doppiOpportunity, true);
        _doppiCore.setDoppiTraderFactory(_doppiFactory);
        _doppiCore.setAPRTolerance(1000);
        _doppiCore.setTreasury(treasury, 1500);
        _doppiCore.setUpkeeps_per_check(50);
        
    }

    function _setDoppiLiquidityProperties(
        DoppiLiquidity _doppiLP, 
        address _doppiCore, 
        DoppiLiquidityRouter _doppiRouter,
        address _doppiFactory
        ) internal {
        
        console.log("Setting DoppiLiquidity Properties...");
        _doppiLP.setDoppiCore(_doppiCore);
        _doppiLP.setEntryPoint(address(_doppiRouter.entryPointA()), true);
        _doppiLP.setEntryPoint(address(_doppiRouter.entryPointB()), true);
        _doppiLP.setDoppiTraderFactory(_doppiFactory);
        _doppiLP.lockEntryPoints();
    }

    function _deployDoppiCore(DoppiLiquidity _doppiLP, DoppiOffer _impliedVol, DoppiPoints _doppiPoints) internal returns (DoppiCore) {
        
        console.log("Deploying DoppiCore...");
        DoppiCore _doppiCore = new DoppiCore(USDT, BTC, _doppiLP, _impliedVol, address(_doppiPoints));
        console.log("DoppiCore deployed at:", address(_doppiCore));
        _doppiPoints.setDoppiCore(address(_doppiCore), true);
        _doppiCore.setMinOrder(minOrderA, minOrderB);
        return _doppiCore;
    }


    function _deployDoppiOpportunity(address _doppiCore, address _doppiLP) internal returns (DoppiOpportunity) {
    
        console.log("Deploying DoppiOpportunity...");
        DoppiOpportunity doppiOpportunity = new DoppiOpportunity(_doppiCore, _doppiLP);
        console.log("DoppiOpportunity deployed at:", address(doppiOpportunity));
        doppiOpportunity.setForwarderAddress(forwarder);
        return doppiOpportunity;
    }

    function _deployDoppiLiquidity() internal returns (DoppiLiquidity) {
        
        console.log("Deploying DoppiLiquidity...");
        DoppiLiquidity _doppiLP = new DoppiLiquidity("Doppi ETH-USDT LP", "ETH-USDT", address(IERC20(USDT)), address(IERC20(BTC)));
        console.log("DoppiLiquidity deployed at:", address(_doppiLP));
        _doppiLP.setConfig(configLP); 
        _doppiLP.approveRouter();
        return _doppiLP;
    }

    function _deployBlackScholes() internal returns (BlackScholes) {
        
        console.log("Initiating Existing BlackScholes...");
        BlackScholes blackScholes = BlackScholes(BlackS);
        return blackScholes;
    
    }

    function _deployExistingDoppiHub() internal returns (PrivateAutomationHub) {
        console.log("Initiating Existing PrivateAutomationHub...");
        PrivateAutomationHub hub = PrivateAutomationHub(DoppiPrivateHub);
        return hub;
    }

    function _deployDoppiClaim() internal returns (DoppiClaim) {
        console.log("Initiating Existing DoppiClaim...");
        DoppiClaim doppiClaim = DoppiClaim(DoppiCl);
        return doppiClaim;
    }

    function _deployDoppiReferral() internal returns (DoppiReferral) {
        
        console.log("Initiating Existing DoppiReferral...");
        DoppiReferral doppiReferral = DoppiReferral(DoppiRef);
        return doppiReferral;
    }

    function _deployDoppiOffer(address _blackScholes) internal returns (DoppiOffer) {
        
        console.log("Deploying DoppiOffer...");
        DoppiOffer impliedVol = new DoppiOffer(IBlackScholes(_blackScholes), CHAINLINK_BTC_USD, 25);
        console.log("DoppiOffer deployed at:", address(impliedVol));
        impliedVol.setTwapDuration(3600);
        impliedVol.setPancakeV3Pool(PCSWAP_V3Pool);
        impliedVol.setMaxOfferAPR(40000); // 400% max APR
        return impliedVol;
    }

    function _deployDoppiPoints() internal returns (DoppiPoints) {

        console.log("Initiating Existing DoppiPoints...");        
        DoppiPoints doppiPoints = DoppiPoints(DoppiPts);
        doppiPoints.setBotVolumeMultiplier(botVolumeMultiplier, botVolumeMultiplierDen);
        return doppiPoints;

    }

    // function _deployDoppiUpkeepManager(DoppiTraderFactory _doppiFactory) internal returns (DoppiUpkeepManager) {

    //     console.log("Deploying DoppiUpkeepManager...");
    //     IAutomationRegistrar registrar = IAutomationRegistrar(CHAINLINK_Registrar);
    //     // IAutomationRegistryConsumer registryConsumer = IAutomationRegistryConsumer(CHAINLINK_RegistryConsumer);
    //     MockRegistryConsumer registryConsumer = new MockRegistryConsumer();

    //     DoppiUpkeepManager doppiUpkeepManager = new DoppiUpkeepManager(
    //         address(registryConsumer), 
    //         address(registrar), 
    //         CHAINLINK_LINK_USD, 
    //         address(PCSWAP_V3_ROUTER),
    //         LINK_PEGGED_SWAP,
    //         USDT, 
    //         LINK, // erc677 link
    //         BNBLINK, //bnb link
    //         address(_doppiFactory),
    //         treasury
    //     );
        
    //     console.log("mockRegistryConsumer deployed at:", address(registryConsumer));
    //     console.log("DoppiUpkeepManager deployed at:", address(doppiUpkeepManager));
    //     doppiUpkeepManager.setMaxDelay(100 days);
    //     doppiUpkeepManager.setForwarderAddress(forwarder);
        
    //     // Note: setDoppiUpKeepManager is deprecated for shared bots
    //     // Shared bots no longer use doppiUpkeepManager (removed in favor of PrivateAutomationHub)
    //     // Use setPrivateAutomationHub() instead for shared bot billing in new deployments
    //     _doppiFactory.setDoppiUpKeepManager(address(doppiUpkeepManager));
    //     return doppiUpkeepManager;
    // }  

    function _defaultPrivateWeights() internal pure returns (uint24[] memory weights) {
        weights = new uint24[](5);
        weights[0] = 500;
        weights[1] = 1000;
        weights[2] = 1500;
        weights[3] = 2500;
        weights[4] = 4500;
    }
        

            
}
