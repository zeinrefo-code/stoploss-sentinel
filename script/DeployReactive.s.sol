// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/StopLossSentinelReactive.sol";

/// @notice Step 2 (Reactive Lasna): deploy the StopLoss Sentinel reactive
///         contract, subscribed to the vault + DEX deployed in step 1.
///         Env: DEX_ADDR, VAULT_ADDR, REACT_FUNDING (wei, default 3 lREACT).
///         Run: forge script script/DeployReactive.s.sol --rpc-url lasna \
///              --private-key $DEPLOYER_PK --broadcast -vvv
contract DeployReactive is Script {
    function run() external {
        address dex = vm.envAddress("DEX_ADDR");
        address vault = vm.envAddress("VAULT_ADDR");
        uint256 funding = vm.envOr("REACT_FUNDING", uint256(3 ether));

        vm.startBroadcast();
        StopLossSentinelReactive sentinel = new StopLossSentinelReactive{value: funding}(dex, vault);
        vm.stopBroadcast();

        console.log("SENTINEL=", address(sentinel));
        console.log("FUNDED_LREACT=", funding);
    }
}
