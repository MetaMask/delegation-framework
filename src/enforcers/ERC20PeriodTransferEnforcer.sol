// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC20PeriodTransferEnforcer
 * @notice Enforces periodic transfer limits for ERC20 token transfers.
 * @dev This contract implements a mechanism by which a user may transfer up to a fixed amount of tokens (the period amount)
 *      during a given time period. The transferable amount resets at the beginning of each period, and any unused tokens
 *      are forfeited once the period ends. Partial transfers within a period are allowed, but the total transfer in any
 *      period cannot exceed the specified limit.
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 */
contract ERC20PeriodTransferEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// State //////////////////////////////

    struct PeriodicAllowance {
        uint256 periodAmount; // Maximum transferable tokens per period.
        uint256 periodDuration; // Duration of each period in seconds.
        uint256 startDate; // Timestamp when the first period begins.
        uint256 lastTransferPeriod; // The period index in which the last transfer was made.
        uint256 transferredInCurrentPeriod; // Cumulative amount transferred in the current period.
    }

    /**
     * @dev Mapping from a delegation manager address and delegation hash to a PeriodicAllowance.
     */
    mapping(address delegationManager => mapping(bytes32 delegationHash => PeriodicAllowance)) public periodicAllowances;

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when a transfer is made, updating the transferred amount in the active period.
     * @param sender The address initiating the transfer.
     * @param redeemer The address that receives the tokens.
     * @param delegationHash The hash identifying the delegation.
     * @param token The ERC20 token contract address.
     * @param periodAmount The maximum tokens transferable per period.
     * @param periodDuration The duration of each period (in seconds).
     * @param startDate The timestamp when the first period begins.
     * @param transferredInCurrentPeriod The total tokens transferred in the current period after this transfer.
     * @param transferTimestamp The block timestamp at which the transfer was executed.
     */
    event TransferredInPeriod(
        address indexed sender,
        address indexed redeemer,
        bytes32 indexed delegationHash,
        address token,
        uint256 periodAmount,
        uint256 periodDuration,
        uint256 startDate,
        uint256 transferredInCurrentPeriod,
        uint256 transferTimestamp
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Retrieves the current transferable amount along with period status for a given delegation.
     * @param _delegationHash The hash that identifies the delegation.
     * @param _delegationManager The address of the delegation manager.
     * @param _terms 116 packed bytes:
     *  - 20 bytes: ERC20 token address.
     *  - 32 bytes: periodAmount.
     *  - 32 bytes: periodDuration (in seconds).
     *  - 32 bytes: startDate for the first period.
     * @return availableAmount_ The number of tokens available to transfer in the current period.
     * @return isNewPeriod_ A boolean indicating whether a new period has started (i.e., last transfer period differs from current).
     * @return currentPeriod_ The current period index based on the start date and period duration.
     */
    function getAvailableAmount(
        bytes32 _delegationHash,
        address _delegationManager,
        bytes calldata _terms
    )
        external
        view
        returns (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_)
    {
        PeriodicAllowance memory storedAllowance_ = periodicAllowances[_delegationManager][_delegationHash];
        if (storedAllowance_.startDate != 0) {
            return _getAvailableAmount(storedAllowance_);
        }

        // Not yet initialized: simulate using provided terms.
        (, uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_) = getTermsInfo(_terms);

        PeriodicAllowance memory allowance_ = PeriodicAllowance({
            periodAmount: periodAmount_,
            periodDuration: periodDuration_,
            startDate: startDate_,
            lastTransferPeriod: 0,
            transferredInCurrentPeriod: 0
        });
        return _getAvailableAmount(allowance_);
    }

    /**
     * @notice Hook called before an ERC20 transfer to enforce the periodic transfer limit.
     * @dev Reverts if the transfer amount exceeds the available tokens for the current period.
     *      Expects `_terms` to be a 116-byte blob encoding the ERC20 token, period amount, period duration, and start date.
     * @param _terms 116 packed bytes:
     *  - 20 bytes: ERC20 token address.
     *  - 32 bytes: periodAmount.
     *  - 32 bytes: periodDuration (in seconds).
     *  - 32 bytes: startDate for the first period.
     * @param _mode The execution mode. (Must be Single callType, Default execType)
     * @param _executionCallData The transaction data (should be an `IERC20.transfer(address,uint256)` call).
     * @param _delegationHash The hash identifying the delegation.
     * @param _redeemer The address intended to receive the tokens.
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
        _validateAndConsumeTransfer(_terms, _executionCallData, _delegationHash, _redeemer);
    }

    /**
     * @notice Decodes the transfer terms.
     * @dev Expects a 116-byte blob and extracts the ERC20 token address, period amount, period duration, and start date.
     * @param _terms 116 packed bytes:
     *  - 20 bytes: ERC20 token address.
     *  - 32 bytes: periodAmount.
     *  - 32 bytes: periodDuration (in seconds).
     *  - 32 bytes: startDate.
     * @return token_ The address of the ERC20 token contract.
     * @return periodAmount_ The maximum tokens transferable per period.
     * @return periodDuration_ The duration of each period in seconds.
     * @return startDate_ The timestamp when the first period begins.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (address token_, uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_)
    {
        require(_terms.length == 116, "ERC20PeriodTransferEnforcer:invalid-terms-length");

        token_ = address(bytes20(_terms[0:20]));
        periodAmount_ = uint256(bytes32(_terms[20:52]));
        periodDuration_ = uint256(bytes32(_terms[52:84]));
        startDate_ = uint256(bytes32(_terms[84:116]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Validates and accounts for a transfer by ensuring the transfer amount does not exceed the transferable tokens.
     * @dev Uses `_getAvailableAmount` to determine the available transferable amount and whether a new period has started.
     *      If a new period is detected, the transferred amount is reset before applying the new transfer.
     * @param _terms The encoded transfer terms (ERC20 token, period amount, period duration, start date).
     * @param _executionCallData The transaction data (expected to be an `IERC20.transfer(address,uint256)` call).
     * @param _delegationHash The hash identifying the delegation.
     * @param _redeemer The address intended to receive the tokens.
     */
    function _validateAndConsumeTransfer(
        bytes calldata _terms,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _redeemer
    )
        private
    {
        (address target_,, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(callData_.length == 68, "ERC20PeriodTransferEnforcer:invalid-execution-length");

        (address token_, uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_) = getTermsInfo(_terms);

        require(token_ == target_, "ERC20PeriodTransferEnforcer:invalid-contract");
        require(bytes4(callData_[0:4]) == IERC20.transfer.selector, "ERC20PeriodTransferEnforcer:invalid-method");

        PeriodicAllowance storage allowance_ = periodicAllowances[msg.sender][_delegationHash];

        // Initialize the allowance on first use.
        if (allowance_.startDate == 0) {
            require(startDate_ > 0, "ERC20PeriodTransferEnforcer:invalid-zero-start-date");
            require(periodAmount_ > 0, "ERC20PeriodTransferEnforcer:invalid-zero-period-amount");
            require(periodDuration_ > 0, "ERC20PeriodTransferEnforcer:invalid-zero-period-duration");

            // Ensure the transfer period has started.
            require(block.timestamp >= startDate_, "ERC20PeriodTransferEnforcer:transfer-not-started");

            allowance_.periodAmount = periodAmount_;
            allowance_.periodDuration = periodDuration_;
            allowance_.startDate = startDate_;
        }

        // Calculate available tokens using the current allowance state.
        (uint256 available_, bool isNewPeriod_, uint256 currentPeriod_) = _getAvailableAmount(allowance_);

        uint256 transferAmount_ = uint256(bytes32(callData_[36:68]));
        require(transferAmount_ <= available_, "ERC20PeriodTransferEnforcer:transfer-amount-exceeded");

        // If a new period has started, reset transferred amount before continuing.
        if (isNewPeriod_) {
            allowance_.lastTransferPeriod = currentPeriod_;
            allowance_.transferredInCurrentPeriod = 0;
        }

        allowance_.transferredInCurrentPeriod += transferAmount_;

        emit TransferredInPeriod(
            msg.sender,
            _redeemer,
            _delegationHash,
            token_,
            periodAmount_,
            periodDuration_,
            startDate_,
            allowance_.transferredInCurrentPeriod,
            block.timestamp
        );
    }

    /**
     * @notice Computes the available tokens that can be transferred in the current period.
     * @dev Calculates the current period index based on `startDate` and `periodDuration`. Returns a tuple:
     *      - availableAmount_: Remaining tokens transferable in the current period.
     *      - isNewPeriod_: True if the last transfer period is not equal to the current period.
     *      - currentPeriod_: The current period index, where the first period starts at index 1.
     *      If the current time is before the start date, availableAmount_ is 0.
     * @param _allowance The PeriodicAllowance struct.
     * @return availableAmount_ The tokens still available to transfer in the current period.
     * @return isNewPeriod_ True if a new period has started since the last transfer.
     * @return currentPeriod_ The current period index calculated from the start date.
     */
    function _getAvailableAmount(PeriodicAllowance memory _allowance)
        internal
        view
        returns (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_)
    {
        if (block.timestamp < _allowance.startDate) {
            return (0, false, 0);
        }

        currentPeriod_ = (block.timestamp - _allowance.startDate) / _allowance.periodDuration + 1;

        isNewPeriod_ = (_allowance.lastTransferPeriod != currentPeriod_);

        uint256 alreadyTransferred = isNewPeriod_ ? 0 : _allowance.transferredInCurrentPeriod;

        availableAmount_ = _allowance.periodAmount > alreadyTransferred ? _allowance.periodAmount - alreadyTransferred : 0;
    }
}
