// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { Execution, ModeCode } from "../utils/Types.sol";
import { CALLTYPE_SINGLE, CALLTYPE_BATCH } from "../utils/Constants.sol";

/**
 * @title NoValueEnforcer
 * @dev This contract enforces that the execution has no value.
 * @dev This caveat enforcer only works when the execution is in single mode.
 */
contract NoValueEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to restrict the value that is executed
     * @dev This function enforces that the execution has no value.
     * @param _mode The execution mode for the execution.
     * @param _executionCallData The execution the delegate is trying try to execute.
     */
    function beforeHook(
        bytes calldata,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32,
        address,
        address
    )
        public
        pure
        override
    {
        if (ModeLib.getCallType(_mode) == CALLTYPE_SINGLE) {
            (, uint256 value_,) = _executionCallData.decodeSingle();
            require(value_ == 0, "NoValueEnforcer:value-not-allowed");
        } else if (ModeLib.getCallType(_mode) == CALLTYPE_BATCH) {
            (Execution[] calldata executions_) = _executionCallData.decodeBatch();
            for (uint256 i = 0; i < executions_.length; i++) {
                require(executions_[i].value == 0, "NoValueEnforcer:value-not-allowed");
            }
        } else {
            revert("NoValueEnforcer:invalid-calltype");
        }
    }
}
