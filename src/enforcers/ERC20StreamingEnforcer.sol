// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC20StreamingEnforcer
 * @notice This contract enforces a linear streaming transfer limit for ERC20 tokens.
 *
 * How it works:
 *  1. Nothing is available before `startTime`.
 *  2. Starting at `startTime`, `initialAmount` becomes immediately available.
 *  3. Beyond that, tokens accrue linearly at `amountPerSecond`.
 *  4. The total unlocked is capped by `maxAmount`.
 *  5. The enforcer tracks how many tokens have already been spent, and will revert
 *     if an attempted transfer exceeds what remains unlocked.
 *
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 * @dev To enable an 'infinite' token stream, set `maxAmount` to type(uint256).max
 */
contract ERC20StreamingEnforcer is CaveatEnforcer {
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
     * @param _delegationManager The address of the delegation manager.
     * @param _delegationHash The hash of the delegation being queried.
     * @return availableAmount_ The number of tokens that are currently spendable
     * under this streaming allowance (capped by `maxAmount`).
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
     * @notice Hook called before an ERC20 transfer is executed to enforce streaming limits.
     * @dev This function will revert if the transfer amount exceeds the available streaming allowance.
     * @param _terms 148 packed bytes where:
     * - 20 bytes: ERC20 token address.
     * - 32 bytes: initial amount.
     * - 32 bytes: max amount.
     * - 32 bytes: amount per second.
     * - 32 bytes: start time for the streaming allowance.
     * @param _mode The execution mode. (Must be Single callType, Default execType)
     * @param _executionCallData The transaction the delegate might try to perform.
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
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms 148 packed bytes where:
     * - 20 bytes: ERC20 token address.
     * - 32 bytes: initial amount.
     * - 32 bytes: max amount.
     * - 32 bytes: amount per second.
     * - 32 bytes: start time for the streaming allowance.
     * @return token_ The address of the ERC20 token contract.
     * @return initialAmount_ The initial amount available at startTime.
     * @return maxAmount_ The maximum total unlocked tokens (hard cap)
     * @return amountPerSecond_ The rate at which the allowance increases per second.
     * @return startTime_ The timestamp from which the allowance streaming begins.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (address token_, uint256 initialAmount_, uint256 maxAmount_, uint256 amountPerSecond_, uint256 startTime_)
    {
        require(_terms.length == 148, "ERC20StreamingEnforcer:invalid-terms-length");

        token_ = address(bytes20(_terms[0:20]));
        initialAmount_ = uint256(bytes32(_terms[20:52]));
        maxAmount_ = uint256(bytes32(_terms[52:84]));
        amountPerSecond_ = uint256(bytes32(_terms[84:116]));
        startTime_ = uint256(bytes32(_terms[116:148]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Validates the streaming allowance limit and updates `spent`.
     * @dev Reverts if the transfer amount exceeds the currently available allowance.
     *
     * @param _terms The encoded streaming terms: ERC20 token, initial amount, max amount, amount per second, and start time.
     * @param _executionCallData The transaction data specifying the target contract and call data. Expect
     * an `IERC20.transfer(address,uint256)` call here.
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
        (address target_,, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(callData_.length == 68, "ERC20StreamingEnforcer:invalid-execution-length");

        (address token_, uint256 initialAmount_, uint256 maxAmount_, uint256 amountPerSecond_, uint256 startTime_) =
            getTermsInfo(_terms);

        require(maxAmount_ >= initialAmount_, "ERC20StreamingEnforcer:invalid-max-amount");

        require(startTime_ > 0, "ERC20StreamingEnforcer:invalid-zero-start-time");

        require(token_ == target_, "ERC20StreamingEnforcer:invalid-contract");

        require(bytes4(callData_[0:4]) == IERC20.transfer.selector, "ERC20StreamingEnforcer:invalid-method");

        StreamingAllowance storage allowance_ = streamingAllowances[msg.sender][_delegationHash];
        if (allowance_.spent == 0) {
            // First use of this delegation
            allowance_.initialAmount = initialAmount_;
            allowance_.maxAmount = maxAmount_;
            allowance_.amountPerSecond = amountPerSecond_;
            allowance_.startTime = startTime_;
        }

        uint256 transferAmount_ = uint256(bytes32(callData_[36:68]));

        require(transferAmount_ <= _getAvailableAmount(allowance_), "ERC20StreamingEnforcer:allowance-exceeded");

        allowance_.spent += transferAmount_;

        emit IncreasedSpentMap(
            msg.sender,
            _redeemer,
            _delegationHash,
            token_,
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
