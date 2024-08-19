// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title AllowedCalldataEnforcer
 * @dev This contract enforces that some subset of the calldata to be executed matches the allowed subset of calldata.
 * @dev This caveat enforcer only works when the execution is in single mode.
 * @dev A common use case for this enforcer is enforcing function parameters. It's strongly recommended to use this enforcer for
 * validating static types and not dynamic types. Ensuring that dynamic types are correct can be done through a series of
 * AllowedCalldataEnforcer terms but this is tedious and error-prone.
 */
contract AllowedCalldataEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to restrict the calldata that is executed
     * @dev This function enforces that a subset of the calldata to be executed matches the allowed subset of calldata.
     * @param _terms This is packed bytes where:
     *   - the first 32 bytes is the start of the subset of calldata bytes
     *   - the remainder of the bytes is the expected value
     * @param _mode The execution mode for the execution.
     * @param _executionCallData The execution the delegate is trying try to execute.
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
        onlySingleExecutionMode(_mode)
    {
        // Ensure that the first two term values are valid and at least 1 byte for value_
        uint256 dataStart_;
        bytes memory value_;

        (,, bytes calldata callData_) = _executionCallData.decodeSingle();

        (dataStart_, value_) = getTermsInfo(_terms);
        uint256 valueLength_ = value_.length;
        require(dataStart_ + valueLength_ <= callData_.length, "AllowedCalldataEnforcer:invalid-calldata-length");

        require(_compare(callData_[dataStart_:dataStart_ + valueLength_], value_), "AllowedCalldataEnforcer:invalid-calldata");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return dataStart_ The start of the subset of calldata bytes.
     * @return value_ The expected value.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 dataStart_, bytes memory value_) {
        require(_terms.length >= 33, "AllowedCalldataEnforcer:invalid-terms-size");
        dataStart_ = uint256(bytes32(_terms[0:32]));
        value_ = _terms[32:];
    }

    /**
     * @dev Compares two byte arrays for equality.
     * @param _a The first byte array.
     * @param _b The second byte array.
     * @return A boolean indicating whether the byte arrays are equal.
     */
    function _compare(bytes memory _a, bytes memory _b) private pure returns (bool) {
        return keccak256(_a) == keccak256(_b);
    }
}
