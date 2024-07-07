// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Action } from "../utils/Types.sol";

/**
 * @title Execution Library
 * Provides a common implementation for executing actions.
 */
library ExecutionLib {
    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when execution fails without providing a reason
    error FailedExecutionWithoutReason();

    /// @dev Error thrown when executing empty Actions array
    error InvalidActionsLength();

    ////////////////////////////// Events //////////////////////////////

    /// @dev Event emitted when an action is executed.
    event ExecutedAction(address indexed to, uint256 value, bool success, bytes errorMessage);

    /// @dev Event emitted when prefunding is sent.
    event SentPrefund(address indexed sender, uint256 amount, bool success);

    ////////////////////////////// Internal Functions //////////////////////////////

    /**
     * @notice Executes the provided Action and reverts if the execution fails.
     * @dev Ensure caller permissions are checked before calling this method
     * @param _action the Action to execute
     */
    function _execute(Action calldata _action) internal {
        (bool success_, bytes memory errorMessage_) = _action.to.call{ value: _action.value }(_action.data);

        emit ExecutedAction(_action.to, _action.value, success_, errorMessage_);

        if (!success_) {
            if (errorMessage_.length == 0) revert FailedExecutionWithoutReason();

            assembly {
                revert(add(32, errorMessage_), mload(errorMessage_))
            }
        }
    }

    /**
     * @notice Executes several Actions in order and reverts if any of the executions fail.
     * @param _actions the ordered actions to execute
     */
    function _executeBatch(Action[] calldata _actions) internal {
        uint256 actionLength = _actions.length;
        if (actionLength == 0) revert InvalidActionsLength();
        for (uint256 i = 0; i < actionLength; ++i) {
            _execute(_actions[i]);
        }
    }

    /**
     * @notice Sends the entrypoint (msg.sender) any needed funds for the transaction.
     * @param _missingAccountFunds the minimum value this method should send the entrypoint.
     *         this value MAY be zero, in case there is enough deposit, or the userOp has a paymaster.
     */
    function _payPrefund(uint256 _missingAccountFunds) internal {
        if (_missingAccountFunds != 0) {
            (bool success_,) = payable(msg.sender).call{ value: _missingAccountFunds, gas: type(uint256).max }("");
            (success_);
            //ignore failure (its EntryPoint's job to verify, not account.)
            emit SentPrefund(msg.sender, _missingAccountFunds, success_);
        }
    }
}
