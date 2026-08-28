// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { MetaSwapForwardingAdapter } from "../helpers/MetaSwapForwardingAdapter.sol";
import { CallType, Execution, ModeCode } from "../utils/Types.sol";
import { CALLTYPE_BATCH } from "../utils/Constants.sol";

/**
 * @title MetaSwapPrefundEnforcer
 * @notice Enforces a one-shot input transfer followed by a call to an immutable MetaSwap forwarding adapter.
 * @dev ERC20 input is transferred with `transfer(adapter, amount)`. Native input is transferred with an empty
 *      call to the adapter carrying the exact amount. The second execution must call `swap` on the adapter and
 *      declare the same input token and amount. The adapter validates the signed route and settlement.
 */
contract MetaSwapPrefundEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    uint256 private constant API_QUOTE_OFFSET = 5 * 32;
    uint256 private constant MIN_SWAP_CALLDATA_LENGTH = 4 + API_QUOTE_OFFSET + 3 * 32;

    struct Terms {
        address tokenIn;
        uint256 tokenInAmount;
    }

    MetaSwapForwardingAdapter public immutable adapter;

    mapping(address manager => mapping(bytes32 delegationHash => bool used)) public usedDelegations;

    event DelegationExecuted(address indexed delegationManager, bytes32 indexed delegationHash, address indexed delegator);

    error DelegationAlreadyUsed();
    error InvalidBatchLength();
    error InvalidCallType();
    error InvalidPrefundCall();
    error InvalidSwapCall();
    error InvalidZeroAddress();
    error InvalidZeroAmount();

    /**
     * @notice Binds this enforcer to one forwarding adapter.
     */
    constructor(MetaSwapForwardingAdapter _adapter) {
        if (address(_adapter) == address(0)) revert InvalidZeroAddress();
        adapter = _adapter;
    }

    /**
     * @notice Validates an atomic prefund-and-swap batch.
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
        onlyDefaultExecutionMode(_mode)
    {
        if (usedDelegations[msg.sender][_delegationHash]) revert DelegationAlreadyUsed();
        if (CallType.unwrap(_mode.getCallType()) != CallType.unwrap(CALLTYPE_BATCH)) revert InvalidCallType();

        Terms memory terms_ = abi.decode(_terms, (Terms));
        if (terms_.tokenInAmount == 0) revert InvalidZeroAmount();

        Execution[] calldata executions_ = _executionCallData.decodeBatch();
        if (executions_.length != 2) revert InvalidBatchLength();

        _validatePrefund(executions_[0], terms_);
        _validateSwap(executions_[1], terms_);

        usedDelegations[msg.sender][_delegationHash] = true;
        emit DelegationExecuted(msg.sender, _delegationHash, _delegator);
    }

    function _validatePrefund(Execution calldata _execution, Terms memory _terms) private view {
        address adapter_ = address(adapter);
        if (_terms.tokenIn == address(0)) {
            if (_execution.target != adapter_ || _execution.value != _terms.tokenInAmount || _execution.callData.length != 0) {
                revert InvalidPrefundCall();
            }
            return;
        }

        if (_execution.target != _terms.tokenIn || _execution.value != 0 || _execution.callData.length != 68) {
            revert InvalidPrefundCall();
        }

        bytes calldata callData_ = _execution.callData;
        if (bytes4(callData_[:4]) != IERC20.transfer.selector) revert InvalidPrefundCall();

        address recipient_;
        uint256 amount_;
        assembly ("memory-safe") {
            recipient_ := and(calldataload(add(callData_.offset, 4)), 0xffffffffffffffffffffffffffffffffffffffff)
            amount_ := calldataload(add(callData_.offset, 36))
        }
        if (recipient_ != adapter_ || amount_ != _terms.tokenInAmount) revert InvalidPrefundCall();
    }

    function _validateSwap(Execution calldata _execution, Terms memory _terms) private view {
        bytes calldata callData_ = _execution.callData;
        if (
            _execution.target != address(adapter) || _execution.value != 0 || callData_.length < MIN_SWAP_CALLDATA_LENGTH
                || bytes4(callData_[:4]) != MetaSwapForwardingAdapter.swap.selector
        ) {
            revert InvalidSwapCall();
        }

        address tokenIn_;
        uint256 tokenInAmount_;
        uint256 quoteOffset_;
        assembly ("memory-safe") {
            tokenIn_ := and(calldataload(add(callData_.offset, 4)), 0xffffffffffffffffffffffffffffffffffffffff)
            tokenInAmount_ := calldataload(add(callData_.offset, 68))
            quoteOffset_ := calldataload(add(callData_.offset, 132))
        }

        if (tokenIn_ != _terms.tokenIn || tokenInAmount_ != _terms.tokenInAmount || quoteOffset_ != API_QUOTE_OFFSET) {
            revert InvalidSwapCall();
        }
    }

    /**
     * @notice Decodes prefund terms.
     */
    function getTermsInfo(bytes calldata _terms) external pure returns (Terms memory terms_) {
        terms_ = abi.decode(_terms, (Terms));
    }

    /**
     * @notice Encodes prefund terms.
     */
    function encodeTerms(Terms calldata _terms) external pure returns (bytes memory) {
        return abi.encode(_terms);
    }
}
