// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title StreamingERC20Enforcer
 * @dev This contract enforces a streaming transfer limit for ERC20 tokens.
 * @dev The allowance increases linearly over time from a specified start time.
 * @dev This caveat enforcer only works when the execution is in single mode.
 */
contract StreamingERC20Enforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// State //////////////////////////////

    struct StreamingAllowance {
        uint256 initialAmount;
        uint256 amountPerSecond;
        uint256 startTime;
        uint256 lastUpdateTimestamp;
        uint256 spent;
    }

    mapping(address delegationManager => mapping(bytes32 delegationHash => StreamingAllowance)) public streamingAllowances;

    ////////////////////////////// Events //////////////////////////////
    event IncreasedSpentMap(
        address indexed sender,
        address indexed redeemer,
        bytes32 indexed delegationHash,
        uint256 initialLimit,
        uint256 amountPerSecond,
        uint256 startTime,
        uint256 spent
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to specify a streaming maximum sum of the contract token to transfer on their behalf.
     * @dev This function enforces the streaming transfer limit before the transaction is performed.
     * @param _terms The ERC20 token address, initial amount, amount per second, and start time for the streaming allowance.
     * @param _mode The mode of the execution.
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
        (uint256 initialLimit_, uint256 amountPerSecond_, uint256 startTime_, uint256 spent_) = _validateAndIncrease(_terms, _executionCallData, _delegationHash);
        emit IncreasedSpentMap(msg.sender, _redeemer, _delegationHash, initialLimit_, amountPerSecond_, startTime_, spent_);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return allowedContract_ The address of the ERC20 token contract.
     * @return initialAmount_ The initial amount of tokens that the delegate is allowed to transfer.
     * @return amountPerSecond_ The rate at which the allowance increases per second.
     * @return startTime_ The timestamp from which the allowance streaming begins.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address allowedContract_, uint256 initialAmount_, uint256 amountPerSecond_, uint256 startTime_) {
        require(_terms.length == 116, "StreamingERC20Enforcer:invalid-terms-length");

        allowedContract_ = address((bytes20(_terms[:20])));
        initialAmount_ = uint256(bytes32(_terms[20:52]));
        amountPerSecond_ = uint256(bytes32(_terms[52:84]));
        startTime_ = uint256(bytes32(_terms[84:]));
    }

    /**
     * @notice Returns the current allowance and updates the spent amount.
     * @param _terms The ERC20 token address, initial amount, amount per second, and start time.
     * @param _executionCallData The transaction the delegate might try to perform.
     * @param _delegationHash The hash of the delegation being operated on.
     * @return initialLimit_ The initial amount of tokens that the delegator is allowed to spend.
     * @return amountPerSecond_ The rate at which the allowance increases per second.
     * @return startTime_ The timestamp from which the allowance streaming begins.
     * @return spent_ The updated amount of tokens that the delegator has spent.
     */
    function _validateAndIncrease(
        bytes calldata _terms,
        bytes calldata _executionCallData,
        bytes32 _delegationHash
    )
        internal
        returns (uint256 initialLimit_, uint256 amountPerSecond_, uint256 startTime_, uint256 spent_)
    {
        (address target_,, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(callData_.length == 68, "StreamingERC20Enforcer:invalid-execution-length");

        address allowedContract_;
        (allowedContract_, initialLimit_, amountPerSecond_, startTime_) = getTermsInfo(_terms);

        require(allowedContract_ == target_, "StreamingERC20Enforcer:invalid-contract");
        require(bytes4(callData_[0:4]) == IERC20.transfer.selector, "StreamingERC20Enforcer:invalid-method");

        StreamingAllowance storage allowance = streamingAllowances[msg.sender][_delegationHash];
        
        if (allowance.lastUpdateTimestamp == 0) {
            // First use of this delegation
            allowance.initialAmount = initialLimit_;
            allowance.amountPerSecond = amountPerSecond_;
            allowance.startTime = startTime_;
            allowance.lastUpdateTimestamp = block.timestamp;
            allowance.spent = 0;
        }

        uint256 elapsedTime = block.timestamp > allowance.startTime ? block.timestamp - allowance.startTime : 0;
        uint256 currentAllowance = allowance.initialAmount + (allowance.amountPerSecond * elapsedTime);

        uint256 transferAmount = uint256(bytes32(callData_[36:68]));
        require(allowance.spent + transferAmount <= currentAllowance, "StreamingERC20Enforcer:allowance-exceeded");

        allowance.spent += transferAmount;
        allowance.lastUpdateTimestamp = block.timestamp;
        spent_ = allowance.spent;
    }
}
