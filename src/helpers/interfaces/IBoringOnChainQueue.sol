// Based on:
// https://github.com/Veda-Labs/boring-vault/blob/main/src/base/Roles/BoringQueue/BoringOnChainQueue.sol

// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title IBoringOnChainQueue
 * @notice Interface for the BoringOnChainQueue's withdraw-request function.
 * @dev Uses native Solidity types to avoid importing Veda-specific dependencies.
 */
interface IBoringOnChainQueue {
    /**
     * @notice Request an on-chain withdraw from the BoringVault queue.
     * @dev The caller must have approved this queue contract to spend `amountOfShares`
     *      of the BoringVault share token. The queue pulls shares via `safeTransferFrom`.
     * @param assetOut The underlying asset the user wants to receive upon maturity
     * @param amountOfShares The amount of vault shares to queue for withdrawal
     * @param discount The discount to apply in bps (0 = no discount)
     * @param secondsToDeadline The time in seconds the request remains valid after maturity
     * @return requestId A unique identifier for the queued withdraw request
     */
    function requestOnChainWithdraw(
        address assetOut,
        uint128 amountOfShares,
        uint16 discount,
        uint24 secondsToDeadline
    )
        external
        returns (bytes32 requestId);
}
