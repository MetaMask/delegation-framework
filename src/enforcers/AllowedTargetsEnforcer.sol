// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { Action } from "../utils/Types.sol";

/**
 * @title AllowedTargetsEnforcer
 * @dev This contract enforces the allowed target addresses for a delegate.
 */
contract AllowedTargetsEnforcer is CaveatEnforcer {
    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to limit what addresses the delegate may call.
     * @dev This function enforces the allowed target addresses before the transaction is performed.
     * @param _terms A series of 20byte addresses, representing the addresses that the delegate is allowed to call.
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
        address targetAddress_ = _action.to;
        address[] memory allowedTargets_ = getTermsInfo(_terms);
        uint256 allowedTargetsLength_ = allowedTargets_.length;
        for (uint256 i = 0; i < allowedTargetsLength_; ++i) {
            if (targetAddress_ == allowedTargets_[i]) {
                return;
            }
        }
        revert("AllowedTargetsEnforcer:target-address-not-allowed");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return allowedTargets_ The allowed target addresses.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address[] memory allowedTargets_) {
        uint256 j = 0;
        uint256 termsLength_ = _terms.length;
        require(termsLength_ % 20 == 0, "AllowedTargetsEnforcer:invalid-terms-length");
        allowedTargets_ = new address[](termsLength_ / 20);
        for (uint256 i = 0; i < termsLength_; i += 20) {
            allowedTargets_[j] = address(bytes20(_terms[i:i + 20]));
            j++;
        }
    }
}
