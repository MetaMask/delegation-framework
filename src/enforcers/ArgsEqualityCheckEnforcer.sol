// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 *  * @title ArgsEqualityCheckEnforcer
 * @notice Ensures that the provided arguments (`args`) during delegation match the expected terms.
 * @dev This caveat enforcer is best used when redeeming delegations where the `delegate` is an immutable contract.
 * The contract can populate the `args` for this caveat when redeeming a delegation letting users restrict delegation
 * redemption to a when the result of an onchain computation matches the pre-determined `terms` of a delegation. For example,
 * if the contract sets the args to the users balance of ETH, the delegation will only be valid when that delegation matches
 * the amount set in the `terms`.
 * @dev This enforcer operates only in default execution mode.
 */
contract ArgsEqualityCheckEnforcer is CaveatEnforcer {
    ////////////////////////////// Events //////////////////////////////

    event DifferentArgsAndTerms(
        address indexed sender, address indexed redeemer, bytes32 indexed delegationHash, bytes terms, bytes args
    );
    ////////////////////////////// External Functions //////////////////////////////

    /**
     * @notice Enforces that the terms and args are the same
     * @param _terms Any terms that need to be compared against the args
     * @param _args Any args that need to be compared against the terms
     * @param _mode The execution mode. (Must be Default execType)
     * @param _delegationHash The hash of the delegation
     * @param _redeemer The address of the redeemer
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        if (keccak256(_terms) != keccak256(_args)) {
            emit DifferentArgsAndTerms(msg.sender, _redeemer, _delegationHash, _terms, _args);
            revert("ArgsEqualityCheckEnforcer:different-args-and-terms");
        }
    }
}
