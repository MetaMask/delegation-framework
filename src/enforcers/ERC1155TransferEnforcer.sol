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
 * @dev The enforcer tracks spent amounts per token ID to enforce transfer limits.
 */
contract ERC1155TransferEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    /// @notice Maps delegation manager address => delegation hash => token ID => spent amount
    mapping(address delegationManager => mapping(bytes32 delegationHash => mapping(uint256 tokenId => uint256 amount))) public
        spentMap;

    ////////////////////////////// Events //////////////////////////////
    /// @notice Emitted when the spent amount for a token ID is increased
    /// @param sender The address of the delegation manager
    /// @param delegationHash The hash of the delegation
    /// @param tokenId The ID of the token being transferred
    /// @param limit The maximum amount allowed for this token ID
    /// @param spent The new total amount spent for this token ID
    event IncreasedSpentMap(address indexed sender, bytes32 indexed delegationHash, uint256 tokenId, uint256 limit, uint256 spent);

    /**
     * @notice Enforces that the contract and tokenIds are permitted for transfer
     * @dev Validates that the transfer execution matches the permitted terms and updates spent amounts
     * @param _terms encoded terms containing transfer type, contract address, token IDs and amounts
     * @param _mode The execution mode. (Must be Single callType, Default execType)
     * @param _executionCallData the call data of the transferFrom call
     * @param _delegationHash the hash of the delegation being operated on
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        virtual
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        _validateTransfer(_terms, _delegationHash, _executionCallData);
    }

    /**
     * @notice Decodes the terms to get the transfer type, permitted contract and token IDs
     * @dev Validates the terms length and structure
     * @param _terms The encoded terms containing transfer type, contract address and token IDs
     * @return _isBatch The transfer type flag
     * @return _permittedContract The address of the permitted ERC1155 contract
     * @return _permittedIds Array of token IDs
     * @return _permittedAmounts Array of token amounts
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (bool _isBatch, address _permittedContract, uint256[] memory _permittedIds, uint256[] memory _permittedAmounts)
    {
        if (_terms.length == 96) {
            _permittedIds = new uint256[](1);
            _permittedAmounts = new uint256[](1);
            (_permittedContract, _permittedIds[0], _permittedAmounts[0]) = abi.decode(_terms, (address, uint256, uint256));
        } else if (_terms.length >= 224) {
            _isBatch = true;
            (_permittedContract, _permittedIds, _permittedAmounts) = abi.decode(_terms, (address, uint256[], uint256[]));
        } else {
            revert("ERC1155TransferEnforcer:invalid-terms-length");
        }

        if (_permittedContract == address(0)) revert("ERC1155TransferEnforcer:invalid-contract-address");
        if (_permittedIds.length != _permittedAmounts.length) revert("ERC1155TransferEnforcer:invalid-ids-values-length");
    }

    /**
     * @notice Validates that the transfer execution matches the permitted terms
     * @dev Checks that the contract, token IDs and amounts match what is permitted in the terms
     * @param _terms The encoded terms containing transfer type, contract address, token IDs and amounts
     * @param _delegationHash The hash of the delegation being operated on
     * @param _executionCallData The encoded execution data containing the transfer details
     */
    function _validateTransfer(bytes calldata _terms, bytes32 _delegationHash, bytes calldata _executionCallData) internal {
        (bool isBatch_, address permittedContract_, uint256[] memory permittedTokenIds_, uint256[] memory permittedAmounts_) =
            getTermsInfo(_terms);
        (address target_, uint256 value_, bytes calldata callData_) = ExecutionLib.decodeSingle(_executionCallData);

        if (value_ != 0) revert("ERC1155TransferEnforcer:invalid-value");
        if (callData_.length != 196 && callData_.length < 324) revert("ERC1155TransferEnforcer:invalid-calldata-length");
        if (target_ != permittedContract_) revert("ERC1155TransferEnforcer:unauthorized-contract-target");

        bytes4 selector_ = bytes4(callData_[0:4]);
        if (isBatch_ && selector_ != IERC1155.safeBatchTransferFrom.selector) {
            revert("ERC1155TransferEnforcer:unauthorized-selector-batch");
        }
        if (!isBatch_ && selector_ != IERC1155.safeTransferFrom.selector) {
            revert("ERC1155TransferEnforcer:unauthorized-selector-single");
        }

        if (isBatch_) {
            _validateBatchTransfer(_delegationHash, callData_, permittedTokenIds_, permittedAmounts_);
        } else {
            _validateSingleTransfer(_delegationHash, callData_, permittedTokenIds_[0], permittedAmounts_[0]);
        }
    }

    /**
     * @notice Validates a single ERC1155 token transfer against permitted parameters
     * @dev Checks that the transfer addresses are valid and matches token ID and amount against permitted values
     * @param _delegationHash The hash of the delegation being operated on
     * @param _callData The encoded transfer function call data
     * @param _permittedTokenId The token ID that is permitted to be transferred
     * @param _permittedAmount The amount that is permitted to be transferred
     */
    function _validateSingleTransfer(
        bytes32 _delegationHash,
        bytes calldata _callData,
        uint256 _permittedTokenId,
        uint256 _permittedAmount
    )
        internal
    {
        (address from_, address to_, uint256 id_, uint256 amount_,) =
            abi.decode(_callData[4:], (address, address, uint256, uint256, bytes));

        if (from_ == address(0) || to_ == address(0)) {
            revert("ERC1155TransferEnforcer:invalid-address");
        }
        if (_permittedTokenId != id_) {
            revert("ERC1155TransferEnforcer:unauthorized-token-id");
        }
        _increaseSpentMap(_delegationHash, id_, amount_, _permittedAmount);
    }

    /**
     * @notice Validates a batch ERC1155 token transfer against permitted parameters
     * @dev Checks that all token IDs in the batch are permitted and their amounts don't exceed limits
     * @param _delegationHash The hash of the delegation being operated on
     * @param _callData The encoded batch transfer function call data
     * @param _permittedTokenIds Array of permitted token IDs
     * @param _permittedAmounts Array of permitted amounts for each token ID
     */
    function _validateBatchTransfer(
        bytes32 _delegationHash,
        bytes calldata _callData,
        uint256[] memory _permittedTokenIds,
        uint256[] memory _permittedAmounts
    )
        internal
    {
        (address from_, address to_, uint256[] memory ids_, uint256[] memory amounts_,) =
            abi.decode(_callData[4:], (address, address, uint256[], uint256[], bytes));

        if (from_ == address(0) || to_ == address(0)) {
            revert("ERC1155TransferEnforcer:invalid-address");
        }

        uint256 idsLength_ = ids_.length;
        uint256 permittedTokenIdsLength_ = _permittedTokenIds.length;

        // Check if all token IDs in the batch are permitted
        for (uint256 i = 0; i < idsLength_; i++) {
            bool isPermitted_ = false;
            for (uint256 j = 0; j < permittedTokenIdsLength_; j++) {
                if (ids_[i] == _permittedTokenIds[j]) {
                    _increaseSpentMap(_delegationHash, ids_[i], amounts_[i], _permittedAmounts[j]);
                    isPermitted_ = true;
                    break;
                }
            }
            if (!isPermitted_) {
                revert("ERC1155TransferEnforcer:unauthorized-token-id");
            }
        }
    }

    /**
     * @notice Updates and validates the spent amount for a token ID
     * @dev Increments the spent amount and checks against permitted limit
     * @param _delegationHash The hash of the delegation being operated on
     * @param _id The token ID being tracked
     * @param _amount The amount to increase the spent tracker by
     * @param _permittedAmount The maximum amount allowed for this token ID
     */
    function _increaseSpentMap(bytes32 _delegationHash, uint256 _id, uint256 _amount, uint256 _permittedAmount) private {
        uint256 spent_ = spentMap[msg.sender][_delegationHash][_id] += _amount;
        if (spent_ > _permittedAmount) {
            revert("ERC1155TransferEnforcer:unauthorized-amount");
        }
        emit IncreasedSpentMap(msg.sender, _delegationHash, _id, _permittedAmount, spent_);
    }
}
