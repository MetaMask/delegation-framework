// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IMetaSwap } from "../../helpers/interfaces/IMetaSwap.sol";
import { Execution } from "../../utils/Types.sol";

/**
 * @title MetaSwapOrderLib
 * @notice Limit-order policy checks shared by every optimized manager variant.
 * @dev Same rules as `MetaSwapOrderDelegationManager`: the batch is `[swap]`, `[approve, swap]`, or
 *      `[approve(0), approve(amount), swap]`, and only the swap route bytes are relayer-chosen.
 */
library MetaSwapOrderLib {
    enum ApprovalMode {
        None,
        SkipApproval,
        Approve,
        ResetApprove
    }

    uint256 internal constant APPROVE_CALL_LENGTH = 68;
    /// @dev `swap(string,address,uint256,bytes)` head (4 + 4 words) plus the two dynamic length words.
    uint256 internal constant SWAP_CALL_MIN_LENGTH = 196;

    error ApprovalShapeNotAllowed();
    error EarlyDelegation();
    error ExpiredDelegation();
    error InsufficientOutput();
    error InvalidApproval();
    error InvalidApprovalMode();
    error InvalidBatchLength();
    error InvalidSwap();
    error InvalidTerms();

    /**
     * @notice Rejects terms that could never describe a meaningful limit order.
     */
    function validateTerms(
        address metaSwap_,
        address tokenIn_,
        uint256 tokenInAmount_,
        uint256 approvalMode_,
        address tokenOut_,
        address recipient_,
        uint256 tokenOutMin_
    )
        internal
        pure
    {
        if (
            metaSwap_ == address(0) || tokenInAmount_ == 0 || recipient_ == address(0) || tokenOutMin_ == 0 || tokenIn_ == tokenOut_
        ) {
            revert InvalidTerms();
        }
        if (approvalMode_ > uint8(ApprovalMode.ResetApprove)) revert InvalidApprovalMode();
    }

    /// @dev `0` disables a bound. A set bound is exclusive, matching `TimestampEnforcer`.
    function validateTimestamp(uint256 validAfter_, uint256 validUntil_) internal view {
        if (validAfter_ != 0 && block.timestamp <= validAfter_) revert EarlyDelegation();
        if (validUntil_ != 0 && block.timestamp >= validUntil_) revert ExpiredDelegation();
    }

    function validateExecutions(
        Execution[] calldata executions_,
        address metaSwap_,
        address tokenIn_,
        uint256 tokenInAmount_,
        uint256 approvalMode_
    )
        internal
        pure
    {
        if (tokenIn_ == address(0)) {
            if (approvalMode_ != uint8(ApprovalMode.None)) revert InvalidApprovalMode();
            if (executions_.length != 1) revert InvalidBatchLength();
            _validateSwap(executions_[0], metaSwap_, address(0), tokenInAmount_, tokenInAmount_);
            return;
        }

        if (approvalMode_ == uint8(ApprovalMode.SkipApproval)) {
            if (executions_.length != 1) revert ApprovalShapeNotAllowed();
            _validateSwap(executions_[0], metaSwap_, tokenIn_, tokenInAmount_, 0);
        } else if (approvalMode_ == uint8(ApprovalMode.Approve)) {
            if (executions_.length != 2) revert ApprovalShapeNotAllowed();
            _validateApproval(executions_[0], tokenIn_, metaSwap_, tokenInAmount_);
            _validateSwap(executions_[1], metaSwap_, tokenIn_, tokenInAmount_, 0);
        } else if (approvalMode_ == uint8(ApprovalMode.ResetApprove)) {
            if (executions_.length != 3) revert ApprovalShapeNotAllowed();
            _validateApproval(executions_[0], tokenIn_, metaSwap_, 0);
            _validateApproval(executions_[1], tokenIn_, metaSwap_, tokenInAmount_);
            _validateSwap(executions_[2], metaSwap_, tokenIn_, tokenInAmount_, 0);
        } else {
            revert InvalidApprovalMode();
        }
    }

    function balanceOf(address token_, address account_) internal view returns (uint256) {
        return token_ == address(0) ? account_.balance : IERC20(token_).balanceOf(account_);
    }

    function _validateApproval(
        Execution calldata execution_,
        address tokenIn_,
        address metaSwap_,
        uint256 expectedAmount_
    )
        private
        pure
    {
        bytes calldata callData_ = execution_.callData;
        if (
            execution_.target != tokenIn_ || execution_.value != 0 || callData_.length != APPROVE_CALL_LENGTH
                || bytes4(callData_[0:4]) != IERC20.approve.selector
                || bytes32(callData_[4:36]) != bytes32(uint256(uint160(metaSwap_)))
                || uint256(bytes32(callData_[36:68])) != expectedAmount_
        ) {
            revert InvalidApproval();
        }
    }

    function _validateSwap(
        Execution calldata execution_,
        address metaSwap_,
        address tokenIn_,
        uint256 tokenInAmount_,
        uint256 expectedValue_
    )
        private
        pure
    {
        bytes calldata callData_ = execution_.callData;
        if (
            execution_.target != metaSwap_ || execution_.value != expectedValue_ || callData_.length < SWAP_CALL_MIN_LENGTH
                || bytes4(callData_[0:4]) != IMetaSwap.swap.selector
                || bytes32(callData_[36:68]) != bytes32(uint256(uint160(tokenIn_)))
                || uint256(bytes32(callData_[68:100])) != tokenInAmount_
        ) {
            revert InvalidSwap();
        }
    }
}
