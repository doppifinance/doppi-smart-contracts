// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DoppiFeePool} from "../src/mainnet/DoppiFeePool.sol";
import {MockToken} from "../src/test/MockToken.sol";

contract DoppiFeePoolTest is Test {
    DoppiFeePool feePool;
    MockToken token;

    address owner = address(this);
    address sharedLP = address(0x11);
    address receiver = address(0x22);
    address privateCore = address(0x33);
    address privateGridFactory = address(0x44);

    function setUp() public {
        token = new MockToken("USDT", "USDT");
        feePool = new DoppiFeePool(sharedLP, receiver, 3000); // 30%
        feePool.setAuthorizedCore(privateCore, true);
    }

    function test_setAuthorizedCore_allowsMultipleAuthorizers() public {
        feePool.setCoreAuthorizer(privateCore);
        feePool.setCoreAuthorizer(privateGridFactory);

        vm.prank(privateCore);
        feePool.setAuthorizedCore(address(0x55), true);

        vm.prank(privateGridFactory);
        feePool.setAuthorizedCore(address(0x66), true);

        assertTrue(feePool.authorizedCore(address(0x55)));
        assertTrue(feePool.authorizedCore(address(0x66)));
    }

    function test_onFeeReceived_splitsImmediately() public {
        token.mint(address(feePool), 1000 ether);

        vm.prank(privateCore);
        feePool.onFeeReceived(address(token), 1000 ether);

        assertEq(token.balanceOf(sharedLP), 300 ether);
        assertEq(token.balanceOf(receiver), 700 ether);
        assertEq(token.balanceOf(address(feePool)), 0);
    }

    function test_onFeeReceived_onlyAuthorizedCore() public {
        token.mint(address(feePool), 1000 ether);

        vm.expectRevert(DoppiFeePool.NotAuthorizedCore.selector);
        feePool.onFeeReceived(address(token), 1000 ether);
    }

    function test_onFeeReceived_capsByBalance() public {
        token.mint(address(feePool), 250 ether);

        vm.prank(privateCore);
        feePool.onFeeReceived(address(token), 1000 ether);

        assertEq(token.balanceOf(sharedLP), 75 ether);
        assertEq(token.balanceOf(receiver), 175 ether);
        assertEq(token.balanceOf(address(feePool)), 0);
    }
}
