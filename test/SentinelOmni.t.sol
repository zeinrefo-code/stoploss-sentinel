// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import "../src/StopLossSentinelOmni.sol";
import "../src/MockERC20.sol";
import "../src/MockDex.sol";
import "../src/StopLossVault.sol";
import "./MockSystemOmni.sol";

contract SentinelOmniTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant ORDER_CREATED_TOPIC0 =
        uint256(keccak256("OrderCreated(uint256,address,uint256,uint256,uint256)"));
    uint256 internal constant PRICE_UPDATED_TOPIC0 = uint256(keccak256("PriceUpdated(uint256,uint256)"));

    MockSystemOmni internal system;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockDex internal dex;
    StopLossVault internal vault;
    StopLossSentinelOmni internal sentinel;

    function setUp() public {
        MockSystemOmni mock = new MockSystemOmni();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        system = MockSystemOmni(payable(SYSTEM_ADDR));

        tokenA = new MockERC20("Stop Loss Token", "SLT");
        tokenB = new MockERC20("Mock USD", "mUSD");
        dex = new MockDex(address(tokenA), address(tokenB));
        tokenA.mint(address(this), 2_000_000 ether);
        tokenB.mint(address(this), 4_000_000 ether);
        tokenA.approve(address(dex), 1_000_000 ether);
        tokenB.approve(address(dex), 2_000_000 ether);
        dex.addLiquidity(1_000_000 ether, 2_000_000 ether); // price 2.0

        vault = new StopLossVault{ value: 0.02 ether }(SYSTEM_ADDR, address(dex));
        sentinel = new StopLossSentinelOmni{ value: 0.25 ether }(address(dex), address(vault));

        tokenA.approve(address(vault), 10_000 ether);
        vault.deposit(10_000 ether);
        vault.createOrder(5_000 ether, 1.5 ether, 3 ether); // order 0
    }

    function _orderCreatedLog(uint256 orderId) internal view returns (IReactive.LogRecord memory log_) {
        log_.chainId = 84532;
        log_.contractAddress = address(vault);
        log_.topic0 = ORDER_CREATED_TOPIC0;
        log_.topic1 = orderId;
        log_.topic2 = uint256(uint160(address(this)));
        log_.data = abi.encode(5_000 ether, 1.5 ether, 3 ether);
        log_.opCode = 3;
    }

    function _priceLog(uint256 price, uint256 ts) internal view returns (IReactive.LogRecord memory log_) {
        log_.chainId = 84532;
        log_.contractAddress = address(dex);
        log_.topic0 = PRICE_UPDATED_TOPIC0;
        log_.data = abi.encode(price, ts);
        log_.opCode = 1;
    }

    function test_ConstructorSubscribesTwice() public view {
        assertEq(system.subscriptionCount(), 2);
    }

    function test_ReactRevertsForNonSystem() public {
        vm.expectRevert();
        sentinel.react(_orderCreatedLog(0));
    }

    function test_TrackThenStopLossRequestsCallback() public {
        vm.prank(SYSTEM_ADDR);
        sentinel.react(_orderCreatedLog(0));
        (bool exists, bool active, uint256 sl, uint256 tp) = sentinel.trackedOrders(0);
        assertTrue(exists);
        assertTrue(active);
        assertEq(sl, 1.5 ether);
        assertEq(tp, 3 ether);
        assertEq(sentinel.trackedOrderCount(), 1);

        // Non-crossing price: no callback.
        vm.prank(SYSTEM_ADDR);
        sentinel.react(_priceLog(2 ether, 1_700_000_000));
        assertEq(system.callbackCount(), 0);

        // Crossing price (stop-loss): exactly one callback request, correctly addressed.
        vm.prank(SYSTEM_ADDR);
        sentinel.react(_priceLog(1.4 ether, 1_700_000_042));
        assertEq(system.callbackCount(), 1);
        assertEq(system.lastChainId(), 84532);
        assertEq(system.lastRecipient(), address(vault));
        assertEq(system.lastGasLimit(), 1_000_000);
        bytes memory expected = abi.encodeWithSignature(
            "executeOrder(address,uint256,uint256,uint256)", address(0), uint256(0), 1.4 ether, 1_700_000_042
        );
        assertEq(system.lastPayload(), expected);

        // Order marked inactive: a second crossing price cannot double-fire.
        (, bool activeAfter,,) = sentinel.trackedOrders(0);
        assertFalse(activeAfter);
        vm.prank(SYSTEM_ADDR);
        sentinel.react(_priceLog(1.3 ether, 1_700_000_100));
        assertEq(system.callbackCount(), 1);
    }

    function test_TakeProfitRequestsCallback() public {
        vm.prank(SYSTEM_ADDR);
        sentinel.react(_orderCreatedLog(0));
        vm.prank(SYSTEM_ADDR);
        sentinel.react(_priceLog(3.2 ether, 1_700_000_500));
        assertEq(system.callbackCount(), 1);
        bytes memory expected = abi.encodeWithSignature(
            "executeOrder(address,uint256,uint256,uint256)", address(0), uint256(0), 3.2 ether, 1_700_000_500
        );
        assertEq(system.lastPayload(), expected);
    }
}
