// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { MetaSwapLimitOrderAdapter } from "./MetaSwapLimitOrderAdapter.sol";
import { Execution, ModeCode, CallType, ExecType } from "../../utils/Types.sol";
import { CALLTYPE_BATCH, EXECTYPE_DEFAULT } from "../../utils/Constants.sol";

/**
 * @title MetaSwapLimitOrderLib
 * @notice Shared validation for one-shot MetaSwap limit orders.
 */
library MetaSwapLimitOrderLib {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    struct Terms {
        address adapter;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        uint64 validAfter;
        uint64 validUntil;
    }

    error IdenticalTokens();
    error InvalidAmount();
    error InvalidMode();
    error InvalidSwapCall();
    error InvalidTerms();
    error InvalidTransferCall();
    error InvalidZeroAddress();
    error OrderExpired();
    error OrderNotYetValid();

    /**
     * @notice Validates signed order terms and their time window.
     * @param _terms Maker-signed order restrictions.
     */
    function validateTerms(Terms memory _terms) internal view {
        if (_terms.adapter == address(0) || _terms.tokenIn == address(0) || _terms.tokenOut == address(0)) {
            revert InvalidZeroAddress();
        }
        if (_terms.tokenIn == _terms.tokenOut) revert IdenticalTokens();
        if (_terms.amountIn == 0 || _terms.minAmountOut == 0) revert InvalidAmount();
        if (_terms.validUntil != 0 && _terms.validUntil <= _terms.validAfter) revert InvalidTerms();
        if (_terms.validAfter != 0 && block.timestamp < _terms.validAfter) revert OrderNotYetValid();
        if (_terms.validUntil != 0 && block.timestamp >= _terms.validUntil) revert OrderExpired();
    }

    /**
     * @notice Validates the exact transfer and bounded adapter call.
     * @param _terms Maker-signed order restrictions.
     * @param _mode ERC-7579 execution mode.
     * @param _executionCallData Encoded two-call execution batch.
     */
    function validateExecution(Terms memory _terms, ModeCode _mode, bytes calldata _executionCallData) internal pure {
        if (CallType.unwrap(_mode.getCallType()) != CallType.unwrap(CALLTYPE_BATCH)) revert InvalidMode();
        (, ExecType execType_,,) = _mode.decode();
        if (ExecType.unwrap(execType_) != ExecType.unwrap(EXECTYPE_DEFAULT)) revert InvalidMode();

        Execution[] calldata executions_ = _executionCallData.decodeBatch();
        if (executions_.length != 2) revert InvalidMode();

        _validateTransfer(executions_[0], _terms);
        _validateSwap(executions_[1], _terms);
    }

    function _validateTransfer(Execution calldata _execution, Terms memory _terms) private pure {
        if (
            _execution.target != _terms.tokenIn || _execution.value != 0 || _execution.callData.length != 68
                || bytes4(_execution.callData[:4]) != IERC20.transfer.selector
        ) {
            revert InvalidTransferCall();
        }

        (address recipient_, uint256 amount_) = abi.decode(_execution.callData[4:], (address, uint256));
        if (recipient_ != _terms.adapter || amount_ != _terms.amountIn) revert InvalidTransferCall();
    }

    function _validateSwap(Execution calldata _execution, Terms memory _terms) private pure {
        if (
            _execution.target != _terms.adapter || _execution.value != 0 || _execution.callData.length < 4
                || bytes4(_execution.callData[:4]) != MetaSwapLimitOrderAdapter.swap.selector
        ) {
            revert InvalidSwapCall();
        }

        (
            IERC20 tokenIn_,
            IERC20 tokenOut_,
            uint256 amountIn_,
            uint256 minAmountOut_,
            MetaSwapLimitOrderAdapter.ApiQuote memory quote_
        ) = abi.decode(_execution.callData[4:], (IERC20, IERC20, uint256, uint256, MetaSwapLimitOrderAdapter.ApiQuote));
        quote_;

        if (
            address(tokenIn_) != _terms.tokenIn || address(tokenOut_) != _terms.tokenOut || amountIn_ != _terms.amountIn
                || minAmountOut_ < _terms.minAmountOut
        ) {
            revert InvalidSwapCall();
        }
    }
}
