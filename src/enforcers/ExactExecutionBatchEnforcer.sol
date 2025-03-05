// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title ExactExecutionBatchEnforcer
 * @notice Ensures that each execution in the batch matches exactly with the expected execution (target, value, and calldata).
 * @dev This caveat enforcer operates only in batch execution mode.
 */
contract ExactExecutionBatchEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Validates that each execution in the batch matches exactly with the expected execution.
     * @param _terms The encoded expected Executions.
     * @param _mode The execution mode, which must be batch.
     * @param _executionCallData The batch execution calldata.
     */
    function beforeHook(
        bytes calldata _terms,
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
        onlyBatchExecutionMode(_mode)
    {
        Execution[] calldata executions_ = _executionCallData.decodeBatch();
        Execution[] memory termsExecutions_ = getTermsInfo(_terms);

        // Validate that the number of executions matches
        require(executions_.length == termsExecutions_.length, "ExactExecutionBatchEnforcer:invalid-batch-size");

        // Check each execution matches exactly (target, value, and calldata)
        for (uint256 i = 0; i < executions_.length; i++) {
            require(
                termsExecutions_[i].target == executions_[i].target && termsExecutions_[i].value == executions_[i].value
                    && keccak256(termsExecutions_[i].callData) == keccak256(executions_[i].callData),
                "ExactExecutionBatchEnforcer:invalid-execution"
            );
        }
    }

    /**
     * @notice Extracts the expected executions from the provided terms.
     * @param _terms The encoded expected Executions.
     * @return executions_ Array of expected Executions.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (Execution[] memory executions_) {
        executions_ = _terms.decodeBatch();
    }
}
