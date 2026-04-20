// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title AllowedCalldataAnyOfEnforcer
 * @dev Like `AllowedCalldataEnforcer`, but the delegator supplies several allowed byte sequences of **equal length**.
 * @dev At `startIndex`, the execution calldata must exactly match **at least one** of those sequences (each candidate is compared
 * over `valueLength` bytes, starting at `startIndex`).
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 * @dev Prefer static or fixed-layout regions of calldata; validating dynamic types remains possible but is more error-prone,
 * same as for `AllowedCalldataEnforcer`.
 */
contract AllowedCalldataAnyOfEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to restrict calldata so that one of several equal-length slices matches at a fixed offset.
     * @dev For each candidate, checks `callData[startIndex : startIndex + valueLength] == candidate`.
     * @param _terms Binary layout:
     *   - **First 32 bytes:** `uint128 startIndex` (high 128 bits) | `uint128 valueLength` (low 128 bits) of one big-endian word.
     *   - **Remainder:** `candidateCount` candidates concatenated, each exactly `valueLength` bytes (so `len(remainder) == candidateCount * valueLength`).
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
     * @notice Decodes and validates the terms used in this CaveatEnforcer.
     * @dev After reading `valueLength` from the header word, requires `valueLength >= 1`, a non-empty remainder, and that the
     * remainder length is a multiple of `valueLength`.
     * @param _terms Encoded data used during the execution hooks.
     * @return startIndex_ Start index in the execution's call data.
     * @return valueLength_ Length of every candidate slice and of the compared execution calldata window.
     * @return candidateCount_ Number of candidates in the concatenated tail (`(len(_terms) - 32) / valueLength_`).
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (uint128 startIndex_, uint128 valueLength_, uint256 candidateCount_)
    {
        require(_terms.length > 32, "AllowedCalldataAnyOfEnforcer:invalid-terms-size");
        uint256 metadataWord_ = uint256(bytes32(_terms[0:32]));
        startIndex_ = uint128(metadataWord_ >> 128);
        valueLength_ = uint128(metadataWord_);

        require(valueLength_ >= 1, "AllowedCalldataAnyOfEnforcer:invalid-value-length");

        uint256 concatenatedValuesLength_ = _terms.length - 32;
        require(concatenatedValuesLength_ != 0, "AllowedCalldataAnyOfEnforcer:no-allowed-values");
        require(concatenatedValuesLength_ % uint256(valueLength_) == 0, "AllowedCalldataAnyOfEnforcer:invalid-values-padding");

        candidateCount_ = concatenatedValuesLength_ / uint256(valueLength_);
    }

    /**
     * @notice Validates that the execution calldata matches one of the allowed slices at `startIndex`.
     * @param _terms Encoded terms (see `beforeHook`).
     * @param _executionCallData The encoded single execution payload.
     */
    function _validateCalldata(bytes calldata _terms, bytes calldata _executionCallData) private pure {
        (uint128 startIndex_, uint128 valueLength_, uint256 candidateCount_) = getTermsInfo(_terms);

        uint256 dataStart_ = uint256(startIndex_);
        uint256 lengthToMatch_ = uint256(valueLength_);
        (,, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(dataStart_ + lengthToMatch_ <= callData_.length, "AllowedCalldataAnyOfEnforcer:invalid-calldata-length");

        bytes calldata callDataToMatch_ = callData_[dataStart_:dataStart_ + lengthToMatch_];

        bool matched_;
        for (uint256 i = 0; i < candidateCount_; ++i) {
            uint256 offset_ = 32 + i * lengthToMatch_;
            if (callDataToMatch_ == _terms[offset_:offset_ + lengthToMatch_]) {
                matched_ = true;
                break;
            }
        }
        require(matched_, "AllowedCalldataAnyOfEnforcer:invalid-calldata");
    }
}
