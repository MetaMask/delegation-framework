// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Adjustable-output swap stand-in used to prove post-execution limit-order checks.
 */
contract MockLimitOrderRouter {
    using SafeERC20 for IERC20;

    uint256 public erc20AmountOut;
    uint256 public nativeAmountOut;

    error NativeTransferFailed();
    error InvalidNativeValue();
    error UnexpectedNativeValue();

    receive() external payable { }

    function setERC20AmountOut(uint256 amountOut_) external {
        erc20AmountOut = amountOut_;
    }

    function setNativeAmountOut(uint256 amountOut_) external {
        nativeAmountOut = amountOut_;
    }

    function swapNativeForERC20(IERC20 tokenOut_, address recipient_) external payable {
        tokenOut_.safeTransfer(recipient_, erc20AmountOut);
    }

    function swapERC20ForNative(IERC20 tokenIn_, uint256 amountIn_, address payable recipient_) external {
        tokenIn_.safeTransferFrom(msg.sender, address(this), amountIn_);
        (bool success_,) = recipient_.call{ value: nativeAmountOut }("");
        if (!success_) revert NativeTransferFailed();
    }

    /// @notice IMetaSwap-compatible entry point with intentionally flexible aggregator and route data.
    function swap(string calldata, IERC20 tokenFrom_, uint256 amount_, bytes calldata route_) external payable {
        (IERC20 tokenOut_, uint256 amountOut_) = abi.decode(route_, (IERC20, uint256));

        if (address(tokenFrom_) == address(0)) {
            if (msg.value != amount_) revert InvalidNativeValue();
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
            tokenFrom_.safeTransferFrom(msg.sender, address(this), amount_);
        }

        if (address(tokenOut_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: amountOut_ }("");
            if (!success_) revert NativeTransferFailed();
        } else {
            tokenOut_.safeTransfer(msg.sender, amountOut_);
        }
    }
}
