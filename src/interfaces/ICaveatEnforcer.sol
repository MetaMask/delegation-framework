// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ModeCode } from "../utils/Types.sol";

/**
 * @title CaveatEnforcer
 * @notice This is an abstract contract that exposes pre and post Execution hooks during delegation redemption.
 * @dev Hooks can be used to enforce conditions before and after an Execution is performed.
 * @dev Reverting during the hooks will revert the entire delegation redemption.
 * @dev Child contracts can implement the beforeHook method and/or afterHook method.
 * @dev NOTE: There is no guarantee that the execution is executed. If you are relying on the execution then be sure to use the
 * `afterHook` method.
 */
interface ICaveatEnforcer {
    /**
     * @notice Enforces the conditions that should hold before a transaction is performed.
     * @dev This function MUST revert if the conditions are not met.
     * @param _terms The terms to enforce set by the delegator.
     * @param _args An optional input parameter set by the redeemer at time of invocation.
     * @param _mode The mode of execution for the executionCalldata.
     * @param _executionCalldata The data representing the execution.
     * @param _delegationHash The hash of the delegation.
     * @param _delegator The address of the delegator.
     * @param _redeemer The address that is redeeming the delegation.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata _executionCalldata,
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
     * @param _mode The mode of execution for the executionCalldata.
     * @param _executionCalldata The data representing the execution.
     * @param _delegationHash The hash of the delegation.
     * @param _delegator The address of the delegator.
     * @param _redeemer The address that is redeeming the delegation.
     */
    function afterHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata _executionCalldata,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        external;
}
