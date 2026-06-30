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
import {DoppiUpkeepManager} from "../../src/mainnet/DoppiUpkeepManager.sol";
import {MockRegistryConsumer} from "../../src/test/MockRegistryConsumerLocalhost.sol";
import {DoppiReferral} from "../../src/mainnet/DoppiReferral.sol";
import {PrivateDoppiTraderFactory} from "../../src/mainnet/private/PrivateDoppiTraderFactory.sol";
import {DoppiFeePool} from "../../src/mainnet/DoppiFeePool.sol";
import "../../src/mainnet/DoppiLiquidityTypes.sol";
import {TestParamLib} from "../../src/Library/TestParamLib.sol";

contract DeployDoppiAll is Script {
    
    uint256 minOrderA = 50 ether;
    uint256 minOrderB = 0.0005 ether;
    uint256 botVolumeMultiplier = 3;
    uint24 privateTreasuryFeeBps = 1000;
    uint16 privateFeeToSharedLPBps = 3000;

    address constant LINK = address(0x404460C6A5EdE2D891e8297795264fDe62ADBB75);
    address constant USDT = address(0x55d398326f99059fF775485246999027B3197955);
    address constant BTC = address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    address constant BNBLINK = address(0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD);
    address constant CHAINLINK_BTC_USD = address(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf);
    // address constant CHAINLINK_BTC_USD = address(0x8ECF7dE377F788A813F5215668E282556b35f300); // SVR
    address constant CHAINLINK_LINK_USD = address(0xca236E327F629f9Fc2c30A4E95775EbF0B89fac8);
    // address constant CHAINLINK_LINK_USD = address(0x933458F222023B7E9f0AB2194e30d7ACcfE3603D); // SVR
    address constant LINK_PEGGED_SWAP = address(0x1FCc3B22955e76Ca48bF025f1A6993685975Bb9e);
    address constant PCSWAP_V3_ROUTER = address(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    address constant PCSWAP_V3Pool = address(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);
    address constant CHAINLINK_RegistryConsumer = address(0xDc21E279934fF6721CaDfDD112DAfb3261f09A2C);
    address constant CHAINLINK_Registrar = address(0xf671F60bCC964B309D22424886FF202807381B32);
    address constant treasury = address(0x7E8c87Feb8D30706ca43A8049ee654875426A721);
    address constant admin = address(0x6Abb788569C3658b4C4798dEb914e6151D7aFc1C);
    address constant forwarder = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    ConfigParam configLP;

    function run() external {
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        configLP = TestParamLib.get_configLP_localhost();
        
        BlackScholes blackScholes = _deployBlackScholes();
        DoppiOffer impliedVol = _deployDoppiOffer(address(blackScholes));
        DoppiPoints doppiPoints = _deployDoppiPoints();
        DoppiLiquidity doppiLP = _deployDoppiLiquidity();
        DoppiCore doppiCore = _deployDoppiCore(doppiLP, impliedVol, doppiPoints);
        DoppiOpportunity doppiOpportunity = _deployDoppiOpportunity(address(doppiCore), address(doppiLP));
        DoppiReferral doppiReferral = _deployDoppiReferral(address(doppiPoints));
    
        console.log("Deploying DoppiLiquidityRouter...");
        DoppiLiquidityRouter doppiRouter = new DoppiLiquidityRouter(IERC20(USDT), IERC20(BTC), doppiLP);
        doppiRouter.setDoppiCore(address(doppiCore));
        doppiLP.setDoppiLiquidityRouter(address(doppiRouter));
        console.log("DoppiLiquidityRouter deployed at:", address(doppiRouter));
        
        console.log("Deploying DoppiTraderFactory...");
        DoppiTraderFactory doppiFactory = new DoppiTraderFactory(IERC20(USDT), IERC20(BTC), address(doppiCore), address(doppiLP), address(doppiRouter), address(impliedVol), address(doppiPoints));
        console.log("DoppiTraderFactory deployed at:", address(doppiFactory));
        
        DoppiUpkeepManager doppiUpkeepManager = _deployDoppiUpkeepManager(doppiFactory);
        
        DOPPI doppiToken = new DOPPI("Doppi Token", "DOPPI");
        DoppiClaim doppiClaim = _deployDoppiClaim(doppiPoints, doppiReferral, doppiToken);
        
        _setDoppiLiquidityProperties(doppiLP, address(doppiCore), doppiRouter, address(doppiFactory));

        _setDoppiCoreProperties(doppiCore, doppiFactory, address(doppiOpportunity));

        doppiPoints.setCoreTraderFactory(address(doppiCore), address(doppiFactory));

        // // Deploy private factory implementations
        DoppiCore privateCoreImpl = new DoppiCore(USDT, BTC, doppiLP, impliedVol, address(doppiPoints));
        DoppiTrader privateTraderImpl = new DoppiTrader();
        DoppiOpportunity privateOpportunityImpl = new DoppiOpportunity(address(0), address(0));

        // Deploy private factory
        PrivateDoppiTraderFactory privateFactory = new PrivateDoppiTraderFactory(
            IERC20(USDT),
            IERC20(BTC),
            address(impliedVol),
            address(doppiPoints),
            address(doppiUpkeepManager),
            address(doppiFactory),
            address(privateTraderImpl),
            address(privateCoreImpl),
            address(privateOpportunityImpl),
            configLP
        );

        DoppiFeePool doppiFeePool = new DoppiFeePool(
            address(doppiLP),
            treasury,
            privateFeeToSharedLPBps
        );
        doppiFeePool.setCoreAuthorizer(address(privateFactory));
        privateFactory.setDefaultPrivateTreasury(address(doppiFeePool), privateTreasuryFeeBps);

        doppiUpkeepManager.addTraderFactory(address(privateFactory));
        doppiPoints.setCoreRegistrar(address(privateFactory), true);

        // Deploy one initial private bot for the broadcasting EOA
        uint24[] memory privateWeights = _defaultPrivateWeights();
        uint32 privateBotId = privateFactory.deployPrivateBot(privateWeights);
        address privateBot = privateFactory.traderBots(privateBotId);
        privateFactory.setPrivateBotForwarder(privateBot, forwarder);
        address privateCore = privateFactory.getPrivateCore(privateBot);
        address privateOpportunity = privateFactory.getPrivateOpportunity(privateBot);
        address privateLP = privateFactory.getPrivateLiquidity(privateBot);
        address privateRouter = privateFactory.getPrivateRouter(privateBot);
        
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
        console.log("DoppiUpkeepManager:", address(doppiUpkeepManager));
        console.log("DoppiReferral:", address(doppiReferral));
        console.log("DoppiClaim:", address(doppiClaim));
        console.log("DoppiToken:", address(doppiToken));
        console.log("PrivateDoppiFactory:", address(privateFactory));
        console.log("DoppiFeePool:", address(doppiFeePool));
        console.log("PrivateFeeToSharedLPBps:", privateFeeToSharedLPBps);
        console.log("PrivateTreasuryFeeBps:", privateTreasuryFeeBps);
        console.log("PrivateCoreImpl:", address(privateCoreImpl));
        console.log("PrivateTraderImpl:", address(privateTraderImpl));
        console.log("PrivateOpportunityImpl:", address(privateOpportunityImpl));
        console.log("InitialPrivateBotId:", privateBotId);
        console.log("InitialPrivateBot:", privateBot);
        console.log("InitialPrivateCore:", privateCore);
        console.log("InitialPrivateOpportunity:", privateOpportunity);
        console.log("InitialPrivateLP:", privateLP);
        console.log("InitialPrivateRouter:", privateRouter);

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
        _doppiCore.setAPRTolerance(500);
        _doppiCore.setTreasury(treasury, 1000);
        _doppiCore.setUpkeeps_per_check(100);
        
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
        DoppiLiquidity _doppiLP = new DoppiLiquidity("Doppi BTC-USDT LP", "BTCB-USDT", address(IERC20(USDT)), address(IERC20(BTC)));
        console.log("DoppiLiquidity deployed at:", address(_doppiLP));
        _doppiLP.setConfig(configLP); 
        _doppiLP.approveRouter();
        return _doppiLP;
    }

    function _deployBlackScholes() internal returns (BlackScholes) {
        
        console.log("Deploying BlackScholes...");
        BlackScholes blackScholes = new BlackScholes();
        console.log("BlackScholes deployed at:", address(blackScholes));
        return blackScholes;
    }

    function _deployDoppiClaim(DoppiPoints _doppiPoints, DoppiReferral _doppiReferral, DOPPI _doppiToken) internal returns (DoppiClaim) {
        console.log("Deploying DoppiClaim...");
        DoppiClaim doppiClaim = new DoppiClaim(
            address(_doppiToken),
            address(_doppiPoints),
            address(_doppiReferral),
            1 // 1 token per point
        );
        _doppiPoints.setDoppiClaim(address(doppiClaim));
        _doppiReferral.setDoppiClaim(address(doppiClaim));
        _doppiToken.addMinter(address(doppiClaim));
        console.log("DoppiClaim deployed at:", address(doppiClaim));
        return doppiClaim;
    }

    function _deployDoppiReferral(address _doppiPoints) internal returns (DoppiReferral) {
        console.log("Deploying DoppiReferral...");
        DoppiReferral doppiReferral = new DoppiReferral(_doppiPoints, 150, 100, 50);
        console.log("DoppiReferral deployed at:", address(doppiReferral));
        doppiReferral.setMinVolumeForL2L3(1_000 ether, 2_000 ether);
        DoppiPoints(_doppiPoints).setDoppiReferral(address(doppiReferral));
        return doppiReferral;
    }

    function _deployDoppiOffer(address _blackScholes) internal returns (DoppiOffer) {
        
        console.log("Deploying DoppiOffer...");
        DoppiOffer impliedVol = new DoppiOffer(IBlackScholes(_blackScholes), CHAINLINK_BTC_USD, 500);
        console.log("DoppiOffer deployed at:", address(impliedVol));
        impliedVol.setTwapDuration(3600);
        impliedVol.setPancakeV3Pool(PCSWAP_V3Pool);
        impliedVol.setMaxOfferAPR(40000); // 400% max APR
        return impliedVol;
    }

    function _deployDoppiPoints() internal returns (DoppiPoints) {
        console.log("Deploying DoppiPoints...");
        DoppiPoints doppiPoints = new DoppiPoints();
        console.log("DoppiPoints deployed at:", address(doppiPoints));
        doppiPoints.setBotVolumeMultiplier(botVolumeMultiplier, 1);
        return doppiPoints;
    }

    function _deployDoppiUpkeepManager(DoppiTraderFactory _doppiFactory) internal returns (DoppiUpkeepManager) {

        console.log("Deploying DoppiUpkeepManager...");
        IAutomationRegistrar registrar = IAutomationRegistrar(CHAINLINK_Registrar);
        // IAutomationRegistryConsumer registryConsumer = IAutomationRegistryConsumer(CHAINLINK_RegistryConsumer);
        MockRegistryConsumer registryConsumer = new MockRegistryConsumer();

        DoppiUpkeepManager doppiUpkeepManager = new DoppiUpkeepManager(
            address(registryConsumer), 
            address(registrar), 
            CHAINLINK_LINK_USD, 
            address(PCSWAP_V3_ROUTER),
            LINK_PEGGED_SWAP,
            USDT, 
            LINK, // erc677 link
            BNBLINK, //bnb link
            address(_doppiFactory),
            treasury
        );
        
        console.log("mockRegistryConsumer deployed at:", address(registryConsumer));
        console.log("DoppiUpkeepManager deployed at:", address(doppiUpkeepManager));
        doppiUpkeepManager.setMaxDelay(100 days);
        doppiUpkeepManager.setForwarderAddress(forwarder);
        _doppiFactory.setDoppiUpKeepManager(address(doppiUpkeepManager));
        return doppiUpkeepManager;
    }  

    function _defaultPrivateWeights() internal pure returns (uint24[] memory weights) {
        weights = new uint24[](5);
        weights[0] = 500;
        weights[1] = 1000;
        weights[2] = 1500;
        weights[3] = 2500;
        weights[4] = 4500;
    }
        

            
}
