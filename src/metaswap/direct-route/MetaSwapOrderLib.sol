// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MetaSwapOrderLib
 * @notice Limit-order policy checks for the DirectRoute manager (terms, timestamp, balance).
 * @dev Batch shape is enforced by `RouteRebuildLib`, which builds `[swap]`, `[approve, swap]`, or
 *      `[approve(0), approve(amount), swap]` from signed terms + relayer route bytes.
 */
library MetaSwapOrderLib {
    enum ApprovalMode {
        None,
        SkipApproval,
        Approve,
        ResetApprove
    }

    error EarlyDelegation();
    error ExpiredDelegation();
    error InsufficientOutput();
    error InvalidApprovalMode();
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

    function balanceOf(address token_, address account_) internal view returns (uint256) {
        return token_ == address(0) ? account_.balance : IERC20(token_).balanceOf(account_);
    }
}
