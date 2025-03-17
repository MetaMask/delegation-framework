// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title AllowedMethodsEnforcer
 * @dev This contract enforces the allowed methods a delegate may call.
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 */
contract AllowedMethodsEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to limit what methods the delegate may call.
     * @dev This function enforces the allowed methods before the transaction is performed.
     * @param _terms A series of 4byte method identifiers, representing the methods that the delegate is allowed to call.
     * @param _mode The execution mode. (Must be Single callType, Default execType)
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
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        _validateMethods(_terms, _executionCallData);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return allowedMethods_ The 4 byte identifiers for the methods that the delegate is allowed to call.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (bytes4[] memory allowedMethods_) {
        uint256 j = 0;
        uint256 termsLength_ = _terms.length;
        require(termsLength_ % 4 == 0 && termsLength_ != 0, "AllowedMethodsEnforcer:invalid-terms-length");
        allowedMethods_ = new bytes4[](termsLength_ / 4);
        for (uint256 i = 0; i < termsLength_; i += 4) {
            allowedMethods_[j] = bytes4(_terms[i:i + 4]);
            j++;
        }
    }

    /**
     * @notice Validates that the method being called is within the allowed set.
     * @dev Extracts the function selector from the execution calldata and checks if it is present
     *      in the allowed methods specified in `_terms`.
     * @param _terms Encoded data containing the allowed method selectors (4-byte function identifiers).
     * @param _executionCallData The calldata of the function execution to be validated.
     * @dev Reverts if the function selector is not in the allowed list.
     */
    function _validateMethods(bytes calldata _terms, bytes calldata _executionCallData) private pure {
        (,, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(callData_.length >= 4, "AllowedMethodsEnforcer:invalid-execution-data-length");

        bytes4 targetSig_ = bytes4(callData_[0:4]);
        bytes4[] memory allowedSignatures_ = getTermsInfo(_terms);
        uint256 allowedSignaturesLength_ = allowedSignatures_.length;

        for (uint256 i = 0; i < allowedSignaturesLength_; ++i) {
            if (targetSig_ == allowedSignatures_[i]) {
                return;
            }
        }
        revert("AllowedMethodsEnforcer:method-not-allowed");
    }
}
