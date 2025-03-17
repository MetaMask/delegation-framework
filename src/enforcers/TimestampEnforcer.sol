// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title Timestamp Enforcer Contract
 * @dev This contract extends the CaveatEnforcer contract. It provides functionality to enforce timestamp restrictions on
 * delegations.
 * @dev This enforcer operates only in default execution mode.
 */
contract TimestampEnforcer is CaveatEnforcer {
    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to specify the timestamp range within which the delegation will be valid.
     * @param _terms - A bytes32 timestamp range where the first half of the word is the earliest the delegation can be used and the
     * last half of the word is the latest the delegation can be used. The timestamp ranges are not inclusive.
     * @param _mode The execution mode. (Must be Default execType)
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        view
        override
        onlyDefaultExecutionMode(_mode)
    {
        (uint128 timestampAfterThreshold_, uint128 timestampBeforeThreshold_) = getTermsInfo(_terms);

        if (timestampAfterThreshold_ > 0) {
            // this means there has been a timestamp set for after which the delegation can be used
            require(block.timestamp > timestampAfterThreshold_, "TimestampEnforcer:early-delegation");
        }

        if (timestampBeforeThreshold_ > 0) {
            // this means there has been a timestamp set for before which the delegation can be used
            require(block.timestamp < timestampBeforeThreshold_, "TimestampEnforcer:expired-delegation");
        }
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return timestampAfterThreshold_ The earliest timestamp before which the delegation can be used.
     * @return timestampBeforeThreshold_ The latest timestamp after which the delegation can be used.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (uint128 timestampAfterThreshold_, uint128 timestampBeforeThreshold_)
    {
        require(_terms.length == 32, "TimestampEnforcer:invalid-terms-length");
        timestampBeforeThreshold_ = uint128(bytes16(_terms[16:]));
        timestampAfterThreshold_ = uint128(bytes16(_terms[:16]));
    }
}
