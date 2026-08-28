// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "../../enforcers/CaveatEnforcer.sol";
import { Execution, ModeCode } from "../../utils/Types.sol";
import { SimpleMetaSwapAdapter } from "./SimpleMetaSwapAdapter.sol";

/**
 * @title MetaSwapLimitOrderEnforcer
 * @notice Enforces a two-call limit-order batch:
 *         (1) exact ERC20 transfer from maker to adapter;
 *         (2) adapter swap with the signed pair, input, and minimum output.
 * @dev API route data remains flexible and is authenticated independently by the adapter.
 */
contract MetaSwapLimitOrderEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    struct Terms {
        address adapter;
        address tokenIn;
        address tokenOut;
        uint256 tokenInAmount;
        uint256 minTokenOut;
    }

    struct OutputSnapshot {
        uint256 balanceBefore;
        bool active;
    }

    mapping(address manager => mapping(bytes32 delegationHash => bool used)) public usedDelegations;
    mapping(address manager => mapping(bytes32 delegationHash => OutputSnapshot snapshot)) public outputSnapshots;

    error DelegationAlreadyUsed();
    error InvalidBatchLength();
    error InvalidSwapCall();
    error InvalidTransferCall();
    error OutputSnapshotActive();
    error InsufficientOutput(uint256 minimum, uint256 received);

    /**
     * @notice Validates the exact transfer and bounded adapter call before execution.
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
        if (usedDelegations[msg.sender][_delegationHash]) revert DelegationAlreadyUsed();

        Terms memory terms_ = abi.decode(_terms, (Terms));
        Execution[] calldata executions_ = _executionCallData.decodeBatch();
        if (executions_.length != 2) revert InvalidBatchLength();

        _validateTransfer(executions_[0], terms_);
        _validateSwap(executions_[1], terms_);

        OutputSnapshot storage snapshot_ = outputSnapshots[msg.sender][_delegationHash];
        if (snapshot_.active) revert OutputSnapshotActive();
        snapshot_.active = true;
        snapshot_.balanceBefore = IERC20(terms_.tokenOut).balanceOf(_delegator);
        usedDelegations[msg.sender][_delegationHash] = true;
    }

    /**
     * @notice Proves that the maker received at least the signed minimum output.
     */
    function afterHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32 _delegationHash,
        address _delegator,
        address
    )
        public
        override
    {
        Terms memory terms_ = abi.decode(_terms, (Terms));
        OutputSnapshot memory snapshot_ = outputSnapshots[msg.sender][_delegationHash];
        delete outputSnapshots[msg.sender][_delegationHash];

        uint256 received_ = IERC20(terms_.tokenOut).balanceOf(_delegator) - snapshot_.balanceBefore;
        if (received_ < terms_.minTokenOut) revert InsufficientOutput(terms_.minTokenOut, received_);
    }

    function _validateTransfer(Execution calldata _execution, Terms memory _terms) private pure {
        if (_execution.target != _terms.tokenIn || _execution.value != 0) revert InvalidTransferCall();
        if (bytes4(_execution.callData[:4]) != IERC20.transfer.selector) revert InvalidTransferCall();
        (address receiver_, uint256 amount_) = abi.decode(_execution.callData[4:], (address, uint256));
        if (receiver_ != _terms.adapter || amount_ != _terms.tokenInAmount) revert InvalidTransferCall();
    }

    function _validateSwap(Execution calldata _execution, Terms memory _terms) private pure {
        if (_execution.target != _terms.adapter || _execution.value != 0) revert InvalidSwapCall();
        if (bytes4(_execution.callData[:4]) != SimpleMetaSwapAdapter.swap.selector) revert InvalidSwapCall();

        (
            IERC20 tokenIn_,
            IERC20 tokenOut_,
            uint256 tokenInAmount_,
            uint256 minTokenOut_,
            SimpleMetaSwapAdapter.ApiQuote memory quote_
        ) = abi.decode(
            _execution.callData[4:], (IERC20, IERC20, uint256, uint256, SimpleMetaSwapAdapter.ApiQuote)
        );
        quote_;

        if (
            address(tokenIn_) != _terms.tokenIn || address(tokenOut_) != _terms.tokenOut
                || tokenInAmount_ != _terms.tokenInAmount || minTokenOut_ < _terms.minTokenOut
        ) {
            revert InvalidSwapCall();
        }
    }

    /**
     * @notice Encodes the maker-signed caveat terms.
     */
    function encodeTerms(Terms calldata _terms) external pure returns (bytes memory) {
        return abi.encode(_terms);
    }
}
