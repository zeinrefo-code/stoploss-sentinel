// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "reactive-lib/interfaces/IReactive.sol";
import "reactive-lib/abstract-base/AbstractReactive.sol";

/// @title StopLossSentinelReactive — the "StopLoss Sentinel" reactive contract.
/// @notice Deployed on Reactive Lasna testnet (chain 5318007). Subscribes to
///         two event streams on Base Sepolia (chain 84532):
///           1. StopLossVault `OrderCreated` — to learn each order's
///              stop-loss / take-profit thresholds.
///           2. MockDex `PriceUpdated` — to watch the market.
///         When a price update crosses an active order's threshold, it emits
///         a `Callback` that the Reactive Network delivers to the vault on
///         Base Sepolia, executing the protective swap. No keeper, no bot:
///         the contract itself is the automation.
contract StopLossSentinelReactive is IReactive, AbstractReactive {
    uint256 public constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    uint64 public constant CALLBACK_GAS_LIMIT = 1000000;

    uint256 internal constant ORDER_CREATED_TOPIC0 =
        uint256(keccak256("OrderCreated(uint256,address,uint256,uint256,uint256)"));
    uint256 internal constant PRICE_UPDATED_TOPIC0 = uint256(keccak256("PriceUpdated(uint256,uint256)"));

    address public immutable dex;
    address public immutable vault;

    struct TrackedOrder {
        bool exists;
        bool active;
        uint256 stopLossPrice;
        uint256 takeProfitPrice;
    }

    mapping(uint256 => TrackedOrder) public trackedOrders;
    uint256[] public orderIds;

    event OrderTracked(uint256 indexed orderId, uint256 stopLossPrice, uint256 takeProfitPrice);
    event PriceChecked(uint256 price, uint256 ordersChecked);
    event Triggered(uint256 indexed orderId, uint256 price, bool isStopLoss);

    constructor(address _dex, address _vault) payable {
        dex = _dex;
        vault = _vault;
        if (!vm) {
            // Subscriptions are created from the network-side (non-VM) copy of
            // this contract at deployment time.
            service.subscribe(
                ORIGIN_CHAIN_ID, vault, ORDER_CREATED_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            service.subscribe(
                ORIGIN_CHAIN_ID, dex, PRICE_UPDATED_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    /// @notice Entry point for event notifications (ReactVM copy only).
    function react(LogRecord calldata log) external vmOnly {
        if (log._contract == vault && log.topic_0 == ORDER_CREATED_TOPIC0) {
            _trackOrder(log);
        } else if (log._contract == dex && log.topic_0 == PRICE_UPDATED_TOPIC0) {
            _checkPrice(log);
        }
    }

    function _trackOrder(LogRecord calldata log) internal {
        uint256 orderId = uint256(log.topic_1);
        (uint256 amount, uint256 stopLossPrice, uint256 takeProfitPrice) =
            abi.decode(log.data, (uint256, uint256, uint256));
        amount; // amount is enforced by the vault; the Sentinel only needs thresholds
        if (!trackedOrders[orderId].exists) {
            orderIds.push(orderId);
        }
        trackedOrders[orderId] = TrackedOrder({
            exists: true, active: true, stopLossPrice: stopLossPrice, takeProfitPrice: takeProfitPrice
        });
        emit OrderTracked(orderId, stopLossPrice, takeProfitPrice);
    }

    function _checkPrice(LogRecord calldata log) internal {
        (uint256 price, uint256 originTimestamp) = abi.decode(log.data, (uint256, uint256));
        emit PriceChecked(price, orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];
            TrackedOrder storage order = trackedOrders[orderId];
            if (!order.active) {
                continue;
            }
            bool isStopLoss = price <= order.stopLossPrice;
            bool isTakeProfit = price >= order.takeProfitPrice;
            if (isStopLoss || isTakeProfit) {
                // Mark first so a later price event can never double-fire.
                order.active = false;
                bytes memory payload = abi.encodeWithSignature(
                    "executeOrder(address,uint256,uint256,uint256)", address(0), orderId, price, originTimestamp
                );
                emit Callback(ORIGIN_CHAIN_ID, vault, CALLBACK_GAS_LIMIT, payload);
                emit Triggered(orderId, price, isStopLoss);
            }
        }
    }

    function trackedOrderCount() external view returns (uint256) {
        return orderIds.length;
    }
}
