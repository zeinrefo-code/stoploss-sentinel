// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "reactive-lib/interfaces/IReactive.sol";
import "../src/MockERC20.sol";
import "../src/MockDex.sol";
import "../src/StopLossVault.sol";
import "../src/StopLossSentinelReactive.sol";

/// @notice Local simulation of the full cross-chain loop:
///         Base Sepolia event -> Lasna react() -> Callback event -> proxy
///         delivery -> vault execution on Base Sepolia. On a single local
///         chain the Reactive Network's transport is replaced by hand-built
///         LogRecords and a pranked callback-proxy call; the contract logic
///         under test is identical to production.
contract SentinelLoopTest is Test {
    address internal constant CALLBACK_PROXY = 0x8888888888888888888888888888888888888888;
    uint256 internal constant ORDER_CREATED_TOPIC0 =
        uint256(keccak256("OrderCreated(uint256,address,uint256,uint256,uint256)"));
    uint256 internal constant PRICE_UPDATED_TOPIC0 = uint256(keccak256("PriceUpdated(uint256,uint256)"));

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockDex internal dex;
    StopLossVault internal vault;
    StopLossSentinelReactive internal sentinel;

    function setUp() public {
        vm.warp(1_700_000_000);
        tokenA = new MockERC20("Sentinel Token", "SLT");
        tokenB = new MockERC20("Mock USD", "mUSD");
        dex = new MockDex(address(tokenA), address(tokenB));
        vault = new StopLossVault{value: 0.02 ether}(CALLBACK_PROXY, address(dex));
        sentinel = new StopLossSentinelReactive(address(dex), address(vault));

        // Liquidity: 1,000,000 SLT / 2,000,000 mUSD -> price 2.0 mUSD per SLT.
        tokenA.mint(address(this), 2_000_000 ether);
        tokenB.mint(address(this), 3_000_000 ether);
        tokenA.approve(address(dex), type(uint256).max);
        tokenB.approve(address(dex), type(uint256).max);
        dex.addLiquidity(1_000_000 ether, 2_000_000 ether);
    }

    function _orderCreatedLog(uint256 orderId, uint256 amount, uint256 sl, uint256 tp)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: 84532,
            _contract: address(vault),
            topic_0: ORDER_CREATED_TOPIC0,
            topic_1: orderId,
            topic_2: uint256(uint160(address(this))),
            topic_3: 0,
            data: abi.encode(amount, sl, tp),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _priceLog(uint256 price, uint256 ts) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: 84532,
            _contract: address(dex),
            topic_0: PRICE_UPDATED_TOPIC0,
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(price, ts),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _createOrder() internal returns (uint256 orderId) {
        tokenA.approve(address(vault), type(uint256).max);
        vault.deposit(10_000 ether);
        orderId = vault.createOrder(5_000 ether, 1.5 ether, 3 ether);
        sentinel.react(_orderCreatedLog(orderId, 5_000 ether, 1.5 ether, 3 ether));
    }

    /// @dev Unpacks (executed, amountOut, loopLatencySeconds) from the vault's
    ///      Order struct getter: (owner, amount, stopLoss, takeProfit,
    ///      active, executed, triggerPrice, amountOut, latency).
    function _execInfo(uint256 id) internal view returns (bool executed, uint256 amountOut, uint256 latency) {
        (,,,,, executed,, amountOut, latency) = vault.orders(id);
    }

    function test_StopLossLoop() public {
        uint256 orderId = _createOrder();
        (bool exists, bool active, uint256 sl, uint256 tp) = sentinel.trackedOrders(orderId);
        assertTrue(exists && active);
        assertEq(sl, 1.5 ether);
        assertEq(tp, 3 ether);

        // Non-crossing price move: no trigger.
        dex.setPrice(1.9 ether);
        sentinel.react(_priceLog(1.9 ether, block.timestamp));
        (bool executed0,,) = _execInfo(orderId);
        assertFalse(executed0);

        // Price crashes through the stop-loss. The origin event is stamped 42
        // seconds in the past to simulate network latency.
        uint256 originTs = block.timestamp - 42;
        dex.setPrice(1.4 ether);
        vm.recordLogs();
        sentinel.react(_priceLog(1.4 ether, originTs));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory payload;
        bool sawCallback = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                payload = abi.decode(logs[i].data, (bytes));
                sawCallback = true;
            }
        }
        assertTrue(sawCallback, "react() must emit a Callback");
        // Payload = 4-byte selector + ABI-encoded arguments; strip the
        // selector before decoding, and check it targets executeOrder.
        bytes4 selector;
        assembly {
            selector := mload(add(payload, 32))
        }
        assertEq(selector, StopLossVault.executeOrder.selector);
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
        (, uint256 cbOrder, uint256 cbPrice, uint256 cbTs) = abi.decode(args, (address, uint256, uint256, uint256));
        assertEq(cbOrder, orderId);
        assertEq(cbPrice, 1.4 ether);
        assertEq(cbTs, originTs);

        // The callback proxy delivers the payload to the vault.
        vm.prank(CALLBACK_PROXY);
        vault.executeOrder(address(0), orderId, 1.4 ether, originTs);

        (bool executed, uint256 amountOut, uint256 latency) = _execInfo(orderId);
        assertTrue(executed);
        // 5000 SLT * 1.4 * 0.997 = 6979 mUSD
        assertEq(amountOut, 6979 ether);
        assertEq(latency, 42);
        assertEq(vault.claimable(address(this)), 6979 ether);

        // A second, deeper price event must not re-fire the executed order:
        // the Sentinel has already marked it inactive.
        (, bool stillActive,,) = sentinel.trackedOrders(orderId);
        assertFalse(stillActive);
    }

    function test_TakeProfitLoop() public {
        uint256 orderId = _createOrder();
        dex.setPrice(3.2 ether);
        sentinel.react(_priceLog(3.2 ether, block.timestamp));
        vm.prank(CALLBACK_PROXY);
        vault.executeOrder(address(0), orderId, 3.2 ether, block.timestamp);
        (bool executed, uint256 amountOut,) = _execInfo(orderId);
        assertTrue(executed);
        // 5000 * 3.2 * 0.997 = 15952 mUSD
        assertEq(amountOut, 15952 ether);
    }

    function test_CallbackRejectsStrangers() public {
        uint256 orderId = _createOrder();
        vm.expectRevert(bytes("Authorized sender only"));
        vault.executeOrder(address(0), orderId, 1.4 ether, block.timestamp);
    }
}
