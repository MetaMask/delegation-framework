// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title ExactCalldataBatchEnforcer
 * @notice Ensures that each batch execution matches the terms Execution (target, value, and calldata).
 * @dev Terms are encoded as Execution[]. Calldata-only comparison would leave target and value
 *      unconstrained despite being present in terms. Operates only in batch + default execution mode.
 */
contract ExactCalldataBatchEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Validates that each execution in the batch matches the expected target, value, and calldata.
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

        // Validate that the number of executions matches the number of expected calldata
        require(executions_.length == termsExecutions_.length, "ExactCalldataBatchEnforcer:invalid-batch-size");

        // Terms encode full Execution[]; enforce target and value as well as calldata so a
        // redeemer cannot swap the token (or attach ETH) while reusing identical calldata.
        for (uint256 i = 0; i < executions_.length; i++) {
            require(executions_[i].target == termsExecutions_[i].target, "ExactCalldataBatchEnforcer:invalid-target");
            require(executions_[i].value == termsExecutions_[i].value, "ExactCalldataBatchEnforcer:invalid-value");
            require(
                keccak256(termsExecutions_[i].callData) == keccak256(executions_[i].callData),
                "ExactCalldataBatchEnforcer:invalid-calldata"
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
