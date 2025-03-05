// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title NativeTokenPeriodAllowanceEnforcer
 * @notice Enforces periodic claim limits for native token (ETH) transfers.
 * @dev This contract implements a mechanism by which a user may claim up to a fixed amount of ETH (the period amount)
 *      during a given time period. The claimable amount resets at the beginning of each period and unclaimed ETH is
 *      forfeited once the period ends. Partial claims within a period are allowed, but the total claim in any period
 *      cannot exceed the specified limit. This enforcer is designed to work only in single execution mode (ModeCode.Single).
 */
contract NativeTokenPeriodAllowanceEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// State //////////////////////////////

    struct PeriodicAllowance {
        uint256 periodAmount; // Maximum claimable ETH (in wei) per period.
        uint256 periodDuration; // Duration of each period in seconds.
        uint256 startDate; // Timestamp when the first period begins.
        uint256 lastClaimPeriod; // The period index in which the last claim was made.
        uint256 claimedInCurrentPeriod; // Cumulative amount claimed in the current period.
    }

    /**
     * @dev Mapping from a delegation manager address and delegation hash to a PeriodicAllowance.
     */
    mapping(address delegationManager => mapping(bytes32 delegationHash => PeriodicAllowance)) public periodicAllowances;

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when a native token claim is made, updating the claimed amount in the active period.
     * @param sender The address initiating the claim.
     * @param redeemer The address that receives the ETH.
     * @param delegationHash The hash identifying the delegation.
     * @param periodAmount The maximum ETH (in wei) claimable per period.
     * @param periodDuration The duration of each period (in seconds).
     * @param startDate The timestamp when the first period begins.
     * @param claimedInCurrentPeriod The total ETH (in wei) claimed in the current period after this claim.
     * @param claimTimestamp The block timestamp at which the claim was executed.
     */
    event ClaimUpdated(
        address indexed sender,
        address indexed redeemer,
        bytes32 indexed delegationHash,
        uint256 periodAmount,
        uint256 periodDuration,
        uint256 startDate,
        uint256 claimedInCurrentPeriod,
        uint256 claimTimestamp
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Retrieves the available ETH by simulating the allowance if it has not been initialized.
     * @param _delegationHash The hash identifying the delegation.
     * @param _delegationManager The delegation manager address.
     * @param _terms 96 packed bytes:
     *  - 32 bytes: periodAmount.
     *  - 32 bytes: periodDuration (in seconds).
     *  - 32 bytes: startDate for the first period.
     * @return availableAmount_ The simulated available ETH (in wei) in the current period.
     * @return isNewPeriod_ True if a new period would be in effect.
     * @return currentPeriod_ The current period index as determined by the terms.
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
        if (storedAllowance_.startDate != 0) return _getAvailableAmount(storedAllowance_);

        // Not yet initialized: simulate using provided terms.
        (uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_) = getTermsInfo(_terms);
        PeriodicAllowance memory allowance_ = PeriodicAllowance({
            periodAmount: periodAmount_,
            periodDuration: periodDuration_,
            startDate: startDate_,
            lastClaimPeriod: 0,
            claimedInCurrentPeriod: 0
        });
        return _getAvailableAmount(allowance_);
    }

    /**
     * @notice Hook called before a native ETH transfer to enforce the periodic claim limit.
     * @dev Reverts if the transfer value exceeds the available ETH for the current period.
     *      Expects `_terms` to be a 96-byte blob encoding: periodAmount, periodDuration, and startDate.
     * @param _terms 96 packed bytes:
     *  - 32 bytes: periodAmount.
     *  - 32 bytes: periodDuration (in seconds).
     *  - 32 bytes: startDate for the first period.
     * @param _mode The execution mode (must be ModeCode.Single).
     * @param _executionCallData The execution data encoded via ExecutionLib.encodeSingle.
     *        For native ETH transfers, decodeSingle returns (target, value, callData) and callData is expected to be empty.
     * @param _delegationHash The hash identifying the delegation.
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
        _validateAndConsumeClaim(_terms, _executionCallData, _delegationHash, _redeemer);
    }

    /**
     * @notice Decodes the native claim terms.
     * @dev Expects a 96-byte blob and extracts: periodAmount, periodDuration, and startDate.
     * @param _terms 96 packed bytes:
     *  - 32 bytes: periodAmount.
     *  - 32 bytes: periodDuration (in seconds).
     *  - 32 bytes: startDate.
     * @return periodAmount_ The maximum ETH (in wei) claimable per period.
     * @return periodDuration_ The duration of each period in seconds.
     * @return startDate_ The timestamp when the first period begins.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_)
    {
        require(_terms.length == 96, "NativeTokenPeriodAllowanceEnforcer:invalid-terms-length");
        periodAmount_ = uint256(bytes32(_terms[0:32]));
        periodDuration_ = uint256(bytes32(_terms[32:64]));
        startDate_ = uint256(bytes32(_terms[64:96]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Validates and consumes a claim by ensuring the transfer value does not exceed the available ETH.
     * @dev Uses _getAvailableAmount to determine the available ETH and whether a new period has started.
     *      If a new period is detected, the claimed amount is reset before consuming the claim.
     * @param _terms The encoded claim terms (periodAmount, periodDuration, startDate).
     * @param _executionCallData The execution data (expected to be encoded via ExecutionLib.encodeSingle).
     *        For native transfers, decodeSingle returns (target, value, callData) and callData must be empty.
     * @param _delegationHash The hash identifying the delegation.
     */
    function _validateAndConsumeClaim(
        bytes calldata _terms,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _redeemer
    )
        private
    {
        (, uint256 value_,) = _executionCallData.decodeSingle();

        (uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_) = getTermsInfo(_terms);

        // Validate terms.
        require(startDate_ > 0, "NativeTokenPeriodAllowanceEnforcer:invalid-zero-start-date");
        require(periodDuration_ > 0, "NativeTokenPeriodAllowanceEnforcer:invalid-zero-period-duration");
        require(periodAmount_ > 0, "NativeTokenPeriodAllowanceEnforcer:invalid-zero-period-amount");

        // Ensure the claim period has started.
        require(block.timestamp >= startDate_, "NativeTokenPeriodAllowanceEnforcer:claim-not-started");

        PeriodicAllowance storage allowance_ = periodicAllowances[msg.sender][_delegationHash];

        // Initialize the allowance on first use.
        if (allowance_.startDate == 0) {
            allowance_.periodAmount = periodAmount_;
            allowance_.periodDuration = periodDuration_;
            allowance_.startDate = startDate_;
            allowance_.lastClaimPeriod = 0;
            allowance_.claimedInCurrentPeriod = 0;
        }

        // Calculate available tokens using the current allowance state.
        (uint256 available_, bool isNewPeriod_, uint256 currentPeriod_) = _getAvailableAmount(allowance_);

        require(value_ <= available_, "NativeTokenPeriodAllowanceEnforcer:claim-amount-exceeded");

        // If a new period has started, update state before processing the claim.
        if (isNewPeriod_) {
            allowance_.lastClaimPeriod = currentPeriod_;
            allowance_.claimedInCurrentPeriod = 0;
        }
        allowance_.claimedInCurrentPeriod += value_;

        emit ClaimUpdated(
            msg.sender,
            _redeemer,
            _delegationHash,
            periodAmount_,
            periodDuration_,
            allowance_.startDate,
            allowance_.claimedInCurrentPeriod,
            block.timestamp
        );
    }

    /**
     * @notice Computes the available tokens that can be claimed in the current period.
     * @dev Calculates the current period index based on `startDate` and `periodDuration`. Returns a tuple:
     *      - availableAmount_: Remaining tokens claimable in the current period.
     *      - isNewPeriod_: True if the last claim period is not equal to the current period.
     *      - currentPeriod_: The current period index, first period starts at 1.
     *      If the current time is before the start date, availableAmount_ is 0.
     * @param _allowance The PeriodicAllowance struct.
     * @return availableAmount_ The tokens still available to claim in the current period.
     * @return isNewPeriod_ True if a new period has started since the last claim.
     * @return currentPeriod_ The current period index calculated from the start date.
     */
    function _getAvailableAmount(PeriodicAllowance memory _allowance)
        internal
        view
        returns (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_)
    {
        if (block.timestamp < _allowance.startDate) return (0, false, 0);
        currentPeriod_ = (block.timestamp - _allowance.startDate) / _allowance.periodDuration + 1;
        isNewPeriod_ = _allowance.lastClaimPeriod != currentPeriod_;
        uint256 claimed = isNewPeriod_ ? 0 : _allowance.claimedInCurrentPeriod;
        availableAmount_ = _allowance.periodAmount > claimed ? _allowance.periodAmount - claimed : 0;
    }
}
