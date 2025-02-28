// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC20PeriodicClaimEnforcer
 * @notice Enforces periodic claim limits for ERC20 token transfers.
 * @dev This contract implements a mechanism by which a user may claim up to a fixed amount of tokens (the period amount)
 *      during a given time period. The claimable amount resets at the beginning of each period and unclaimed tokens are
 *      forfeited once the period ends. Partial claims within a period are allowed, but the total claim in any period
 *      cannot exceed the specified limit. This enforcer is designed to work only in single execution mode (ModeCode.Single).
 */
contract ERC20PeriodicClaimEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// State //////////////////////////////

    struct PeriodicAllowance {
        uint256 periodAmount; // Maximum claimable tokens per period.
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
     * @notice Emitted when a claim is made, updating the claimed amount in the active period.
     * @param sender The address initiating the claim.
     * @param redeemer The address that receives the tokens.
     * @param delegationHash The hash identifying the delegation.
     * @param token The ERC20 token contract address.
     * @param periodAmount The maximum tokens claimable per period.
     * @param periodDuration The duration of each period (in seconds).
     * @param startDate The timestamp when the first period begins.
     * @param claimedInCurrentPeriod The total tokens claimed in the current period after this claim.
     * @param claimTimestamp The block timestamp at which the claim was executed.
     */
    event ClaimUpdated(
        address indexed sender,
        address indexed redeemer,
        bytes32 indexed delegationHash,
        address token,
        uint256 periodAmount,
        uint256 periodDuration,
        uint256 startDate,
        uint256 claimedInCurrentPeriod,
        uint256 claimTimestamp
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Retrieves the current claimable amount along with period status for a given delegation.
     * @param _delegationHash The hash that identifies the delegation.
     * @param _delegationManager The address of the delegation manager.
     * @return availableAmount_ The number of tokens available to claim in the current period.
     * @return isNewPeriod_ A boolean indicating whether a new period has started (i.e., last claim period differs from current).
     * @return currentPeriod_ The current period index based on the start date and period duration.
     */
    function getAvailableAmount(
        bytes32 _delegationHash,
        address _delegationManager
    )
        external
        view
        returns (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_)
    {
        PeriodicAllowance storage allowance_ = periodicAllowances[_delegationManager][_delegationHash];
        (availableAmount_, isNewPeriod_, currentPeriod_) = _getAvailableAmount(allowance_);
    }

    /**
     * @notice Hook called before an ERC20 transfer to enforce the periodic claim limit.
     * @dev Reverts if the transfer amount exceeds the available tokens for the current period.
     *      Expects `_terms` to be a 116-byte blob encoding the ERC20 token, period amount, period duration, and start date.
     * @param _terms 116 packed bytes:
     *  - 20 bytes: ERC20 token address.
     *  - 32 bytes: periodAmount.
     *  - 32 bytes: periodDuration (in seconds).
     *  - 32 bytes: startDate for the first period.
     * @param _mode The execution mode (must be ModeCode.Single).
     * @param _executionCallData The transaction data (should be an `IERC20.transfer(address,uint256)` call).
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
     * @notice Decodes the claim terms.
     * @dev Expects a 116-byte blob and extracts the ERC20 token address, period amount, period duration, and start date.
     * @param _terms 116 packed bytes:
     *  - 20 bytes: ERC20 token address.
     *  - 32 bytes: periodAmount.
     *  - 32 bytes: periodDuration (in seconds).
     *  - 32 bytes: startDate.
     * @return token_ The address of the ERC20 token contract.
     * @return periodAmount_ The maximum tokens claimable per period.
     * @return periodDuration_ The duration of each period in seconds.
     * @return startDate_ The timestamp when the first period begins.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (address token_, uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_)
    {
        require(_terms.length == 116, "ERC20PeriodicClaimEnforcer:invalid-terms-length");

        token_ = address(bytes20(_terms[0:20]));
        periodAmount_ = uint256(bytes32(_terms[20:52]));
        periodDuration_ = uint256(bytes32(_terms[52:84]));
        startDate_ = uint256(bytes32(_terms[84:116]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Validates and consumes a claim by ensuring the transfer amount does not exceed the claimable tokens.
     * @dev Uses `_getAvailableAmount` to determine the available claimable amount and whether a new period has started.
     *      If a new period is detected, the claimed amount is reset before consuming the claim.
     * @param _terms The encoded claim terms (ERC20 token, period amount, period duration, start date).
     * @param _executionCallData The transaction data (expected to be an `IERC20.transfer(address,uint256)` call).
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
        (address target_,, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(callData_.length == 68, "ERC20PeriodicClaimEnforcer:invalid-execution-length");

        (address token_, uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_) = getTermsInfo(_terms);

        // Validate terms
        require(startDate_ > 0, "ERC20PeriodicClaimEnforcer:invalid-zero-start-date");
        require(periodDuration_ > 0, "ERC20PeriodicClaimEnforcer:invalid-zero-period-duration");
        require(periodAmount_ > 0, "ERC20PeriodicClaimEnforcer:invalid-zero-period-amount");

        require(token_ == target_, "ERC20PeriodicClaimEnforcer:invalid-contract");

        require(bytes4(callData_[0:4]) == IERC20.transfer.selector, "ERC20PeriodicClaimEnforcer:invalid-method");

        // Ensure the claim period has started.
        require(block.timestamp >= startDate_, "ERC20PeriodicClaimEnforcer:claim-not-started");

        PeriodicAllowance storage allowance_ = periodicAllowances[msg.sender][_delegationHash];

        // Initialize the allowance on first use.
        if (allowance_.startDate == 0) {
            allowance_.periodAmount = periodAmount_;
            allowance_.periodDuration = periodDuration_;
            allowance_.startDate = startDate_;
            allowance_.lastClaimPeriod = 0;
            allowance_.claimedInCurrentPeriod = 0;
        }

        // Reuse the view function to calculate the available claimable tokens.
        (uint256 available_, bool isNewPeriod_, uint256 currentPeriod_) = _getAvailableAmount(allowance_);

        uint256 transferAmount_ = uint256(bytes32(callData_[36:68]));
        require(transferAmount_ <= available_, "ERC20PeriodicClaimEnforcer:claim-amount-exceeded");

        // If a new period has started, update state before processing the claim.
        if (isNewPeriod_) {
            allowance_.lastClaimPeriod = currentPeriod_;
            allowance_.claimedInCurrentPeriod = 0;
        }

        allowance_.claimedInCurrentPeriod += transferAmount_;

        emit ClaimUpdated(
            msg.sender,
            _redeemer,
            _delegationHash,
            token_,
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
     *      - currentPeriod_: The current period index.
     *      If the current time is before the start date, availableAmount_ is 0.
     * @param allowance The PeriodicAllowance struct containing the claim parameters and state.
     * @return availableAmount_ The tokens still available to claim in the current period.
     * @return isNewPeriod_ True if a new period has started since the last claim.
     * @return currentPeriod_ The current period index calculated from the start date.
     */
    function _getAvailableAmount(PeriodicAllowance storage allowance)
        internal
        view
        returns (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_)
    {
        if (block.timestamp < allowance.startDate) return (0, false, 0);

        currentPeriod_ = (block.timestamp - allowance.startDate) / allowance.periodDuration;
        isNewPeriod_ = allowance.lastClaimPeriod != currentPeriod_;
        uint256 claimed = isNewPeriod_ ? 0 : allowance.claimedInCurrentPeriod;
        availableAmount_ = allowance.periodAmount > claimed ? allowance.periodAmount - claimed : 0;
    }
}
