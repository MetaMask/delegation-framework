// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMetaSwap {
    struct Adapter {
        address addr; // adapter's address
        bytes4 selector;
        bytes data; // adapter's fixed data
    }

    /**
     * @dev Sets the adapter for an aggregator. It can't be changed later.
     * @param aggregatorId Aggregator's identifier
     * @param addr Address of the contract that contains the logic for this aggregator
     * @param selector The function selector of the swap function in the adapter
     * @param data Fixed abi encoded data the will be passed in each delegatecall made to the adapter
     */
    function setAdapter(string calldata aggregatorId, address addr, bytes4 selector, bytes calldata data) external;

    /**
     * @dev Removes the adapter for an existing aggregator. This can't be undone.
     * @param aggregatorId Aggregator's identifier
     */
    function removeAdapter(string calldata aggregatorId) external;

    /**
     * @dev Performs a swap
     * @param aggregatorId Identifier of the aggregator to be used for the swap
     * @param data Dynamic data which is concatenated with the fixed aggregator's
     * data in the delecatecall made to the adapter
     */
    function swap(string calldata aggregatorId, IERC20 tokenFrom, uint256 amount, bytes calldata data) external payable;

    function adapters(string memory id) external view returns (Adapter memory);
}
