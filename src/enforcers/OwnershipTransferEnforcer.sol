// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";
import { IERC173 } from "../interfaces/IERC173.sol";

/**
 * @title OwnershipTransferEnforcer
 * @dev This contract enforces the ownership transfer of ERC-173 compliant contracts.
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 */
contract OwnershipTransferEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Events //////////////////////////////
    event OwnershipTransferEnforced(
        address indexed sender, address indexed redeemer, bytes32 indexed delegationHash, address newOwner
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Enforces the ownership transfer of an ERC-173 compliant contract.
     * @dev This function enforces the ownership transfer before the transaction is performed.
     * @param _terms The address of the contract whose ownership is being transferred.
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
        address newOwner = _validateAndEnforce(_terms, _executionCallData);
        emit OwnershipTransferEnforced(msg.sender, _redeemer, _delegationHash, newOwner);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return targetContract_ The address of the ERC-173 compliant contract.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address targetContract_) {
        require(_terms.length == 20, "OwnershipTransferEnforcer:invalid-terms-length");
        targetContract_ = address(bytes20(_terms));
    }
    /**
     * @notice Validates the ownership transfer and enforces the terms.
     * @param _terms The address of the contract whose ownership is being transferred.
     * @param _executionCallData The transaction the delegate might try to perform.
     * @return newOwner_ The address of the new owner.
     */

    function _validateAndEnforce(
        bytes calldata _terms,
        bytes calldata _executionCallData
    )
        internal
        pure
        returns (address newOwner_)
    {
        (address target_,, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(callData_.length == 36, "OwnershipTransferEnforcer:invalid-execution-length");

        bytes4 selector_ = bytes4(callData_[0:4]);
        require(selector_ == IERC173.transferOwnership.selector, "OwnershipTransferEnforcer:invalid-method");

        address targetContract_ = getTermsInfo(_terms);
        require(targetContract_ == target_, "OwnershipTransferEnforcer:invalid-contract");

        newOwner_ = address(uint160(uint256(bytes32(callData_[4:36]))));
    }
}
