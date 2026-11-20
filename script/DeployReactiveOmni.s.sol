// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Script.sol";
import "../src/StopLossSentinelOmni.sol";

/// @notice Deploys StopLossSentinelOmni (Reactive Omni pattern) on Lasna.
///         Env: DEX_ADDR, VAULT_ADDR, REACT_FUNDING (wei, default 0.25 ether).
contract DeployReactiveOmni is Script {
    function run() external {
        address dex = vm.envAddress("DEX_ADDR");
        address vault = vm.envAddress("VAULT_ADDR");
        uint256 funding = vm.envOr("REACT_FUNDING", uint256(0.25 ether));

        vm.startBroadcast();
        StopLossSentinelOmni sentinel = new StopLossSentinelOmni{ value: funding }(dex, vault);
        vm.stopBroadcast();

        console2.log("StopLossSentinelOmni:", address(sentinel));
        console2.log("funded with (wei):", funding);
    }
}
