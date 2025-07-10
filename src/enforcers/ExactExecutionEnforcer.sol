// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title ExactExecutionEnforcer
 * @notice Ensures that the provided execution matches exactly with the expected execution (target, value, and calldata).
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 */
contract ExactExecutionEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Validates that the execution matches exactly with the expected execution.
     * @param _terms The encoded expected Execution.
     * @param _mode The execution mode. (Must be Single callType, Default execType)
     * @param _executionCallData The execution calldata.
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
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        _validateExecution(_terms, _executionCallData);
    }

    /**
     * @notice Extracts the expected execution from the provided terms.
     * @param _terms The encoded expected Execution.
     * @return execution_ The expected Execution.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (Execution memory execution_) {
        (execution_.target, execution_.value, execution_.callData) = _terms.decodeSingle();
    }

    /**
     * @notice Validates that the provided execution matches exactly with the expected execution.
     * @dev Compares the target address, value, and calldata of the execution against the expected execution terms.
     * @param _terms Encoded data representing the expected execution (target, value, and calldata).
     * @param _executionCallData The actual execution calldata to be validated.
     * @dev Reverts if any part of the execution (target, value, or calldata) does not match the expected terms.
     */
    function _validateExecution(bytes calldata _terms, bytes calldata _executionCallData) private pure {
        // Decode execution data
        (address execTarget_, uint256 execValue_, bytes calldata execCallData_) = _executionCallData.decodeSingle();

        require(
            address(bytes20(_terms[0:20])) == execTarget_ && uint256(bytes32(_terms[20:52])) == execValue_
                && keccak256(_terms[52:]) == keccak256(execCallData_),
            "ExactExecutionEnforcer:invalid-execution"
        );
    }
}
