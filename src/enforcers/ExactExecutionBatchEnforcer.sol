// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title ExactExecutionBatchEnforcer
 * @notice Ensures that each execution in the batch matches exactly with the expected execution (target, value, and calldata).
 * @dev This enforcer operates only in batch execution call type and with default execution mode.
 */
contract ExactExecutionBatchEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Validates that each execution in the batch matches exactly with the expected execution.
     * @param _terms The encoded expected Executions.
     * @param _mode The execution mode. (Must be Batch callType, Default execType)
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
        onlyBatchCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        Execution[] calldata executions_ = _executionCallData.decodeBatch();
        Execution[] memory termsExecutions_ = getTermsInfo(_terms);

        // Validate that the number of executions matches
        require(executions_.length == termsExecutions_.length, "ExactExecutionBatchEnforcer:invalid-batch-size");

        // Encode both sets of executions and compare the hashes
        require(
            keccak256(abi.encode(executions_)) == keccak256(abi.encode(termsExecutions_)),
            "ExactExecutionBatchEnforcer:invalid-execution"
        );
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
