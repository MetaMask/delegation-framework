// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

/**
 * @title CallIntervalEnforcer
 * @notice Enforces a minimum interval between consecutive calls for a given delegation.
 * @dev This enforcer restricts the frequency at which a delegation can be used, by requiring a minimum time interval between calls.
 * The interval is specified in the `_terms` parameter as a `uint256` encoded in 32 bytes.
 * Only operates in the default execution mode.
 *
 * - The `beforeHook` checks that the required interval has passed since the last call for the given delegation.
 * - The interval is enforced per (delegationManager, delegationHash) pair.
 * - The `lastCallExecution` mapping tracks the last execution timestamp for each delegation.
 *
 * Example usage:
 *   - To allow a delegation to be used only once every 24 hours, set `_terms` to `uint256(86400)` encoded as 32 bytes.
 */
contract CallIntervalEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    /// @notice Tracks the last execution timestamp for each (delegationManager, delegationHash) pair.
    /// @dev delegationManager => delegationHash => last execution timestamp
    mapping(address delegationManager => mapping(bytes32 delegationHash => uint256 lastCallExecution)) public lastCallExecution;

    /**
     * @notice Checks that the minimum interval between calls has passed before allowing execution.
     * @dev Reverts if the interval has not elapsed since the last call for this delegation.
     * The msg.sender is expected to be the delegation manager address.
     * @param _terms Encoded as 32 bytes, representing the minimum interval in seconds between calls.
     * @param _mode The execution mode. Must be the default execution mode.
     * @param _delegationHash The hash of the delegation being enforced.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        (uint256 callInterval_) = getTermsInfo(_terms);

        uint256 lastCallExecutedAt_ = lastCallExecution[msg.sender][_delegationHash];

        if (callInterval_ > 0) {
            require((block.timestamp - lastCallExecutedAt_) > callInterval_, "CallIntervalEnforcer:early-delegation");
        }
        lastCallExecution[msg.sender][_delegationHash] = block.timestamp;
    }

    /**
     * @notice Decodes the interval from the `_terms` parameter.
     * @dev Expects `_terms` to be exactly 32 bytes, representing a uint256 interval in seconds.
     * @param _terms The encoded interval.
     * @return interval_ The minimum interval in seconds between calls.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 interval_) {
        require(_terms.length == 32, "CallIntervalEnforcer:invalid-terms-length");
        interval_ = uint256(bytes32(_terms));
    }
}
