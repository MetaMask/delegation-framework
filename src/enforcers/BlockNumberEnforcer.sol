// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title BlockNumberEnforcer
 * @dev This contract enforces the block number range for a delegation.
 * @dev This enforcer operates only in default execution mode.
 */
contract BlockNumberEnforcer is CaveatEnforcer {
    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to specify the block number range within which the delegation will be valid.
     * @dev This function enforces the block number range before the transaction is performed.
     * @param _terms A bytes32 blocknumber range where the first half of the word is the earliest the delegation can be used and
     * the last half of the word is the latest the delegation can be used. The block number ranges are not inclusive.
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
        (uint128 blockAfterThreshold_, uint128 blockBeforeThreshold_) = getTermsInfo(_terms);

        if (blockAfterThreshold_ > 0) {
            // this means there has been a after blocknumber set for which the delegation must be used
            require(block.number > blockAfterThreshold_, "BlockNumberEnforcer:early-delegation");
        }

        if (blockBeforeThreshold_ > 0) {
            // this means there has been a before blocknumber set for which the delegation must be used
            require(block.number < blockBeforeThreshold_, "BlockNumberEnforcer:expired-delegation");
        }
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return blockAfterThreshold_ The earliest block number before which the delegation can be used.
     * @return blockBeforeThreshold_ The latest block number after which the delegation can be used.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (uint128 blockAfterThreshold_, uint128 blockBeforeThreshold_)
    {
        require(_terms.length == 32, "BlockNumberEnforcer:invalid-terms-length");
        blockAfterThreshold_ = uint128(bytes16(_terms[:16]));
        blockBeforeThreshold_ = uint128(bytes16(_terms[16:]));
    }
}
