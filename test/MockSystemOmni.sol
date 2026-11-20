// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Minimal stand-in for the Omni system contract, etched at
///         0x8888…8888 in tests. Records subscriptions and callback requests.
contract MockSystemOmni {
    uint256 public subscriptionCount;
    uint256 public callbackCount;
    uint256 public lastChainId;
    address public lastRecipient;
    uint64 public lastGasLimit;
    bytes public lastPayload;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptionCount++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external { }

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external { }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackCount++;
        lastChainId = config_.chainId;
        lastRecipient = config_.recipient;
        lastGasLimit = config_.gasLimit;
        lastPayload = config_.payload;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable { }
}
