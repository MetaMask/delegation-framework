// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { Execution, ModeCode } from "../utils/Types.sol";
import { CALLTYPE_SINGLE, CALLTYPE_BATCH } from "../utils/Constants.sol";

/**
 * @title NoCalldataEnforcer
 * @dev This contract enforces that the execution has no calldata.
 * @dev This caveat enforcer only works when the execution is in single mode.
 */
contract NoCalldataEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to restrict the calldata that is executed
     * @dev This function enforces that the execution has no calldata.
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
            (,, bytes calldata callData_) = _executionCallData.decodeSingle();
            require(callData_.length == 0, "NoCalldataEnforcer:calldata-not-allowed");
        } else if (ModeLib.getCallType(_mode) == CALLTYPE_BATCH) {
            (Execution[] calldata executions_) = _executionCallData.decodeBatch();
            for (uint256 i = 0; i < executions_.length; i++) {
                require(executions_[i].callData.length == 0, "NoCalldataEnforcer:calldata-not-allowed");
            }
        } else {
            revert("NoCalldataEnforcer:invalid-calltype");
        }
    }
}
