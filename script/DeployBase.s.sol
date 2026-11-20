// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/MockERC20.sol";
import "../src/MockDex.sol";
import "../src/StopLossVault.sol";

/// @notice Step 1 (Base Sepolia): deploy tokens, mock DEX, seed liquidity,
///         deploy the StopLossVault destination contract.
///         Run: forge script script/DeployBase.s.sol --rpc-url base_sepolia \
///              --private-key $DEPLOYER_PK --broadcast -vvv
contract DeployBase is Script {
    address internal constant CALLBACK_PROXY = 0x8888888888888888888888888888888888888888;

    function run() external {
        vm.startBroadcast();

        MockERC20 tokenA = new MockERC20("Sentinel Token", "SLT");
        MockERC20 tokenB = new MockERC20("Mock USD", "mUSD");
        MockDex dex = new MockDex(address(tokenA), address(tokenB));

        // Liquidity: 1,000,000 SLT / 2,000,000 mUSD -> opening price 2.0.
        tokenA.mint(msg.sender, 2_000_000 ether);
        tokenB.mint(msg.sender, 3_000_000 ether);
        tokenA.approve(address(dex), type(uint256).max);
        tokenB.approve(address(dex), type(uint256).max);
        dex.addLiquidity(1_000_000 ether, 2_000_000 ether);

        // Destination contract, funded so it can settle callback-proxy debt.
        StopLossVault vault = new StopLossVault{value: 0.02 ether}(CALLBACK_PROXY, address(dex));

        vm.stopBroadcast();

        console.log("TOKEN_A=", address(tokenA));
        console.log("TOKEN_B=", address(tokenB));
        console.log("DEX=", address(dex));
        console.log("VAULT=", address(vault));
        console.log("OPENING_PRICE=", dex.price());
    }
}
