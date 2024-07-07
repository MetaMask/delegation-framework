// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ICaveatEnforcer } from "../interfaces/ICaveatEnforcer.sol";
import { Action } from "../utils/Types.sol";

/**
 * @title CaveatEnforcer
 * @dev This abstract contract enforces caveats before and after the execution of an action.
 */
abstract contract CaveatEnforcer is ICaveatEnforcer {
    /// @inheritdoc ICaveatEnforcer
    function beforeHook(bytes calldata, bytes calldata, Action calldata, bytes32, address, address) public virtual { }

    /// @inheritdoc ICaveatEnforcer
    function afterHook(bytes calldata, bytes calldata, Action calldata, bytes32, address, address) public virtual { }
}
