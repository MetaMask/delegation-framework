// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC20BalanceChangeEnforcer
 * @notice Enforces that a recipient's token balance increases by at least the expected total amount across multiple delegations
 * or decreases by at most the expected total amount across multiple delegations. In a delegation chain there can be a combination
 * of both increases and decreases and the enforcer will track the total expected change.
 * @dev Tracks initial balance and accumulates expected increases and decreases per recipient/token pair within a delegation chain
 * @dev Only operates in default execution mode
 * @dev Terms format: enforceDecrease (1 byte) + token (20 bytes) + recipient (20 bytes) + expected increase/decrease (32 bytes)
 * @dev Security considerations:
 * - State is shared between enforcers watching the same recipient/token pair
 * - A single balance change can satisfy multiple enforcer instances simultaneously
 * - Balance changes are tracked by comparing before/after balances
 */
contract ERC20BalanceChangeEnforcer is CaveatEnforcer {
    ////////////////////////////// Events //////////////////////////////
    event BalanceTracked(address indexed delegationManager, address indexed recipient, address indexed token, uint256 balance);
    event ExpectedBalanceUpdated(
        bool enforceDecrease, address indexed delegationManager, address indexed token, address indexed recipient, uint256 expected
    );
    event BalanceValidated(address indexed delegationManager, address indexed recipient, address indexed token, uint256 expected);

    ////////////////////////////// State //////////////////////////////

    struct BalanceTracker {
        uint256 balanceBefore;
        uint256 expectedIncrease;
        uint256 expectedDecrease;
    }

    mapping(bytes32 hashKey => BalanceTracker balance) public balanceTracker;

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     * @param _caller Address of the sender calling the enforcer.
     * @param _token Token being compared in the beforeHook and afterHook.
     * @param _recipient Address of the recipient whose balance is being tracked.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(address _caller, address _token, address _recipient) external pure returns (bytes32) {
        return _getHashKey(_caller, _token, _recipient);
    }

    /**
     * @notice This function caches the recipient's initial token balance and accumulates the expected increase.
     * @param _terms 73 packed bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the token
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: balance change guardrail amount (i.e., minimum increase OR maximum decrease, depending on
     * enforceDecrease)
     * @param _mode The execution mode. (Must be Default execType)
     */
    function beforeAllHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        (bool enforceDecrease_, address token_, address recipient_, uint256 expected_) = getTermsInfo(_terms);

        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_);
        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        uint256 currentBalance_ = IERC20(token_).balanceOf(recipient_);
        if (balanceTracker_.expectedDecrease == 0 && balanceTracker_.expectedIncrease == 0) {
            balanceTracker_.balanceBefore = currentBalance_;
            emit BalanceTracked(msg.sender, recipient_, token_, currentBalance_);
        } else {
            require(balanceTracker_.balanceBefore == currentBalance_, "ERC20BalanceChangeEnforcer:balance-before-differs");
        }

        if (enforceDecrease_) {
            balanceTracker_.expectedDecrease += expected_;
        } else {
            balanceTracker_.expectedIncrease += expected_;
        }

        balanceTracker[hashKey_] = balanceTracker_;

        emit ExpectedBalanceUpdated(enforceDecrease_, msg.sender, token_, recipient_, expected_);
    }

    /**
     * @notice This function validates that the recipient's token balance has increased by at least the total expected amount.
     * @param _terms 73 packed bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the token
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: balance change guardrail amount (i.e., minimum increase OR maximum decrease, depending on
     * enforceDecrease)
     */
    function afterAllHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
    {
        (, address token_, address recipient_,) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_);

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        if (balanceTracker_.expectedDecrease == 0 && balanceTracker_.expectedIncrease == 0) return; // validation has already been
            // made
        delete balanceTracker[hashKey_];

        uint256 currentBalance_ = IERC20(token_).balanceOf(recipient_);
        uint256 expected_;
        if (balanceTracker_.expectedIncrease >= balanceTracker_.expectedDecrease) {
            expected_ = balanceTracker_.expectedIncrease - balanceTracker_.expectedDecrease;
            require(
                currentBalance_ >= balanceTracker_.balanceBefore + expected_,
                "ERC20BalanceChangeEnforcer:insufficient-balance-increase"
            );
        } else {
            expected_ = balanceTracker_.expectedDecrease - balanceTracker_.expectedIncrease;
            require(
                currentBalance_ >= balanceTracker_.balanceBefore - expected_, "ERC20BalanceChangeEnforcer:exceeded-balance-decrease"
            );
        }

        emit BalanceValidated(msg.sender, recipient_, token_, expected_);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return enforceDecrease_ Boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00).
     * @return token_ The address of the token.
     * @return recipient_ The address of the recipient.
     * @return expected_ The expected balance change amount.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (bool enforceDecrease_, address token_, address recipient_, uint256 expected_)
    {
        require(_terms.length == 73, "ERC20BalanceChangeEnforcer:invalid-terms-length");
        enforceDecrease_ = _terms[0] != 0;
        token_ = address(bytes20(_terms[1:21]));
        recipient_ = address(bytes20(_terms[21:41]));
        expected_ = uint256(bytes32(_terms[41:]));
    }

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     */
    function _getHashKey(address _caller, address _token, address _recipient) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _token, _recipient));
    }
}
