// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IMetaBridge {
    /**
     * @dev Bridges tokens between chains
     * @param adapterId Identifier of the adapter to be used for the bridge
     * @param srcToken Address of the source token
     * @param amount Amount of tokens to bridge
     * @param data Dynamic data which is concatenated with the fixed adapter's
     * data in the delecatecall made to the adapter
     */
    function bridge(string calldata adapterId, address srcToken, uint256 amount, bytes calldata data) external payable;
}
