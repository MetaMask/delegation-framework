// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

/**
 * @title ERC1155TransferEnforcer
 * @notice This enforcer restricts the execution to the transfer of specific ERC1155 tokens.
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 * Supports both single and batch transfers. The terms include a boolean flag indicating the transfer type.
 */
contract ERC1155TransferEnforcer is CaveatEnforcer {
    bytes4 private constant SAFE_BATCH_TRANSFER_FROM_SELECTOR =
        bytes4(keccak256("safeBatchTransferFrom(address,address,uint256[],uint256[],bytes)"));

    /**
     * @notice Enforces that the contract and tokenIds are permitted for transfer
     * @param _terms abi encoded (bool isBatch, address contract, uint256[] tokenIds)
     * @param _mode The execution mode. (Must be Single callType, Default execType)
     * @param _executionCallData the call data of the transferFrom call
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32,
        address,
        address
    )
        public
        virtual
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        _validateTransfer(_terms, _executionCallData);
    }

    /**
     * @notice Decodes the terms to get the transfer type, permitted contract and token IDs
     * @param _terms The encoded terms containing transfer type, contract address and token IDs
     * @return _isBatch The transfer type flag
     * @return _permittedContract The address of the permitted ERC1155 contract
     * @return _ids Array of token IDs
     * @return _values Array of token amounts
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (bool _isBatch, address _permittedContract, uint256[] memory _ids, uint256[] memory _values)
    {
        if (_isBatch) {
            (_isBatch, _permittedContract, _ids, _values) = abi.decode(_terms, (bool, address, uint256[], uint256[]));
        } else {
            uint256 id_;
            uint256 value_;
            _ids = new uint256[](1);
            _values = new uint256[](1);
            (_isBatch, _permittedContract, id_, value_) = abi.decode(_terms, (bool, address, uint256, uint256));
            _ids[0] = id_;
            _values[0] = value_;
        }

        if (_ids.length != _values.length) revert("ERC1155TransferEnforcer:invalid-ids-values-length");
    }

    /**
     * @notice Validates that the transfer execution matches the permitted terms
     * @dev Checks that the contract, token IDs and amounts match what is permitted in the terms
     * @param _terms The encoded terms containing transfer type, contract address, token IDs and amounts
     * @param _executionCallData The encoded execution data containing the transfer details
     */
    function _validateTransfer(bytes calldata _terms, bytes calldata _executionCallData) internal pure {
        (bool isBatch_, address permittedContract_, uint256[] memory permittedTokenIds_, uint256[] memory permittedValues_) =
            getTermsInfo(_terms);
        (address target_, uint256 value_, bytes calldata callData_) = ExecutionLib.decodeSingle(_executionCallData);

        if (value_ != 0) revert("ERC1155TransferEnforcer:invalid-value");

        if (callData_.length < 4) revert("ERC1155TransferEnforcer:invalid-calldata-length");

        if (target_ != permittedContract_) {
            revert("ERC1155TransferEnforcer:unauthorized-contract-target");
        }

        bytes4 selector_ = bytes4(callData_[0:4]);
        if (isBatch_ && selector_ != SAFE_BATCH_TRANSFER_FROM_SELECTOR) {
            revert("ERC1155TransferEnforcer:unauthorized-selector-batch");
        } else if (!isBatch_ && selector_ != IERC1155.safeTransferFrom.selector) {
            revert("ERC1155TransferEnforcer:unauthorized-selector-single");
        }

        if (isBatch_) {
            // Batch transfer
            (address from_, address to_, uint256[] memory ids_, uint256[] memory amounts_,) =
                abi.decode(callData_[4:], (address, address, uint256[], uint256[], bytes));

            if (from_ == address(0) || to_ == address(0)) {
                revert("ERC1155TransferEnforcer:invalid-address");
            }

            _validateBatchTransfer(ids_, amounts_, permittedTokenIds_, permittedValues_);
        } else {
            // Single transfer
            (address from_, address to_, uint256 id_, uint256 amount_,) =
                abi.decode(callData_[4:], (address, address, uint256, uint256, bytes));

            if (from_ == address(0) || to_ == address(0)) {
                revert("ERC1155TransferEnforcer:invalid-address");
            }
            if (permittedTokenIds_[0] != id_) {
                revert("ERC1155TransferEnforcer:unauthorized-token-id");
            }
            if (permittedValues_[0] != amount_) {
                revert("ERC1155TransferEnforcer:unauthorized-amount");
            }
        }
    }

    /**
     * @notice Validates that all token IDs and amounts in a batch transfer are permitted
     * @dev Checks each token ID in the transfer against the permitted token IDs and their corresponding amounts
     * @param _ids Array of token IDs being transferred
     * @param _values Array of amounts being transferred for each token ID
     * @param _permittedTokenIds Array of permitted token IDs
     * @param _permittedValues Array of permitted amounts for each token ID
     */
    function _validateBatchTransfer(
        uint256[] memory _ids,
        uint256[] memory _values,
        uint256[] memory _permittedTokenIds,
        uint256[] memory _permittedValues
    )
        internal
        pure
    {
        uint256 idsLength_ = _ids.length;
        uint256 permittedTokenIdsLength_ = _permittedTokenIds.length;

        // Check if all token IDs in the batch are permitted
        for (uint256 i = 0; i < idsLength_; i++) {
            bool isPermitted_ = false;
            for (uint256 j = 0; j < permittedTokenIdsLength_; j++) {
                if (_permittedTokenIds[j] == _ids[i]) {
                    if (_permittedValues[j] != _values[i]) revert("ERC1155TransferEnforcer:unauthorized-amount");
                    isPermitted_ = true;
                    break;
                }
            }
            if (!isPermitted_) {
                revert("ERC1155TransferEnforcer:unauthorized-token-id");
            }
        }
    }
}
