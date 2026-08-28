// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { MetaSwapAdapter } from "../helpers/MetaSwapAdapter.sol";
import { CallType, Execution, ModeCode } from "../utils/Types.sol";
import { CALLTYPE_BATCH, CALLTYPE_SINGLE } from "../utils/Constants.sol";

/**
 * @title MetaSwapTransferSwapEnforcer
 * @notice Enforces a one-shot MetaSwap adapter execution.
 * @dev MetaSwap API calldata remains flexible and is authenticated and decoded by the adapter.
 *      ERC-20 input requires an exact transfer-and-swap batch. Native input requires a single swap call whose
 *      execution value equals `tokenInAmount`. Address zero represents the native token.
 */
contract MetaSwapTransferSwapEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    uint256 private constant API_QUOTE_OFFSET = 5 * 32;
    uint256 private constant MIN_SWAP_CALLDATA_LENGTH = 4 + API_QUOTE_OFFSET + 3 * 32;

    struct Terms {
        address adapter;
        address tokenIn;
        address tokenOut;
        uint256 tokenInAmount;
        uint256 minTokenOut;
    }

    mapping(address manager => mapping(bytes32 delegationHash => bool used)) public usedDelegations;

    event DelegationExecuted(address indexed delegationManager, bytes32 indexed delegationHash, address indexed delegator);

    error DelegationAlreadyUsed();
    error IdenticalTokens();
    error InvalidBatchLength();
    error InvalidCallType();
    error InvalidSwapCall();
    error InvalidTransferCall();
    error InvalidZeroAddress();
    error InvalidZeroAmount();

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
        onlyDefaultExecutionMode(_mode)
    {
        if (usedDelegations[msg.sender][_delegationHash]) revert DelegationAlreadyUsed();

        Terms memory terms_ = abi.decode(_terms, (Terms));
        if (terms_.adapter == address(0)) revert InvalidZeroAddress();
        if (terms_.tokenInAmount == 0 || terms_.minTokenOut == 0) revert InvalidZeroAmount();
        if (terms_.tokenIn == terms_.tokenOut) revert IdenticalTokens();

        if (terms_.tokenIn == address(0)) {
            if (CallType.unwrap(_mode.getCallType()) != CallType.unwrap(CALLTYPE_SINGLE)) revert InvalidCallType();
            (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();
            _validateSwap(target_, value_, callData_, terms_);
        } else {
            if (CallType.unwrap(_mode.getCallType()) != CallType.unwrap(CALLTYPE_BATCH)) revert InvalidCallType();
            Execution[] calldata executions_ = _executionCallData.decodeBatch();
            if (executions_.length != 2) revert InvalidBatchLength();

            _validateTransfer(executions_[0], terms_);
            _validateSwap(executions_[1].target, executions_[1].value, executions_[1].callData, terms_);
        }

        usedDelegations[msg.sender][_delegationHash] = true;

        emit DelegationExecuted(msg.sender, _delegationHash, _delegator);
    }

    function _validateTransfer(Execution calldata _execution, Terms memory _terms) private pure {
        if (_execution.target != _terms.tokenIn || _execution.value != 0 || _execution.callData.length != 68) {
            revert InvalidTransferCall();
        }
        if (bytes4(_execution.callData[:4]) != IERC20.transfer.selector) revert InvalidTransferCall();

        bytes calldata transferCallData_ = _execution.callData;
        address recipient_;
        uint256 amount_;
        assembly ("memory-safe") {
            recipient_ := and(calldataload(add(transferCallData_.offset, 4)), 0xffffffffffffffffffffffffffffffffffffffff)
            amount_ := calldataload(add(transferCallData_.offset, 36))
        }
        if (recipient_ != _terms.adapter || amount_ != _terms.tokenInAmount) revert InvalidTransferCall();
    }

    function _validateSwap(address _target, uint256 _value, bytes calldata _callData, Terms memory _terms) private pure {
        uint256 expectedValue_ = _terms.tokenIn == address(0) ? _terms.tokenInAmount : 0;
        if (_target != _terms.adapter || _value != expectedValue_ || _callData.length < MIN_SWAP_CALLDATA_LENGTH) {
            revert InvalidSwapCall();
        }
        if (bytes4(_callData[:4]) != MetaSwapAdapter.swap.selector) revert InvalidSwapCall();

        address tokenIn_;
        address tokenOut_;
        uint256 tokenInAmount_;
        uint256 minTokenOut_;
        uint256 quoteOffset_;
        assembly ("memory-safe") {
            tokenIn_ := and(calldataload(add(_callData.offset, 4)), 0xffffffffffffffffffffffffffffffffffffffff)
            tokenOut_ := and(calldataload(add(_callData.offset, 36)), 0xffffffffffffffffffffffffffffffffffffffff)
            tokenInAmount_ := calldataload(add(_callData.offset, 68))
            minTokenOut_ := calldataload(add(_callData.offset, 100))
            quoteOffset_ := calldataload(add(_callData.offset, 132))
        }

        // Enforce the canonical five-word ABI head without copying the dynamic quote into memory.
        if (quoteOffset_ != API_QUOTE_OFFSET) revert InvalidSwapCall();

        if (
            tokenIn_ != _terms.tokenIn || tokenOut_ != _terms.tokenOut || tokenInAmount_ != _terms.tokenInAmount
                || minTokenOut_ < _terms.minTokenOut
        ) {
            revert InvalidSwapCall();
        }
    }

    function getTermsInfo(bytes calldata _terms) external pure returns (Terms memory terms_) {
        terms_ = abi.decode(_terms, (Terms));
    }

    function encodeTerms(Terms calldata _terms) external pure returns (bytes memory) {
        return abi.encode(_terms);
    }
}
