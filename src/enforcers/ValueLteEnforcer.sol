// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ValueLteEnforcer
 * @dev This contract extends the CaveatEnforcer contract. It provides functionality to enforce a specific value for the Execution
 * being executed.
 * @dev This caveat enforcer only works when the execution is in single mode.
 */
contract ValueLteEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to specify a maximum value of native tokens that the delegate can spend.
     * @param _terms - A uint256 value that the Execution's value must be less than or equal to.
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
        (, uint256 value_,) = _executionCallData.decodeSingle();
        uint256 termsValue_ = getTermsInfo(_terms);
        require(value_ <= termsValue_, "ValueLteEnforcer:value-too-high");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return value_ The value that the Execution's value must be less than or equal to.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 value_) {
        require(_terms.length == 32, "ValueLteEnforcer:invalid-terms-length");
        value_ = uint256(bytes32(_terms));
    }
}
