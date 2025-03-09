// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { CaveatEnforcer } from "../../src/enforcers/CaveatEnforcer.sol";
import { ModeCode } from "../../src/utils/Types.sol";

/**
 * @title MockCaveatEnforcer
 * @dev This contract is a mock implementation of the CaveatEnforcer interface for testing purposes.
 */
contract MockCaveatEnforcer is CaveatEnforcer {
    uint256 public beforeHookCallCount;
    uint256 public afterHookCallCount;

    /**
     * @dev Mocked implementation of the beforeHook function.
     * Increments the beforeHook call count.
     */
    function beforeHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) public override {
        beforeHookCallCount++;
    }

    /**
     * @dev Mocked implementation of the afterHook function.
     * Increments the afterHook call count.
     */
    function afterHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) public override {
        afterHookCallCount++;
    }
}
