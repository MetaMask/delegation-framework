// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { Action } from "../utils/Types.sol";

/**
 * @title ValueLteEnforcer
 * @dev This contract extends the CaveatEnforcer contract. It provides functionality to enforce a specific value for the Action
 * being executed.
 */
contract ValueLteEnforcer is CaveatEnforcer {
    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to specify a maximum value of native tokens that the delegate can spend.
     * @param _terms - A uint256 value that the Action's value must be less than or equal to.
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
        uint256 value_ = getTermsInfo(_terms);
        require(_action.value <= value_, "ValueLteEnforcer:value-too-high");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return value_ The value that the Action's value must be less than or equal to.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 value_) {
        require(_terms.length == 32, "ValueLteEnforcer:invalid-terms-length");
        value_ = uint256(bytes32(_terms));
    }
}
