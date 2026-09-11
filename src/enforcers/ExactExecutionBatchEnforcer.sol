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
        _validateBatch(_terms, _executionCallData);
    }

    /**
     * @notice Validates that the batch execution matches the expected batch exactly.
     * @dev `_terms` and `_executionCallData` are both `ExecutionLib.encodeBatch(Execution[])` (= `abi.encode(Execution[])`), so
     *      byte equality is exactly batch equality. Decode only to surface the dedicated batch-size error; compare content via a
     *      single keccak over the raw calldata (avoids re-encoding both arrays into memory). Isolated into its own function to
     *      keep the 7-arg `beforeHook` stack shallow.
     */
    function _validateBatch(bytes calldata _terms, bytes calldata _executionCallData) private pure {
        Execution[] calldata executions_ = _executionCallData.decodeBatch();
        Execution[] calldata termsExecutions_ = _terms.decodeBatch();

        require(executions_.length == termsExecutions_.length, "ExactExecutionBatchEnforcer:invalid-batch-size");
        require(keccak256(_executionCallData) == keccak256(_terms), "ExactExecutionBatchEnforcer:invalid-execution");
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
