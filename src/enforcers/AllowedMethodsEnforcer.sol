// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { Action } from "../utils/Types.sol";

/**
 * @title AllowedMethodsEnforcer
 * @dev This contract enforces the allowed methods a delegate may call.
 */
contract AllowedMethodsEnforcer is CaveatEnforcer {
    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to limit what methods the delegate may call.
     * @dev This function enforces the allowed methods before the transaction is performed.
     * @param _terms A series of 4byte method identifiers, representing the methods that the delegate is allowed to call.
     * @param _action The transaction the delegate might try to perform.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        Action calldata _action,
        bytes32,
        address,
        address
    )
        public
        pure
        override
    {
        require(_action.data.length >= 4, "AllowedMethodsEnforcer:invalid-action-data-length");

        bytes4 targetSig_ = bytes4(_action.data[0:4]);
        bytes4[] memory allowedSignatures_ = getTermsInfo(_terms);
        uint256 allowedSignaturesLength_ = allowedSignatures_.length;

        for (uint256 i = 0; i < allowedSignaturesLength_; ++i) {
            if (targetSig_ == allowedSignatures_[i]) {
                return;
            }
        }
        revert("AllowedMethodsEnforcer:method-not-allowed");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return allowedMethods_ The 4 byte identifiers for the methods that the delegate is allowed to call.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (bytes4[] memory allowedMethods_) {
        uint256 j = 0;
        uint256 termsLength_ = _terms.length;
        require(termsLength_ % 4 == 0, "AllowedMethodsEnforcer:invalid-terms-length");
        allowedMethods_ = new bytes4[](termsLength_ / 4);
        for (uint256 i = 0; i < termsLength_; i += 4) {
            allowedMethods_[j] = bytes4(_terms[i:i + 4]);
            j++;
        }
    }
}
