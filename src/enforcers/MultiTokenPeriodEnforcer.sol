// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title MultiTokenPeriodEnforcer
 * @notice Enforces periodic transfer limits for multiple tokens per delegation.
 * @dev The enforcer expects the _terms to be a concatenation of one or more 116-byte configurations.
 *      Each 116-byte segment encodes:
 *        - 20 bytes: token address (address(0) indicates a native transfer)
 *        - 32 bytes: periodAmount.
 *        - 32 bytes: periodDuration (in seconds).
 *        - 32 bytes: startDate for the first period.
 *      The _executionCallData always contains instructions for one token transfer.
 */
contract MultiTokenPeriodEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// State //////////////////////////////

    struct PeriodicAllowance {
        uint256 periodAmount; // Maximum transferable amount per period.
        uint256 periodDuration; // Duration of each period in seconds.
        uint256 startDate; // Timestamp when the first period begins.
        uint256 lastTransferPeriod; // The period index in which the last transfer was made.
        uint256 transferredInCurrentPeriod; // Cumulative amount transferred in the current period.
    }

    // Mapping from delegation manager => delegation hash => token address => PeriodicAllowance.
    mapping(address => mapping(bytes32 => mapping(address => PeriodicAllowance))) public periodicAllowances;

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when a transfer is made and the allowance is updated.
     * @param sender The address initiating the transfer.
     * @param redeemer The address receiving the tokens/ETH.
     * @param delegationHash The hash identifying the delegation.
     * @param token The token contract address; for native transfers this is address(0).
     * @param periodAmount The maximum transferable amount per period.
     * @param periodDuration The duration of each period in seconds.
     * @param startDate The timestamp when the first period begins.
     * @param transferredInCurrentPeriod The total transferred in the current period after this transfer.
     * @param transferTimestamp The block timestamp when the transfer occurred.
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
     * @notice Retrieves the available amount along with period details for a specific token.
     * @param _delegationHash The delegation hash.
     * @param _delegationManager The delegation manager's address.
     * @param _terms A concatenation of one or more 116-byte configurations.
     * @param _token The token for which the available amount is requested (address(0) for native).
     * @return availableAmount_ The remaining transferable amount in the current period.
     * @return isNewPeriod_ True if a new period has begun.
     * @return currentPeriod_ The current period index.
     */
    function getAvailableAmount(
        bytes32 _delegationHash,
        address _delegationManager,
        bytes calldata _terms,
        address _token
    )
        external
        view
        returns (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_)
    {
        PeriodicAllowance memory storedAllowance_ = periodicAllowances[_delegationManager][_delegationHash][_token];
        if (storedAllowance_.startDate != 0) {
            return _getAvailableAmount(storedAllowance_);
        }

        // Not yet initialized; simulate using provided terms.
        (uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_) = getTermsInfo(_terms, _token);
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
     * @notice Hook called before a transfer to enforce the periodic limit.
     * @dev For ERC20 transfers, expects _executionCallData to decode to (target, , callData)
     *      with callData length of 68 and beginning with IERC20.transfer.selector.
     *      For native transfers, expects _executionCallData to decode to (target, value, callData)
     *      with an empty callData.
     * @param _terms A concatenation of one or more 116-byte configurations.
     * @param _mode The execution mode (must be single callType, default execType).
     * @param _executionCallData The encoded execution data.
     * @param _delegationHash The delegation hash.
     * @param _redeemer The address intended to receive the tokens/ETH.
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
     * @notice Searches the provided _terms for a configuration matching _token.
     * @dev Expects _terms length to be a multiple of 116.
     * @param _terms A concatenation of 116-byte configurations.
     * @param _token The token address to search for (address(0) for native transfers).
     * @return periodAmount_ The maximum transferable amount for this token.
     * @return periodDuration_ The period duration (in seconds) for this token.
     * @return startDate_ The start date for the first period.
     */
    function getTermsInfo(
        bytes calldata _terms,
        address _token
    )
        public
        pure
        returns (uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_)
    {
        uint256 termsLength_ = _terms.length;
        require(termsLength_ % 116 == 0 && termsLength_ != 0, "MultiTokenPeriodEnforcer:invalid-terms-length");
        uint256 numConfigs_ = termsLength_ / 116;
        for (uint256 i = 0; i < numConfigs_; i++) {
            uint256 offset_ = i * 116;
            address token_ = address(bytes20(_terms[offset_:offset_ + 20]));
            if (token_ == _token) {
                periodAmount_ = uint256(bytes32(_terms[offset_ + 20:offset_ + 52]));
                periodDuration_ = uint256(bytes32(_terms[offset_ + 52:offset_ + 84]));
                startDate_ = uint256(bytes32(_terms[offset_ + 84:offset_ + 116]));
                return (periodAmount_, periodDuration_, startDate_);
            }
        }
        revert("MultiTokenPeriodEnforcer:token-config-not-found");
    }

    /**
     * @notice Decodes all configurations contained in _terms.
     * @dev Expects _terms length to be a multiple of 116.
     * @param _terms A concatenation of 116-byte configurations.
     * @return tokens_ An array of token addresses.
     * @return periodAmounts_ An array of period amounts.
     * @return periodDurations_ An array of period durations (in seconds).
     * @return startDates_ An array of start dates for the first period.
     */
    function getAllTermsInfo(bytes calldata _terms)
        public
        pure
        returns (
            address[] memory tokens_,
            uint256[] memory periodAmounts_,
            uint256[] memory periodDurations_,
            uint256[] memory startDates_
        )
    {
        uint256 termsLength_ = _terms.length;
        require(termsLength_ % 116 == 0 && termsLength_ != 0, "MultiTokenPeriodEnforcer:invalid-terms-length");
        uint256 numConfigs_ = termsLength_ / 116;
        tokens_ = new address[](numConfigs_);
        periodAmounts_ = new uint256[](numConfigs_);
        periodDurations_ = new uint256[](numConfigs_);
        startDates_ = new uint256[](numConfigs_);

        for (uint256 i = 0; i < numConfigs_; i++) {
            uint256 offset_ = i * 116;
            tokens_[i] = address(bytes20(_terms[offset_:offset_ + 20]));
            periodAmounts_[i] = uint256(bytes32(_terms[offset_ + 20:offset_ + 52]));
            periodDurations_[i] = uint256(bytes32(_terms[offset_ + 52:offset_ + 84]));
            startDates_[i] = uint256(bytes32(_terms[offset_ + 84:offset_ + 116]));
        }
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Validates and consumes a transfer (native or ERC20) by ensuring the amount does not exceed the available limit.
     * @dev Decodes the execution data based on token type:
     *      - For native transfers (_token == address(0)): decodes (target, value, callData) and requires callData to be empty.
     *      - For ERC20 transfers (_token != address(0)): decodes (target, , callData) and requires callData length to be 68 with a
     * valid IERC20.transfer selector.
     * @param _terms The concatenated configurations.
     * @param _executionCallData The encoded execution data.
     * @param _delegationHash The delegation hash.
     * @param _redeemer The address intended to receive the tokens/ETH.
     */
    function _validateAndConsumeTransfer(
        bytes calldata _terms,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _redeemer
    )
        private
    {
        uint256 transferAmount_;
        address token_;

        // Decode _executionCallData using decodeSingle.
        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();
        if (value_ > 0) {
            // Native transfer.
            token_ = address(0);
            transferAmount_ = value_;
        } else {
            // ERC20 transfer.
            require(callData_.length == 68, "MultiTokenPeriodEnforcer:invalid-execution-length");
            require(bytes4(callData_[0:4]) == IERC20.transfer.selector, "MultiTokenPeriodEnforcer:invalid-method");
            token_ = target_;
            transferAmount_ = uint256(bytes32(callData_[36:68]));
        }

        // Retrieve the configuration for the token from _terms.
        (uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_) = getTermsInfo(_terms, token_);

        // Use the multi-token mapping.
        PeriodicAllowance storage allowance_ = periodicAllowances[msg.sender][_delegationHash][token_];

        // Initialize the allowance if not already set.
        if (allowance_.startDate == 0) {
            require(startDate_ > 0, "MultiTokenPeriodEnforcer:invalid-zero-start-date");
            require(periodAmount_ > 0, "MultiTokenPeriodEnforcer:invalid-zero-period-amount");
            require(periodDuration_ > 0, "MultiTokenPeriodEnforcer:invalid-zero-period-duration");
            require(block.timestamp >= startDate_, "MultiTokenPeriodEnforcer:transfer-not-started");

            allowance_.periodAmount = periodAmount_;
            allowance_.periodDuration = periodDuration_;
            allowance_.startDate = startDate_;
        }

        // Determine the available amount.
        (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_) = _getAvailableAmount(allowance_);
        require(transferAmount_ <= availableAmount_, "MultiTokenPeriodEnforcer:transfer-amount-exceeded");

        // Reset transferred amount if a new period has begun.
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
     * @notice Computes the available amount for the current period.
     * @dev If block.timestamp is before startDate, available amount is 0.
     * @param _allowance The PeriodicAllowance struct.
     * @return availableAmount_ The remaining transferable amount in the current period.
     * @return isNewPeriod_ True if the last transfer period is not equal to the current period.
     * @return currentPeriod_ The current period index.
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
        uint256 alreadyTransferred_ = isNewPeriod_ ? 0 : _allowance.transferredInCurrentPeriod;
        availableAmount_ = _allowance.periodAmount > alreadyTransferred_ ? _allowance.periodAmount - alreadyTransferred_ : 0;
    }
}
