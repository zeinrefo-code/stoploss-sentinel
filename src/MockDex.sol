// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./MockERC20.sol";

/// @title MockDex — a minimal two-token spot DEX used as the event origin.
/// @notice Holds reserves of tokenA/tokenB. The price (tokenB per tokenA, 1e18
///         scaled) is set by the owner acting as market maker; every price
///         change emits `PriceUpdated(price, timestamp)`, which is the event
///         the StopLoss Sentinel reactive contract subscribes to. Swaps execute
///         at the current spot price minus a 0.3% fee and also move the price,
///         emitting `PriceUpdated` like a real pool would.
contract MockDex {
    MockERC20 public immutable tokenA;
    MockERC20 public immutable tokenB;
    address public immutable owner;

    uint256 public reserveA;
    uint256 public reserveB;

    /// @dev The origin event the reactive contract watches. Both fields are in
    ///      the log data: the Reactive `LogRecord` carries no timestamp, so the
    ///      origin timestamp travels inside the event data and lets the
    ///      destination vault measure end-to-end loop latency on-chain.
    event PriceUpdated(uint256 price, uint256 timestamp);
    event LiquidityAdded(uint256 amountA, uint256 amountB);
    event Swap(address indexed trader, uint256 amountIn, uint256 amountOut, uint256 price);

    modifier onlyOwner() {
        require(msg.sender == owner, "MockDex: not owner");
        _;
    }

    constructor(address _tokenA, address _tokenB) {
        tokenA = MockERC20(_tokenA);
        tokenB = MockERC20(_tokenB);
        owner = msg.sender;
    }

    /// @notice Current spot price: tokenB per tokenA, scaled by 1e18.
    function price() public view returns (uint256) {
        require(reserveA > 0, "MockDex: no liquidity");
        return (reserveB * 1e18) / reserveA;
    }

    function addLiquidity(uint256 amountA, uint256 amountB) external {
        require(tokenA.transferFrom(msg.sender, address(this), amountA), "MockDex: A transfer failed");
        require(tokenB.transferFrom(msg.sender, address(this), amountB), "MockDex: B transfer failed");
        reserveA += amountA;
        reserveB += amountB;
        emit LiquidityAdded(amountA, amountB);
        emit PriceUpdated(price(), block.timestamp);
    }

    /// @notice Market-maker price move. Keeps reserveA constant and rebalances
    ///         reserveB (minting/burning the mock quote token to back the new
    ///         reserve), then emits the `PriceUpdated` event the Sentinel
    ///         reacts to.
    function setPrice(uint256 newPrice) external onlyOwner {
        require(reserveA > 0, "MockDex: no liquidity");
        require(newPrice > 0, "MockDex: zero price");
        uint256 targetB = (reserveA * newPrice) / 1e18;
        if (targetB > reserveB) {
            tokenB.mint(address(this), targetB - reserveB);
        } else if (targetB < reserveB) {
            tokenB.burn(reserveB - targetB);
        }
        reserveB = targetB;
        emit PriceUpdated(newPrice, block.timestamp);
    }

    /// @notice Swap tokenA for tokenB at spot (0.3% fee). Used by the vault to
    ///         execute a triggered stop-loss / take-profit order.
    function swapAForB(uint256 amountIn) external returns (uint256 amountOut) {
        uint256 p = price();
        amountOut = (((amountIn * p) / 1e18) * 997) / 1000;
        require(amountOut > 0 && amountOut <= reserveB, "MockDex: insufficient output liquidity");
        require(tokenA.transferFrom(msg.sender, address(this), amountIn), "MockDex: A transfer failed");
        reserveA += amountIn;
        reserveB -= amountOut;
        require(tokenB.transfer(msg.sender, amountOut), "MockDex: B transfer failed");
        emit Swap(msg.sender, amountIn, amountOut, p);
        emit PriceUpdated(price(), block.timestamp);
    }
}
