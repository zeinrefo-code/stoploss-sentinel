// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import "../src/StopLossSentinelOmni.sol";
import "../src/StopLossVaultOmni.sol";
import "../src/MockERC20.sol";
import "../src/MockDex.sol";
import "./MockSystemOmni.sol";

/// @notice End-to-end local proof of the Omni pair: order -> OrderCreated log
///         -> react() -> captured callback request -> proxy delivery (with the
///         reactive contract's address injected into the payload's first
///         slot, exactly as the network does) -> swap executed in the vault.
contract OmniLoopTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585; // Base Sepolia, per current docs
    uint256 internal constant ORDER_CREATED_TOPIC0 =
        uint256(keccak256("OrderCreated(uint256,address,uint256,uint256,uint256)"));
    uint256 internal constant PRICE_UPDATED_TOPIC0 = uint256(keccak256("PriceUpdated(uint256,uint256)"));

    MockSystemOmni internal system;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockDex internal dex;
    StopLossVaultOmni internal vault;
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

        // Same CREATE-prediction the production deployment uses: the vault
        // is deployed right after the Sentinel, so its address is computable
        // before the Sentinel (which needs it immutably) is deployed.
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        sentinel = new StopLossSentinelOmni{ value: 0.25 ether }(address(dex), predictedVault);
        vault = new StopLossVaultOmni{ value: 0.003 ether }(
            IPayable(payable(PROXY)), address(sentinel), address(dex)
        );
        require(address(vault) == predictedVault, "vault address prediction failed");

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

    /// @dev Simulates the network: take the payload the Sentinel requested,
    ///      overwrite its first address slot with the Sentinel's address
    ///      (what the proxy injects), and deliver it from the proxy.
    function _deliverCapturedCallback() internal {
        bytes memory payload = system.lastPayload();
        bytes memory injected = abi.encodePacked(abi.encode(address(sentinel)), _stripFirstArg(payload));
        // Rebuild: selector + injected address + remaining args verbatim.
        bytes4 selector;
        assembly {
            selector := mload(add(payload, 0x20))
        }
        bytes memory callData = abi.encodePacked(selector, injected);
        vm.prank(PROXY);
        (bool ok, bytes memory ret) = address(vault).call(callData);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _stripFirstArg(bytes memory payload) internal pure returns (bytes memory rest) {
        // payload = 4-byte selector + 32-byte first arg + rest
        rest = new bytes(payload.length - 36);
        for (uint256 i = 0; i < rest.length; i++) {
            rest[i] = payload[36 + i];
        }
    }

    function test_FullOmniLoop_StopLoss() public {
        vm.warp(1_700_000_100);
        vm.prank(SYSTEM_ADDR);
        sentinel.react(_orderCreatedLog(0));

        dex.setPrice(1.4 ether);
        vm.prank(SYSTEM_ADDR);
        sentinel.react(_priceLog(1.4 ether, 1_700_000_042));
        assertEq(system.callbackCount(), 1);
        assertEq(system.lastRecipient(), address(vault));

        _deliverCapturedCallback();

        (,,,, bool active, bool executed, uint256 triggerPrice, uint256 amountOut, uint256 latency) = vault.orders(0);
        assertTrue(executed);
        assertFalse(active);
        assertEq(triggerPrice, 1.4 ether);
        assertEq(amountOut, 6_979 ether); // 5,000 x 1.4 x 0.997
        assertEq(latency, 58); // 1_700_000_100 - 1_700_000_042
        assertEq(vault.claimable(address(this)), 6_979 ether);
    }

    function test_CallbackRejectsWrongReactiveSender() public {
        bytes memory payload = abi.encodeWithSignature(
            "executeOrder(address,uint256,uint256,uint256)", address(0xDEAD), uint256(0), 1.4 ether, uint256(1_700_000_042)
        );
        vm.prank(PROXY);
        (bool ok,) = address(vault).call(payload);
        assertFalse(ok);
    }

    function test_CallbackRejectsNonProxyCaller() public {
        bytes memory payload = abi.encodeWithSignature(
            "executeOrder(address,uint256,uint256,uint256)",
            address(sentinel),
            uint256(0),
            1.4 ether,
            uint256(1_700_000_042)
        );
        (bool ok,) = address(vault).call(payload);
        assertFalse(ok);
    }
}
