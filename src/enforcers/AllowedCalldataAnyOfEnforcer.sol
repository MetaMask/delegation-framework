// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title AllowedCalldataAnyOfEnforcer
 * @dev Like `AllowedCalldataEnforcer`, but the delegator supplies several allowed byte sequences (`bytes[]`).
 * @dev At `dataStart`, the execution calldata must exactly match **at least one** of those sequences (each candidate is compared
 * over its full length, starting at `dataStart`).
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 * @dev Prefer static or fixed-layout regions of calldata; validating dynamic types remains possible but is more error-prone,
 * same as for `AllowedCalldataEnforcer`.
 */
contract AllowedCalldataAnyOfEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to restrict calldata so that one of several allowed slices matches at a fixed offset.
     * @dev For each candidate `v` in the decoded array, checks `callData[dataStart : dataStart + len(v)] == v`.
     * @param _terms Packed header plus ABI-encoded `bytes[]`:
     *   - the first 32 bytes: `uint256` start index in the execution call data (same layout as `AllowedCalldataEnforcer`)
     *   - the remainder: `abi.encode(bytes[])` where each element is a non-empty candidate byte string
     * @param _mode The execution mode. (Must be Single callType, Default execType)
     * @param _executionCallData The execution the delegate is trying to execute.
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
        _validateCalldata(_terms, _executionCallData);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms Encoded data used during the execution hooks.
     * @return dataStart_ The start index in the execution's call data.
     * @return values_ ABI-decoded array of candidate byte strings; each element must be at least one byte long.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 dataStart_, bytes[] memory values_) {
        require(_terms.length >= 32, "AllowedCalldataAnyOfEnforcer:invalid-terms-size");
        dataStart_ = uint256(bytes32(_terms[0:32]));
        values_ = abi.decode(_terms[32:], (bytes[]));
        require(values_.length > 0, "AllowedCalldataAnyOfEnforcer:no-allowed-values");
        for (uint256 i = 0; i < values_.length; ++i) {
            require(values_[i].length >= 1, "AllowedCalldataAnyOfEnforcer:invalid-value-length");
        }
    }

    /**
     * @notice Validates that the execution calldata matches one of the allowed slices at `dataStart`.
     * @param _terms Encoded terms (see `beforeHook`).
     * @param _executionCallData The encoded single execution payload.
     */
    function _validateCalldata(bytes calldata _terms, bytes calldata _executionCallData) private pure {
        (uint256 dataStart_, bytes[] memory values_) = getTermsInfo(_terms);
        (,, bytes calldata callData_) = _executionCallData.decodeSingle();

        bool matched_;
        uint256 n_ = values_.length;
        for (uint256 i = 0; i < n_; ++i) {
            bytes memory candidate_ = values_[i];
            uint256 len_ = candidate_.length;
            if (dataStart_ + len_ > callData_.length) {
                continue;
            }
            if (keccak256(callData_[dataStart_:dataStart_ + len_]) == keccak256(candidate_)) {
                matched_ = true;
                break;
            }
        }
        require(matched_, "AllowedCalldataAnyOfEnforcer:invalid-calldata");
    }
}
