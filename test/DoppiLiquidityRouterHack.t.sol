// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiLiquidity} from "../src/mainnet/DoppiLiquidity.sol";
import {DoppiLiquidityRouter, EntryPointAssetA} from "../src/mainnet/DoppiLiquidityRouter.sol";
import {MockToken} from "../src/test/MockToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC7575} from "../src/Interface/IERC7575.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {Swapper} from "../src/test/Swapper.sol";
import {DoppiConfig} from "../src/mainnet/DoppiConfig.sol";
import {TestParamLib} from "../src/Library/TestParamLib.sol";
import "../src/mainnet/DoppiLiquidityTypes.sol";

contract DoppiLiquidityRouterTest is Test {
    DoppiLiquidityRouter public router;
    DoppiLiquidity public doppiLP;
    MockToken public usdt;
    MockToken public btc;
    MockOracle public oracle;
    Swapper public swapper;
    DoppiConfig public doppiConfig;
    ConfigParam configLP;
    
    uint256 public INITIAL_BALANCE_USDT = 10000 ether;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public attacker = address(0x4);
    

    event Deposited(address indexed user, uint256 amount, address asset, uint256 shares);
    event Redeemed(address indexed user, uint256 shares, uint256 assetsA, uint256 assetsB);
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy mock tokens
        usdt = new MockToken("USDT", "USDT");
        btc = new MockToken("Bitcoin", "BTC");
        console.log(address(usdt), "usdt");
        console.log(address(btc), "btc");
        
        // Deploy mock oracle with 100,000 USDT per BTC price
        oracle = new MockOracle(int256(100_000 * 1e8), 8);
        // Deploy Swapper that will act as both router and pool
        swapper = new Swapper(usdt, btc);
        swapper.setOracle(MockOracle(oracle)); 
        // deploy doppiConfig
        doppiConfig = new DoppiConfig();
        // doppiConfig.setTreasury(address(0x9));
        
        // Deploy doppiLP
        doppiLP =
            new DoppiLiquidity("Dual Asset LP", "DALP", IERC20(address(usdt)), IERC20(address(btc)));

        // Deploy doppiLPRouter
        router = new DoppiLiquidityRouter(IERC20(address(usdt)), IERC20(address(btc)), doppiLP);

        
        // Setup liquidity pool
        configLP = TestParamLib.get_configLP();
        configLP.chainLinkFeed = address(oracle);
        configLP.quoter = address(swapper);
        configLP.router = address(swapper);
        doppiLP.setConfig(configLP);

        doppiLP.setDoppiCore(address(0x4)); // Mock core address
        doppiLP.setDoppiTraderFactory(address(0x5)); // Mock factory address
        doppiLP.approveRouter();
        doppiLP.setEntryPoint(address(router.entryPointA()), true);
        doppiLP.setEntryPoint(address(router.entryPointB()), true);
        doppiLP.approveEntryPoint(address(router.entryPointA()), address(usdt));
        doppiLP.approveEntryPoint(address(router.entryPointB()), address(btc));

        // Approve router for tokens
        usdt.approve(address(router), type(uint256).max);
        btc.approve(address(router), type(uint256).max);
        
        // Transfer tokens to users
        usdt.mint(user1, INITIAL_BALANCE_USDT);
        usdt.mint(user2, INITIAL_BALANCE_USDT);
        btc.mint(user1, 1000 * 10 ** btc.decimals());
        btc.mint(user2, 1000 * 10 ** btc.decimals());
        usdt.mint(attacker, INITIAL_BALANCE_USDT);
        usdt.mint(attacker, INITIAL_BALANCE_USDT);
        
        vm.stopPrank();
    }

    function test_DirectDepositToEntryPoint() public {

        uint256 depositAmount = 1000 ether;
        
        // User1 deposits directly to EntryPointA (bypassing router)
        vm.startPrank(user1);
        usdt.approve(address(router.entryPointA()), depositAmount);
        
        EntryPointAssetA entryPointA = EntryPointAssetA(address(router.entryPointA()));
        vm.expectRevert("Only router can call");
        entryPointA.deposit(depositAmount, user1);
        vm.stopPrank();
    }

    function test_DirectMintToEntryPoint() public {

        uint256 depositAmount = 1000 ether;
        
        // User1 deposits directly to EntryPointA (bypassing router)
        vm.startPrank(user1);
        usdt.approve(address(router.entryPointA()), depositAmount);
        
        EntryPointAssetA entryPointA = EntryPointAssetA(address(router.entryPointA()));
        vm.expectRevert("Mint not supported");
        entryPointA.mint(depositAmount, user1);
        vm.stopPrank();
    }
  
}
