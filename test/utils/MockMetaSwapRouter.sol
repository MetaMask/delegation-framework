// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Stand-in for MetaMask Swaps router (`0x881D…300C`). 1:1 output, no real AMM.
contract MockMetaSwapRouter {
    IERC20 public immutable destToken;

    error Slippage();

    constructor(IERC20 destToken_) {
        destToken = destToken_;
    }

    /// @notice Native in (msg.value) → destToken out. Mirrors a gasless ETH swap `trade.value`.
    function swapNative(uint256 minOut, address recipient) external payable {
        uint256 out_ = msg.value;
        if (out_ < minOut) revert Slippage();
        destToken.transfer(recipient, out_);
    }

    /// @notice ERC-20 in via allowance → destToken out. Mirrors a USDC swap `trade.data`.
    function swapERC20(IERC20 tokenIn, uint256 amountIn, uint256 minOut, address recipient) external {
        if (amountIn < minOut) revert Slippage();
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        destToken.transfer(recipient, amountIn);
    }
}
