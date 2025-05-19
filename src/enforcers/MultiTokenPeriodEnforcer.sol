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
 *
 *      Duplicate token entries in the terms are supported. Each configuration is identified
 *      by its index, allowing the same token to have multiple distinct allowances.
 *      The internal mapping includes the index in its hash key, enabling separate
 *      tracking per configuration.
 *
 *      Additionally, the enforcer does not support restrictions on the recipient address or
 *      arbitrary calldata. For ERC20 transfers, the execution data is strictly required to
 *      match the IERC20.transfer function selector with a zero ETH value, and for native transfers,
 *      only an empty calldata is permitted.
 *
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

    // Mapping from hash key => PeriodicAllowance
    mapping(bytes32 hashKey => PeriodicAllowance) public periodicAllowances;

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

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     * @param _caller Address of the sender calling the enforcer.
     * @param _token Token being compared in the beforeHook and afterHook.
     * @param _delegationHash The hash of the delegation.
     * @param _index The token configuration index.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(address _caller, address _token, bytes32 _delegationHash, uint256 _index) external pure returns (bytes32) {
        return _getHashKey(_caller, _token, _delegationHash, _index);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Retrieves the available amount along with period details for a specific token.
     * @param _delegationHash The delegation hash.
     * @param _delegationManager The delegation manager's address.
     * @param _terms A concatenation of one or more 116-byte configurations.
     * @param _args A single uint256 value representing the index of the token configuration to use.
     * @return availableAmount_ The remaining transferable amount in the current period.
     * @return isNewPeriod_ True if a new period has begun.
     * @return currentPeriod_ The current period index.
     */
    function getAvailableAmount(
        bytes32 _delegationHash,
        address _delegationManager,
        bytes calldata _terms,
        bytes calldata _args
    )
        external
        view
        returns (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_)
    {
        (bytes32 hashKey_, uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_) =
            _getValues(_delegationHash, _delegationManager, _terms, _args);

        PeriodicAllowance memory storedAllowance_ = periodicAllowances[hashKey_];
        if (storedAllowance_.startDate != 0) {
            return _getAvailableAmount(storedAllowance_);
        }

        // Not yet initialized; simulate using provided terms.
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
     * @notice Decodes all configurations contained in _terms.
     * @dev Expects _terms length to be a multiple of 116.
     * @param _terms A concatenation of 116-byte configurations.
     * @return tokens_ An array of token addresses.
     * @return periodAmounts_ An array of period amounts.
     * @return periodDurations_ An array of period durations (in seconds).
     * @return startDates_ An array of start dates for the first period.
     */
    function getAllTermsInfo(bytes calldata _terms)
        external
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

        // Loop over each configuration using its index.
        for (uint256 i = 0; i < numConfigs_; ++i) {
            // Calculate the starting offset for this configuration.
            uint256 offset_ = i * 116;
            // Get the token address from the first 20 bytes.
            tokens_[i] = address(bytes20(_terms[offset_:offset_ + 20]));
            // Get the periodAmount from the next 32 bytes.
            periodAmounts_[i] = uint256(bytes32(_terms[offset_ + 20:offset_ + 52]));
            // Get the periodDuration from the following 32 bytes.
            periodDurations_[i] = uint256(bytes32(_terms[offset_ + 52:offset_ + 84]));
            // Get the startDate from the final 32 bytes.
            startDates_[i] = uint256(bytes32(_terms[offset_ + 84:offset_ + 116]));
        }
    }

    /**
     * @notice Hook called before a transfer to enforce the periodic limit.
     * @dev For ERC20 transfers, expects _executionCallData to decode to (target,, callData)
     *      with callData length of 68, beginning with IERC20.transfer.selector and zero value.
     *      For native transfers, expects _executionCallData to decode to (target, value, callData)
     *      with an empty callData.
     * @param _terms A concatenation of one or more 116-byte configurations.
     * @param _args A single uint256 value representing the index of the token configuration to use.
     * @param _mode The execution mode (must be single callType, default execType).
     * @param _executionCallData The encoded execution data.
     * @param _delegationHash The delegation hash.
     * @param _redeemer The address intended to receive the tokens/ETH.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
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
        _validateAndConsumeTransfer(_terms, _args, _executionCallData, _delegationHash, _redeemer);
    }

    /**
     * @notice Retrieves the configuration for a specific token index from _terms.
     * @dev Expects _terms length to be a multiple of 116.
     * @param _terms A concatenation of 116-byte configurations.
     * @param _tokenIndex The index of the token configuration to retrieve.
     * @return token_ The token address at the specified index.
     * @return periodAmount_ The maximum transferable amount for this token.
     * @return periodDuration_ The period duration (in seconds) for this token.
     * @return startDate_ The start date for the first period.
     */
    function getTermsInfo(
        bytes calldata _terms,
        uint256 _tokenIndex
    )
        public
        pure
        returns (address token_, uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_)
    {
        uint256 termsLength_ = _terms.length;
        require(termsLength_ != 0 && termsLength_ % 116 == 0, "MultiTokenPeriodEnforcer:invalid-terms-length");

        uint256 numConfigs_ = termsLength_ / 116;
        require(_tokenIndex < numConfigs_, "MultiTokenPeriodEnforcer:invalid-token-index");

        uint256 offset_ = _tokenIndex * 116;
        token_ = address(bytes20(_terms[offset_:offset_ + 20]));
        periodAmount_ = uint256(bytes32(_terms[offset_ + 20:offset_ + 52]));
        periodDuration_ = uint256(bytes32(_terms[offset_ + 52:offset_ + 84]));
        startDate_ = uint256(bytes32(_terms[offset_ + 84:offset_ + 116]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Validates and consumes a transfer (native or ERC20) by ensuring the amount does not exceed the available limit.
     * @dev Decodes the execution data based on token type:
     *      - For native transfers (_token == address(0)): expect no calldata, value greater than zero.
     *      - For ERC20 transfers (_token != address(0)): requires callData length to be 68 with a
     *        valid IERC20.transfer selector, and zero value.
     * @param _terms The concatenated configurations.
     * @param _args A single uint256 value representing the index of the token configuration to use.
     * @param _executionCallData The encoded execution data.
     * @param _delegationHash The delegation hash.
     * @param _redeemer The address intended to receive the tokens/ETH.
     */
    function _validateAndConsumeTransfer(
        bytes calldata _terms,
        bytes calldata _args,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _redeemer
    )
        private
    {
        uint256 transferAmount_;
        address token_;
        {
            // Decode _executionCallData using decodeSingle.
            (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();

            if (callData_.length == 68) {
                // ERC20 transfer.
                require(value_ == 0, "MultiTokenPeriodEnforcer:invalid-value-in-erc20-transfer");
                require(bytes4(callData_[0:4]) == IERC20.transfer.selector, "MultiTokenPeriodEnforcer:invalid-method");
                token_ = target_;
                transferAmount_ = uint256(bytes32(callData_[36:68]));
            } else if (callData_.length == 0) {
                // Native transfer.
                require(value_ > 0, "MultiTokenPeriodEnforcer:invalid-zero-value-in-native-transfer");
                token_ = address(0);
                transferAmount_ = value_;
            } else {
                // If callData length is neither 68 nor 0, revert.
                revert("MultiTokenPeriodEnforcer:invalid-call-data-length");
            }
        }
        uint256 index_ = abi.decode(_args, (uint256));
        // Get the token configuration from the specified index
        (address configuredToken_, uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_) =
            getTermsInfo(_terms, index_);

        // Verify that the token in the execution matches the configured token
        require(token_ == configuredToken_, "MultiTokenPeriodEnforcer:token-mismatch");

        // Use the hash key for the mapping
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, _delegationHash, index_);
        PeriodicAllowance storage allowance_ = periodicAllowances[hashKey_];

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

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     * @param _delegationManager The delegation manager's address.
     * @param _token The token address.
     * @param _delegationHash The hash of the delegation.
     * @param _index The token configuration index.
     * @return The hash to be used as key of the mapping.
     */
    function _getHashKey(
        address _delegationManager,
        address _token,
        bytes32 _delegationHash,
        uint256 _index
    )
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_delegationManager, _token, _delegationHash, _index));
    }

    /**
     * @notice Extracts and processes values from delegation terms and arguments
     * @dev Decodes the index from args, gets token info from terms, and generates a unique hash key
     * @param _delegationHash The hash of the delegation
     * @param _delegationManager The address of the delegation manager contract
     * @param _terms The encoded terms containing token configurations
     * @param _args The encoded arguments containing the token configuration index
     * @return hashKey_ A unique hash key for identifying this specific delegation/token combination
     * @return periodAmount_ The maximum amount that can be transferred per period
     * @return periodDuration_ The duration of each period in seconds
     * @return startDate_ The timestamp when the periodic allowance begins
     */
    function _getValues(
        bytes32 _delegationHash,
        address _delegationManager,
        bytes calldata _terms,
        bytes calldata _args
    )
        internal
        pure
        returns (bytes32 hashKey_, uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_)
    {
        uint256 index_ = abi.decode(_args, (uint256));
        address token_;
        (token_, periodAmount_, periodDuration_, startDate_) = getTermsInfo(_terms, index_);

        hashKey_ = _getHashKey(_delegationManager, token_, _delegationHash, index_);
    }
}
