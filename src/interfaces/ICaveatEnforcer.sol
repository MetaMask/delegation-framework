// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Action } from "../utils/Types.sol";

/**
 * @title CaveatEnforcer
 * @notice This is an abstract contract that exposes pre and post Action hooks during delegation redemption.
 * @dev Hooks can be used to enforce conditions before and after an Action is performed.
 * @dev Reverting during the hooks will revert the entire delegation redemption.
 * @dev Child contracts can implement the beforeHook method and/or afterHook method.
 * @dev NOTE: There is no guarantee that the action is executed. If you are relying on the action then be sure to use the
 * `afterHook` method.
 */
interface ICaveatEnforcer {
    /**
     * @notice Enforces the conditions that should hold before a transaction is performed.
     * @dev This function MUST revert if the conditions are not met.
     * @param _terms The terms to enforce set by the delegator.
     * @param _args An optional input parameter set by the redeemer at time of invocation.
     * @param _action The action of the transaction.
     * @param _delegationHash The hash of the delegation.
     * @param _delegator The address of the delegator.
     * @param _redeemer The address that is redeeming the delegation.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        Action calldata _action,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        external;

    /**
     * @notice Enforces the conditions that should hold after a transaction is performed.
     * @dev This function MUST revert if the conditions are not met.
     * @param _terms The terms to enforce set by the delegator.
     * @param _args An optional input parameter set by the redeemer at time of invocation.
     * @param _action The action of the transaction.
     * @param _delegationHash The hash of the delegation.
     * @param _delegator The address of the delegator.
     * @param _redeemer The address that is redeeming the delegation.
     */
    function afterHook(
        bytes calldata _terms,
        bytes calldata _args,
        Action calldata _action,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        external;
}
