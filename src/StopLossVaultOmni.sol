// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import "./MockERC20.sol";
import "./MockDex.sol";

/// @title StopLossVaultOmni — destination contract on Base Sepolia, rewritten
///        for the Reactive Omni architecture.
/// @notice The legacy vault (`StopLossVault`) authorizes the pre-migration
///         callback proxy 0x8888…8888. Under Omni, Base Sepolia callbacks are
///         delivered by the per-chain proxy 0x476F44b1…585, so the legacy
///         vault can never accept a delivery. This version inherits the Omni
///         `AbstractCallback`: the delivery is authenticated twice — the
///         caller must be the callback proxy (`onlyServiceProvider`) and the
///         address the proxy injects into the payload's first slot must be
///         the authorized reactive contract (`onlyCallbackSender`).
/// @notice Users deposit tokenA and create stop-loss / take-profit orders.
///         `OrderCreated` is watched by the StopLoss Sentinel reactive
///         contract on Lasna. When the Sentinel decides a threshold has been
///         crossed, the Reactive Network's callback proxy calls
///         `executeOrder`, which performs the protective swap on MockDex and
///         records the measured end-to-end loop latency on-chain.
contract StopLossVaultOmni is AbstractCallback {
    MockDex public immutable dex;
    MockERC20 public immutable tokenA;
    MockERC20 public immutable tokenB;

    struct Order {
        address owner;
        uint256 amount; // tokenA escrowed in the order
        uint256 stopLossPrice; // execute when price <= this (1e18 scaled)
        uint256 takeProfitPrice; // execute when price >= this (1e18 scaled)
        bool active;
        bool executed;
        uint256 triggerPrice;
        uint256 amountOut;
        uint256 loopLatencySeconds;
    }

    Order[] public orders;

    /// @notice Free tokenA balances (deposited, not escrowed in an order).
    mapping(address => uint256) public balances;
    /// @notice tokenB proceeds claimable after an execution.
    mapping(address => uint256) public claimable;

    /// @dev Subscribed by the reactive contract. orderId + owner are indexed
    ///      (topics 1 and 2); the order parameters travel in the log data.
    event OrderCreated(
        uint256 indexed orderId, address indexed owner, uint256 amount, uint256 stopLossPrice, uint256 takeProfitPrice
    );
    event OrderCancelled(uint256 indexed orderId);
    event OrderExecuted(
        uint256 indexed orderId, uint256 triggerPrice, uint256 amountIn, uint256 amountOut, uint256 loopLatencySeconds
    );
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event ProceedsClaimed(address indexed user, uint256 amount);

    constructor(IPayable _callbackProxy, address _callbackSender, address _dex)
        payable
        AbstractCallback(_callbackProxy, _callbackSender)
    {
        dex = MockDex(_dex);
        tokenA = dex.tokenA();
        tokenB = dex.tokenB();
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "Vault: zero deposit");
        require(tokenA.transferFrom(msg.sender, address(this), amount), "Vault: transfer failed");
        balances[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Vault: insufficient balance");
        balances[msg.sender] -= amount;
        require(tokenA.transfer(msg.sender, amount), "Vault: transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Create a stop-loss / take-profit order over deposited tokenA.
    function createOrder(uint256 amount, uint256 stopLossPrice, uint256 takeProfitPrice)
        external
        returns (uint256 orderId)
    {
        require(amount > 0, "Vault: zero amount");
        require(balances[msg.sender] >= amount, "Vault: insufficient balance");
        require(stopLossPrice > 0 && stopLossPrice < takeProfitPrice, "Vault: bad thresholds");
        balances[msg.sender] -= amount;
        orderId = orders.length;
        orders.push(
            Order({
                owner: msg.sender,
                amount: amount,
                stopLossPrice: stopLossPrice,
                takeProfitPrice: takeProfitPrice,
                active: true,
                executed: false,
                triggerPrice: 0,
                amountOut: 0,
                loopLatencySeconds: 0
            })
        );
        emit OrderCreated(orderId, msg.sender, amount, stopLossPrice, takeProfitPrice);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        require(order.owner == msg.sender, "Vault: not order owner");
        require(order.active && !order.executed, "Vault: order not active");
        order.active = false;
        balances[msg.sender] += order.amount;
        emit OrderCancelled(orderId);
    }

    /// @notice Callback entry point, called by the Reactive Network callback
    ///         proxy only, and only for callbacks originating from the
    ///         authorized reactive contract. The first parameter is the
    ///         reactive contract's address, injected by the proxy over the
    ///         placeholder in the requested payload.
    /// @param originTimestamp Timestamp of the origin `PriceUpdated` event on
    ///        Base Sepolia, carried through the reactive contract so the loop
    ///        latency can be measured and stored on-chain.
    function executeOrder(address reactive_, uint256 orderId, uint256 triggerPrice, uint256 originTimestamp)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        Order storage order = orders[orderId];
        require(order.active && !order.executed, "Vault: order not executable");

        require(tokenA.approve(address(dex), order.amount), "Vault: approve failed");
        uint256 amountOut = dex.swapAForB(order.amount);

        order.executed = true;
        order.active = false;
        order.triggerPrice = triggerPrice;
        order.amountOut = amountOut;
        order.loopLatencySeconds = block.timestamp - originTimestamp;
        claimable[order.owner] += amountOut;

        emit OrderExecuted(orderId, triggerPrice, order.amount, amountOut, order.loopLatencySeconds);
    }

    /// @notice Settles outstanding callback debt from this contract's own
    ///         balance (a contract in debt receives nothing).
    function coverDebt() external {
        _coverDebt();
    }

    function claimProceeds() external {
        uint256 amount = claimable[msg.sender];
        require(amount > 0, "Vault: nothing to claim");
        claimable[msg.sender] = 0;
        require(tokenB.transfer(msg.sender, amount), "Vault: transfer failed");
        emit ProceedsClaimed(msg.sender, amount);
    }

    function orderCount() external view returns (uint256) {
        return orders.length;
    }
}
