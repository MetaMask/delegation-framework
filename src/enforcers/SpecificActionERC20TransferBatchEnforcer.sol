// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode, Execution } from "../utils/Types.sol";

/**
 * @title SpecificActionERC20TransferBatchEnforcer
 * @dev This enforcer validates a batch of exactly 2 transactions where:
 * 1. First transaction must match specific target, method and calldata
 * 2. Second transaction must be an ERC20 transfer with specific parameters
 * @dev The delegation can only be executed once
 * @dev This enforcer operates only in batch execution call type and with default execution mode.
 */
contract SpecificActionERC20TransferBatchEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    ////////////////////////////// State //////////////////////////////

    // Tracks if a delegation has been executed
    mapping(address delegationManager => mapping(bytes32 delegationHash => bool used)) public usedDelegations;

    ////////////////////////////// Events //////////////////////////////

    event DelegationExecuted(address indexed delegationManager, bytes32 indexed delegationHash, address indexed delegator);

    ////////////////////////////// Structs //////////////////////////////

    struct TermsData {
        address tokenAddress;
        address recipient;
        uint256 amount;
        address firstTarget;
        bytes firstCalldata;
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Enforces the batch execution rules
     * @param _terms The encoded terms containing:
     *   - ERC20 token address (20 bytes)
     *   - Transfer recipient address (20 bytes)
     *   - Transfer amount (32 bytes)
     *   - First transaction target address (20 bytes)
     *   - First transaction calldata (remaining bytes)
     * @param _mode The execution mode. (Must be Batch callType, Default execType)
     * @param _executionCallData The batch execution calldata
     * @param _delegationHash The delegation hash
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address
    )
        public
        override
        onlyBatchCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        // Check delegation hasn't been used
        if (usedDelegations[msg.sender][_delegationHash]) {
            revert("SpecificActionERC20TransferBatchEnforcer:delegation-already-used");
        }

        // Mark delegation as used
        usedDelegations[msg.sender][_delegationHash] = true;

        // Decode the batch executions
        Execution[] calldata executions_ = _executionCallData.decodeBatch();

        // Validate batch size
        if (executions_.length != 2) {
            revert("SpecificActionERC20TransferBatchEnforcer:invalid-batch-size");
        }

        // Decode terms into struct
        TermsData memory terms_ = getTermsInfo(_terms);

        // Validate first transaction
        if (
            executions_[0].target != terms_.firstTarget || executions_[0].value != 0
                || keccak256(executions_[0].callData) != keccak256(terms_.firstCalldata)
        ) {
            revert("SpecificActionERC20TransferBatchEnforcer:invalid-first-transaction");
        }

        // Validate second transaction
        if (
            executions_[1].target != terms_.tokenAddress || executions_[1].value != 0 || executions_[1].callData.length != 68
                || bytes4(executions_[1].callData[0:4]) != IERC20.transfer.selector
                || address(uint160(uint256(bytes32(executions_[1].callData[4:36])))) != terms_.recipient
                || uint256(bytes32(executions_[1].callData[36:68])) != terms_.amount
        ) {
            revert("SpecificActionERC20TransferBatchEnforcer:invalid-second-transaction");
        }

        emit DelegationExecuted(msg.sender, _delegationHash, _delegator);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer
     * @param _terms The encoded terms
     * @return termsData_ The decoded terms data
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (TermsData memory termsData_) {
        // Require minimum length: 20 + 20 + 32 + 20 = 92 bytes
        require(_terms.length >= 92, "SpecificActionERC20TransferBatchEnforcer:invalid-terms-length");

        // First 20 bytes is token address
        termsData_.tokenAddress = address(bytes20(_terms[0:20]));

        // Next 20 bytes is recipient address
        termsData_.recipient = address(bytes20(_terms[20:40]));

        // Next 32 bytes is amount
        termsData_.amount = uint256(bytes32(_terms[40:72]));

        // Next 20 bytes is first target
        termsData_.firstTarget = address(bytes20(_terms[72:92]));

        // Remaining bytes is firstCalldata
        termsData_.firstCalldata = _terms[92:];
    }
}
