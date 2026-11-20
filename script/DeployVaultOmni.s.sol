// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import "../src/StopLossVaultOmni.sol";

/// @notice Deploys StopLossVaultOmni on Base Sepolia.
///         Env: CALLBACK_PROXY (Omni proxy for Base Sepolia), CALLBACK_SENDER
///         (the reactive contract's Lasna address), DEX_ADDR, VAULT_FUNDING
///         (wei, default 0.003 ether — callback settlement funds).
contract DeployVaultOmni is Script {
    function run() external {
        address proxy = vm.envAddress("CALLBACK_PROXY");
        address sender = vm.envAddress("CALLBACK_SENDER");
        address dex = vm.envAddress("DEX_ADDR");
        uint256 funding = vm.envOr("VAULT_FUNDING", uint256(0.003 ether));

        vm.startBroadcast();
        StopLossVaultOmni vault = new StopLossVaultOmni{ value: funding }(
            IPayable(payable(proxy)), sender, dex
        );
        vm.stopBroadcast();

        console2.log("StopLossVaultOmni:", address(vault));
        console2.log("funded with (wei):", funding);
    }
}
