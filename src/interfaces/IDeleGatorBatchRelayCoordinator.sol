// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title IDeleGatorBatchRelayCoordinator
 * @notice Multi-account coordinator for signed EIP7702BatchDeleGator relay batches.
 * @dev Not an EIP-4337 paymaster. Child accounts still require valid signed batches.
 */
interface IDeleGatorBatchRelayCoordinator {
    struct AccountBatch {
        address account;
        bytes32 mode;
        bytes executionData;
    }

    /// @notice Executes each signed batch row on its delegated account.
    function executeBatches(AccountBatch[] calldata batches) external;
}
