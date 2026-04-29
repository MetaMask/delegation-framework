// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMetaSwap {
    /**
     * @dev Performs a swap
     * @param aggregatorId Identifier of the aggregator to be used for the swap
     * @param data Dynamic data which is concatenated with the fixed aggregator's
     * data in the delecatecall made to the adapter
     */
    function swap(string calldata aggregatorId, IERC20 tokenFrom, uint256 amount, bytes calldata data) external payable;
}
