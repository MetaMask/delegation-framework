// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Action } from "../../src/utils/Types.sol";

/**
 * @title MockFailureCaveatEnforcer
 * @dev This contract is a mock implementation of the ICaveatEnforcer interface for testing purposes.
 */
contract MockFailureCaveatEnforcer is ICaveatEnforcer {
    uint256 public beforeHookCallCount;

    /**
     * @dev Mocked implementation of the beforeHook function.
     * Increments the beforeHook call count.
     */
    function beforeHook(bytes calldata, bytes calldata, Action calldata, bytes32, address, address) external {
        beforeHookCallCount++;
    }

    /**
     * @dev Mocked implementation of the afterHook function.
     * Increments the afterHook call count.
     */
    function afterHook(bytes calldata, bytes calldata, Action calldata, bytes32, address, address) external pure {
        revert();
    }
}
