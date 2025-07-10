// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title NativeTokenStreamingEnforcer
 * @notice This contract enforces a linear streaming limit for native tokens.
 *
 * How it works:
 *  1. Nothing is available before `startTime`.
 *  2. At `startTime`, `initialAmount` becomes immediately available.
 *  3. After `startTime`, tokens accrue linearly at `amountPerSecond`.
 *  4. The total unlocked is capped by `maxAmount`.
 *  5. The contract tracks how many native tokens have been spent and will revert
 *     if an attempted transfer (i.e. the value sent) exceeds what remains unlocked.
 *
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 * @dev To enable an 'infinite' token stream, set `maxAmount` to type(uint256).max
 */
contract NativeTokenStreamingEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// State //////////////////////////////

    struct StreamingAllowance {
        uint256 initialAmount;
        uint256 maxAmount;
        uint256 amountPerSecond;
        uint256 startTime;
        uint256 spent;
    }

    /**
     * @dev Maps a delegation manager address and delegation hash to a StreamingAllowance.
     */
    mapping(address delegationManager => mapping(bytes32 delegationHash => StreamingAllowance)) public streamingAllowances;

    ////////////////////////////// Events //////////////////////////////

    event IncreasedSpentMap(
        address indexed sender,
        address indexed redeemer,
        bytes32 indexed delegationHash,
        uint256 initialAmount,
        uint256 maxAmount,
        uint256 amountPerSecond,
        uint256 startTime,
        uint256 spent,
        uint256 lastUpdateTimestamp
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Retrieves the current available allowance for a given delegation.
     * @param _delegationManager The delegation manager address.
     * @param _delegationHash The hash of the delegation.
     * @return availableAmount_ The native token amount available (capped by `maxAmount`).
     */
    function getAvailableAmount(
        address _delegationManager,
        bytes32 _delegationHash
    )
        external
        view
        returns (uint256 availableAmount_)
    {
        StreamingAllowance storage allowance_ = streamingAllowances[_delegationManager][_delegationHash];
        availableAmount_ = _getAvailableAmount(allowance_);
    }

    /**
     * @notice Hook called before a native token transfer to enforce streaming limits.
     * @dev Reverts if the native token value exceeds the currently unlocked amount.
     * @param _terms 128 packed bytes where:
     * - 32 bytes: initial amount.
     * - 32 bytes: max amount.
     * - 32 bytes: amount per second.
     * - 32 bytes: start time for the streaming allowance.
     * @param _mode The execution mode. (Must be Single callType, Default execType)
     * @param _executionCallData The execution data which, when decoded via ExecutionLib.decodeSingle(),
     *        yields (target, value, callData). Here, the `value` is the native token amount.
     * @param _delegationHash The hash of the delegation being operated on.
     * @param _redeemer The address of the redeemer.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        _validateAndConsumeAllowance(_terms, _executionCallData, _delegationHash, _redeemer);
    }

    /**
     * @notice Decodes the streaming terms.
     * @param _terms 128 packed bytes:
     * - 32 bytes: initial amount.
     * - 32 bytes: max amount.
     * - 32 bytes: amount per second.
     * - 32 bytes: start time for the streaming allowance.
     * @return initialAmount_ The immediate native token amount available at startTime.
     * @return maxAmount_ The hard cap on total native tokens that can be unlocked.
     * @return amountPerSecond_ The rate at which the allowance increases per second.
     * @return startTime_ The timestamp from which the allowance streaming begins.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (uint256 initialAmount_, uint256 maxAmount_, uint256 amountPerSecond_, uint256 startTime_)
    {
        require(_terms.length == 128, "NativeTokenStreamingEnforcer:invalid-terms-length");

        initialAmount_ = uint256(bytes32(_terms[0:32]));
        maxAmount_ = uint256(bytes32(_terms[32:64]));
        amountPerSecond_ = uint256(bytes32(_terms[64:96]));
        startTime_ = uint256(bytes32(_terms[96:128]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Validates the native token streaming allowance and increments `spent`.
     * @dev Reverts if the native token value exceeds what is available.
     * @param _terms Encoded streaming terms.
     * @param _executionCallData When decoded, yields (target, value, callData). The `value` is the native token amount.
     * @param _delegationHash The hash of the delegation to which this transfer applies.
     * @param _redeemer The address of the redeemer.
     */
    function _validateAndConsumeAllowance(
        bytes calldata _terms,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _redeemer
    )
        private
    {
        (, uint256 value_,) = _executionCallData.decodeSingle();

        (uint256 initialAmount_, uint256 maxAmount_, uint256 amountPerSecond_, uint256 startTime_) = getTermsInfo(_terms);

        require(maxAmount_ >= initialAmount_, "NativeTokenStreamingEnforcer:invalid-max-amount");
        require(startTime_ > 0, "NativeTokenStreamingEnforcer:invalid-zero-start-time");

        StreamingAllowance storage allowance_ = streamingAllowances[msg.sender][_delegationHash];
        if (allowance_.spent == 0) {
            // First use of this delegation
            allowance_.initialAmount = initialAmount_;
            allowance_.maxAmount = maxAmount_;
            allowance_.amountPerSecond = amountPerSecond_;
            allowance_.startTime = startTime_;
        }

        require(value_ <= _getAvailableAmount(allowance_), "NativeTokenStreamingEnforcer:allowance-exceeded");

        allowance_.spent += value_;

        emit IncreasedSpentMap(
            msg.sender,
            _redeemer,
            _delegationHash,
            initialAmount_,
            maxAmount_,
            amountPerSecond_,
            startTime_,
            allowance_.spent,
            block.timestamp
        );
    }

    /**
     * @notice Calculates how many tokens are currently unlocked in total, then subtracts `spent`, then clamps by `maxAmount`.
     * @param _allowance The StreamingAllowance struct containing allowance details.
     * @return A uint256 representing how many tokens are currently available to spend.
     */
    function _getAvailableAmount(StreamingAllowance memory _allowance) private view returns (uint256) {
        if (block.timestamp < _allowance.startTime) return 0;

        uint256 elapsed_ = block.timestamp - _allowance.startTime;
        uint256 unlocked_ = _allowance.initialAmount + (_allowance.amountPerSecond * elapsed_);

        if (unlocked_ > _allowance.maxAmount) {
            unlocked_ = _allowance.maxAmount;
        }

        if (_allowance.spent >= unlocked_) return 0;

        return unlocked_ - _allowance.spent;
    }
}
