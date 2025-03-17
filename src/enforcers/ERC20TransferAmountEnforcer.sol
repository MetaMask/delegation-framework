// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC20TransferAmountEnforcer
 * @dev This contract enforces the transfer limit for ERC20 tokens.
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 */
contract ERC20TransferAmountEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// State //////////////////////////////

    mapping(address delegationManager => mapping(bytes32 delegationHash => uint256 amount)) public spentMap;

    ////////////////////////////// Events //////////////////////////////
    event IncreasedSpentMap(
        address indexed sender, address indexed redeemer, bytes32 indexed delegationHash, uint256 limit, uint256 spent
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to specify a maximum sum of the contract token to transfer on their behalf.
     * @dev This function enforces the transfer limit before the transaction is performed.
     * @param _terms The ERC20 token address, and the numeric maximum amount that the recipient may transfer on the signer's
     * behalf.
     * @param _mode The execution mode. (Must be Single callType, Default execType)
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
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        (uint256 limit_, uint256 spent_) = _validateAndIncrease(_terms, _executionCallData, _delegationHash);
        emit IncreasedSpentMap(msg.sender, _redeemer, _delegationHash, limit_, spent_);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return allowedContract_ The address of the ERC20 token contract.
     * @return maxTokens_ The maximum number of tokens that the delegate is allowed to transfer.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address allowedContract_, uint256 maxTokens_) {
        require(_terms.length == 52, "ERC20TransferAmountEnforcer:invalid-terms-length");

        allowedContract_ = address((bytes20(_terms[:20])));
        maxTokens_ = uint256(bytes32(_terms[20:]));
    }

    /**
     * @notice Returns the amount of tokens that the delegator has already spent.
     * @param _terms The ERC20 token address, and the numeric maximum amount that the recipient may transfer
     * @param _executionCallData The transaction the delegate might try to perform.
     * @param _delegationHash The hash of the delegation being operated on.
     * @return limit_ The maximum amount of tokens that the delegator is allowed to spend.
     * @return spent_ The amount of tokens that the delegator has spent.
     */
    function _validateAndIncrease(
        bytes calldata _terms,
        bytes calldata _executionCallData,
        bytes32 _delegationHash
    )
        internal
        returns (uint256 limit_, uint256 spent_)
    {
        (address target_,, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(callData_.length == 68, "ERC20TransferAmountEnforcer:invalid-execution-length");

        address allowedContract_;
        (allowedContract_, limit_) = getTermsInfo(_terms);

        require(allowedContract_ == target_, "ERC20TransferAmountEnforcer:invalid-contract");

        require(bytes4(callData_[0:4]) == IERC20.transfer.selector, "ERC20TransferAmountEnforcer:invalid-method");

        spent_ = spentMap[msg.sender][_delegationHash] += uint256(bytes32(callData_[36:68]));
        require(spent_ <= limit_, "ERC20TransferAmountEnforcer:allowance-exceeded");
    }
}
