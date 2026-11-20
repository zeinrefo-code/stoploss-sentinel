// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title StopLossSentinelOmni — the "StopLoss Sentinel" reactive contract,
///        rewritten for the Reactive Omni architecture.
/// @notice The legacy version (`StopLossSentinelReactive`) was deployed to
///         Lasna after the network's Omni migration (Oct 2026) and never
///         reacted: under Omni there is no ReactVM, so the legacy `vmOnly`
///         gate rejects every delivery and legacy-service subscriptions are
///         not dispatched. This contract follows the current Omni pattern:
///         it subscribes through the system contract at 0x8888…8888, receives
///         reactive transactions from it (`onlySystem`), and requests
///         callbacks via `requestCallbackV_1_0`.
/// @notice Deployed on Reactive Lasna testnet (chain 5318007). Subscribes to
///         two event streams on Base Sepolia (chain 84532):
///           1. StopLossVault `OrderCreated` — to learn each order's
///              stop-loss / take-profit thresholds.
///           2. MockDex `PriceUpdated` — to watch the market.
///         When a price update crosses an active order's threshold, it asks
///         the system contract to post a callback to the vault on Base
///         Sepolia, which executes the protective swap. No keeper, no bot:
///         the contract itself is the automation.
contract StopLossSentinelOmni is AbstractReactive {
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
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID, vault, ORDER_CREATED_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID, dex, PRICE_UPDATED_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        if (log_.contractAddress == vault && log_.topic0 == ORDER_CREATED_TOPIC0) {
            _trackOrder(log_);
        } else if (log_.contractAddress == dex && log_.topic0 == PRICE_UPDATED_TOPIC0) {
            _checkPrice(log_);
        }
    }

    /// @notice Settles any outstanding debt to the system contract from this
    ///         contract's own balance (a contract in debt receives nothing).
    function coverDebt() external {
        _coverDebt();
    }

    function _trackOrder(LogRecord memory log_) internal {
        uint256 orderId = log_.topic1;
        (uint256 amount, uint256 stopLossPrice, uint256 takeProfitPrice) =
            abi.decode(log_.data, (uint256, uint256, uint256));
        amount; // amount is enforced by the vault; the Sentinel only needs thresholds
        if (!trackedOrders[orderId].exists) {
            orderIds.push(orderId);
        }
        trackedOrders[orderId] = TrackedOrder({
            exists: true, active: true, stopLossPrice: stopLossPrice, takeProfitPrice: takeProfitPrice
        });
        emit OrderTracked(orderId, stopLossPrice, takeProfitPrice);
    }

    function _checkPrice(LogRecord memory log_) internal {
        (uint256 price, uint256 originTimestamp) = abi.decode(log_.data, (uint256, uint256));
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
                // The payload's first argument is an address placeholder: the
                // network replaces it with this contract's address so the
                // vault can authenticate the callback's origin.
                bytes memory payload = abi.encodeWithSignature(
                    "executeOrder(address,uint256,uint256,uint256)", address(0), orderId, price, originTimestamp
                );
                SYSTEM.requestCallbackV_1_0(
                    ISystemContract.CallbackConfiguration_V_1_0({
                        chainId: ORIGIN_CHAIN_ID, recipient: vault, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
                    })
                );
                emit Triggered(orderId, price, isStopLoss);
            }
        }
    }

    function trackedOrderCount() external view returns (uint256) {
        return orderIds.length;
    }
}
