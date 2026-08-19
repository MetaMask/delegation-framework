// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockSwapRouter {
    using SafeERC20 for IERC20;

    function swap(
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        address receiver,
        address,
        bytes calldata
    )
        external
    {
        sellToken.safeTransferFrom(msg.sender, address(this), sellAmount);
        buyToken.safeTransfer(receiver, buyAmount);
    }
}
