// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title RedeemerEnforcer
 * @dev This contract restricts the addresses that can redeem delegations.
 * Specifically designed for smart contracts or EOAs lacking delegation support.
 * @dev DeleGator accounts with delegation functionalities may bypass these restrictions by delegating to other addresses.
 * @dev This enforcer operates only in default execution mode.
 */
contract RedeemerEnforcer is CaveatEnforcer {
    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to limit which addresses can redeem the delegation.
     * @param _terms Encoded 20-byte addresses of the allowed redeemers.
     * @param _mode The execution mode. (Must be Default execType)
     * @param _redeemer The address attempting to redeem the delegation.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address,
        address _redeemer
    )
        public
        pure
        override
        onlyDefaultExecutionMode(_mode)
    {
        address[] memory allowedRedeemers_ = getTermsInfo(_terms);
        uint256 allowedRedeemersLength_ = allowedRedeemers_.length;
        for (uint256 i = 0; i < allowedRedeemersLength_; ++i) {
            if (_redeemer == allowedRedeemers_[i]) return;
        }
        revert("RedeemerEnforcer:unauthorized-redeemer");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms Encoded 20-byte addresses of the allowed redeemers.
     * @return allowedRedeemers_ Array containing the allowed redeemer addresses.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address[] memory allowedRedeemers_) {
        uint256 j = 0;
        uint256 termsLength_ = _terms.length;
        require(termsLength_ > 0 && termsLength_ % 20 == 0, "RedeemerEnforcer:invalid-terms-length");
        allowedRedeemers_ = new address[](termsLength_ / 20);
        for (uint256 i = 0; i < termsLength_; i += 20) {
            allowedRedeemers_[j] = address(bytes20(_terms[i:i + 20]));
            j++;
        }
    }
}
