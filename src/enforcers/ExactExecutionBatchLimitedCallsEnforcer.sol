// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title ExactExecutionBatchLimitedCallsEnforcer
 * @notice A gas-optimized caveat enforcer that BLENDS {ExactExecutionBatchEnforcer} and {LimitedCallsEnforcer} into a single
 *         `beforeHook`. In one external call it (1) pins the batch execution exactly (target, value, calldata of every
 *         execution) and (2) enforces a maximum number of redemptions of the delegation (replay / limited-calls). Using this
 *         one enforcer instead of the two separate caveats saves the manager a whole external call — and a cold account
 *         access — per redemption.
 *
 * @dev TERMS LAYOUT — `abi.encodePacked(uint256 limit, ExecutionLib.encodeBatch(Execution[] expectedExecutions))`:
 *        - `terms[0:32]` : the maximum number of redemptions (LimitedCalls semantics).
 *        - `terms[32:]`  : the expected batch encoding. For a batch-mode redemption `executionCallData` IS
 *                          `ExecutionLib.encodeBatch(Execution[])` (= `abi.encode(Execution[])`), so the exact-execution check
 *                          is a single keccak comparison of `terms[32:]` against `executionCallData` — no decode/re-encode.
 *
 * @dev Operates only in BATCH call type + DEFAULT execution mode (like {ExactExecutionBatchEnforcer}). A single-execution
 *      gasless action can use this enforcer by encoding it as a one-element batch.
 *
 * @dev Unlike {LimitedCallsEnforcer} it does NOT emit an `IncreasedCount` event (saves a LOG3, ~1.9k gas). The on-chain
 *      `callCounts` mapping remains the authoritative, queryable replay state.
 */
contract ExactExecutionBatchLimitedCallsEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    /// @dev Per-manager, per-delegation redemption counter (the authoritative, queryable replay state).
    mapping(address delegationManager => mapping(bytes32 delegationHash => uint256 count)) public callCounts;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Validates the batch execution matches exactly AND that the per-delegation call limit is not exceeded.
     * @param _terms `abi.encodePacked(uint256 limit, encodeBatch(Execution[] expectedExecutions))`.
     * @param _mode The execution mode (must be Batch callType, Default execType).
     * @param _executionCallData The batch execution calldata (`abi.encode(Execution[])`).
     * @param _delegationHash The hash of the delegation being redeemed (the replay-counter key).
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        virtual
        override
        onlyBatchCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        require(_terms.length >= 32, "ExactExecutionBatchLimitedCallsEnforcer:invalid-terms-length");

        // (1) Exact batch execution: the expected batch (`terms[32:]`) must byte-match the executionCallData. Both are
        //     `ExecutionLib.encodeBatch(Execution[])`, so byte equality is exactly batch equality (no decode/re-encode).
        require(
            keccak256(_terms[32:]) == keccak256(_executionCallData), "ExactExecutionBatchLimitedCallsEnforcer:invalid-execution"
        );

        // (2) Limited calls (replay): increment the per-(manager, delegation) counter and bound it by the limit (`terms[0:32]`).
        uint256 callCount_ = ++callCounts[msg.sender][_delegationHash];
        require(callCount_ <= uint256(bytes32(_terms[0:32])), "ExactExecutionBatchLimitedCallsEnforcer:limit-exceeded");
    }

    /**
     * @notice Decodes the terms into the call limit and the expected executions.
     * @param _terms The encoded terms (see {beforeHook}).
     * @return limit_ The maximum number of redemptions.
     * @return executions_ The expected batch of executions.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 limit_, Execution[] memory executions_) {
        require(_terms.length >= 32, "ExactExecutionBatchLimitedCallsEnforcer:invalid-terms-length");
        limit_ = uint256(bytes32(_terms[0:32]));
        executions_ = ExecutionLib.decodeBatch(_terms[32:]);
    }
}
