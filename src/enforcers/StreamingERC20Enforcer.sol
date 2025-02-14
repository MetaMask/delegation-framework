// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title StreamingERC20Enforcer
 * @notice This contract enforces a streaming transfer limit for ERC20 tokens.
 *
 * How it works:
 *  - `maxAmount` is a hard cap on total tokens that can ever become available.
 *  - If `initialAmount` == 0, the allowance accumulates linearly from `startTime`
 *    at a rate of `amountPerSecond`.
 *  - If `initialAmount` > 0, then the allowance is unlocked in "chunks":
 *     - The first chunk (size = `initialAmount`) is available immediately at `startTime`.
 *     - Each subsequent chunk is also `initialAmount` in size, and becomes available
 *       after each `chunkDuration = (initialAmount / amountPerSecond)` seconds.
 *
 * @dev This caveat enforcer only works when the execution is in single mode (`ModeCode.Single`).
 */
contract StreamingERC20Enforcer is CaveatEnforcer {
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
        address token,
        uint256 initialAmount,
        uint256 maxAmount,
        uint256 amountPerSecond,
        uint256 startTime,
        uint256 spent,
        uint256 lastUpdateTimestamp
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Retrieves the current available allowance for a specific delegation.
     * @param _delegationHash The hash of the delegation being queried.
     * @param _delegationManager The address of the delegation manager.
     * @return availableAmount_ The number of tokens that are currently spendable
     * under this streaming allowance (capped by `maxAmount`).
     */
    function getAvailableAmount(
        bytes32 _delegationHash,
        address _delegationManager
    )
        external
        view
        returns (uint256 availableAmount_)
    {
        StreamingAllowance storage allowance = streamingAllowances[_delegationManager][_delegationHash];
        availableAmount_ = _getAvailableAmount(allowance);
    }

    /**
     * @notice Hook called before an ERC20 transfer is executed to enforce streaming limits.
     * @dev This function will revert if the transfer amount exceeds the available streaming allowance.
     * @param _terms 148 packed bytes where:
     * - 20 bytes: ERC20 token address.
     * - 32 bytes: initial amount.
     * - 32 bytes: max amount.
     * - 32 bytes: amount per second.
     * - 32 bytes: start time for the streaming allowance.
     * @param _mode The mode of the execution (must be `ModeCode.Single` for this enforcer).
     * @param _executionCallData The transaction the delegate might try to perform.
     * @param _delegationHash The hash of the delegation being operated on.
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
        onlySingleExecutionMode(_mode)
    {
        _validateAndConsumeAllowance(_terms, _executionCallData, _delegationHash, _redeemer);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms 148 packed bytes where:
     * - 20 bytes: ERC20 token address.
     * - 32 bytes: initial amount.
     * - 32 bytes: max amount.
     * - 32 bytes: amount per second.
     * - 32 bytes: start time for the streaming allowance.
     * @return token_ The address of the ERC20 token contract.
     * @return initialAmount_ The initial chunk size or 0 if purely linear
     * @return maxAmount_ The maximum total unlocked tokens (hard cap)
     * @return amountPerSecond_ The rate at which the allowance increases per second.
     * @return startTime_ The timestamp from which the allowance streaming begins.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (address token_, uint256 initialAmount_, uint256 maxAmount_, uint256 amountPerSecond_, uint256 startTime_)
    {
        require(_terms.length == 148, "StreamingERC20Enforcer:invalid-terms-length");

        token_ = address(bytes20(_terms[0:20]));
        initialAmount_ = uint256(bytes32(_terms[20:52]));
        maxAmount_ = uint256(bytes32(_terms[52:84]));
        amountPerSecond_ = uint256(bytes32(_terms[84:116]));
        startTime_ = uint256(bytes32(_terms[116:148]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Enforces the streaming allowance limit and updates `spent`.
     * @dev Reverts if the transfer amount exceeds the currently available allowance.
     *
     * @param _terms The encoded streaming terms: ERC20 token, initial amount, amount per second, and start time.
     * @param _executionCallData The transaction data specifying the target contract and call data. We expect
     * an `IERC20.transfer(address,uint256)` call here.
     * @param _delegationHash The hash of the delegation to which this transfer applies.
     * @return token_ The token address (extracted from `_terms`).
     * @return initialAmount_ The `initialAmount` set for this streaming allowance.
     * @return maxAmount_ The maximum amount that can be transferred.
     * @return amountPerSecond_ The streaming rate specified in `_terms`.
     * @return startTime_ The timestamp after which tokens become available.
     * @return spent_ The updated `spent` amount after applying this transfer.
     */
    function _validateAndConsumeAllowance(
        bytes calldata _terms,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _redeemer
    )
        private
        returns (
            address token_,
            uint256 initialAmount_,
            uint256 maxAmount_,
            uint256 amountPerSecond_,
            uint256 startTime_,
            uint256 spent_
        )
    {
        (address target_,, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(callData_.length == 68, "StreamingERC20Enforcer:invalid-execution-length");

        (token_, initialAmount_, maxAmount_, amountPerSecond_, startTime_) = getTermsInfo(_terms);

        require(maxAmount_ >= initialAmount_, "StreamingERC20Enforcer:invalid-max-amount");

        require(startTime_ > 0, "StreamingERC20Enforcer:invalid-zero-start-time");

        require(token_ == target_, "StreamingERC20Enforcer:invalid-contract");

        require(bytes4(callData_[0:4]) == IERC20.transfer.selector, "StreamingERC20Enforcer:invalid-method");

        StreamingAllowance storage allowance = streamingAllowances[msg.sender][_delegationHash];
        if (allowance.spent == 0) {
            // First use of this delegation
            allowance.initialAmount = initialAmount_;
            allowance.maxAmount = maxAmount_;
            allowance.amountPerSecond = amountPerSecond_;
            allowance.startTime = startTime_;
        }

        uint256 transferAmount_ = uint256(bytes32(callData_[36:68]));

        require(transferAmount_ <= _getAvailableAmount(allowance), "StreamingERC20Enforcer:allowance-exceeded");

        allowance.spent += transferAmount_;
        spent_ = allowance.spent;

        emit IncreasedSpentMap(
            msg.sender,
            _redeemer,
            _delegationHash,
            token_,
            initialAmount_,
            maxAmount_,
            amountPerSecond_,
            startTime_,
            spent_,
            block.timestamp
        );
    }

    /**
     * @notice Calculates the available allowance for a given StreamingAllowance state.
     * @dev Computes the remaining allowance based on elapsed time, initial amount, and spent tokens
     * then clamps by `maxAmount`.
     * @param allowance The StreamingAllowance struct containing allowance details.
     * @return A uint256 representing how many tokens are currently available to spend.
     */
    function _getAvailableAmount(StreamingAllowance storage allowance) internal view returns (uint256) {
        if (block.timestamp < allowance.startTime) return 0;

        uint256 elapsed_ = block.timestamp - allowance.startTime;

        // If `initialAmount` == 0, do purely linear streaming
        if (allowance.initialAmount == 0) return _computeLinearAllowance(allowance, elapsed_);

        require(allowance.amountPerSecond > 0, "StreamingERC20Enforcer:zero-amount-per-second");

        // If the user wants chunks, ensure the initial amount is large enough
        // that `chunkDuration` won't be zero.
        require(allowance.initialAmount >= allowance.amountPerSecond, "StreamingERC20Enforcer:initial-amount-is-too-low");

        // Calculate how many chunks have fully unlocked
        uint256 chunkDuration_ = allowance.initialAmount / allowance.amountPerSecond;
        uint256 chunksUnlocked_ = elapsed_ / chunkDuration_;

        // The first chunk is unlocked immediately at `startTime`,
        uint256 totalUnlocked_ = (chunksUnlocked_ + 1) * allowance.initialAmount;

        // clamp by maxAmount
        if (totalUnlocked_ > allowance.maxAmount) {
            totalUnlocked_ = allowance.maxAmount;
        }

        if (allowance.spent >= totalUnlocked_) return 0;

        return totalUnlocked_ - allowance.spent;
    }

    /**
     * @notice Computes the unlocked amount using a purely linear model:
     *         `initialAmount + (amountPerSecond * elapsed)`, then clamps by `maxAmount`.
     *
     * @dev This function is called when `initialAmount == 0`, or as a fallback
     *      if chunk-based logic is not feasible.
     *
     * @param allowance The StreamingAllowance containing the streaming parameters.
     * @param elapsed_  How many seconds have passed since `startTime`.
     * @return The number of tokens currently available after subtracting `spent`.
     */
    function _computeLinearAllowance(StreamingAllowance storage allowance, uint256 elapsed_) private view returns (uint256) {
        uint256 totalSoFar_ = allowance.initialAmount + (allowance.amountPerSecond * elapsed_);

        // clamp to maxAmount
        if (totalSoFar_ > allowance.maxAmount) {
            totalSoFar_ = allowance.maxAmount;
        }

        if (allowance.spent >= totalSoFar_) return 0;

        return totalSoFar_ - allowance.spent;
    }
}
