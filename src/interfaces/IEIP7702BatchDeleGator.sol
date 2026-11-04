// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Execution } from "@erc7579/interfaces/IERC7579Account.sol";

/**
 * @title IEIP7702BatchDeleGator
 * @notice Relay-only ERC-7821 batch execution surface for EIP7702BatchDeleGator.
 * @dev Signed batches are submitted through `executeBatch`, not inherited `execute(ModeCode,bytes)`.
 */
interface IEIP7702BatchDeleGator {
    /// @dev Single batch with optional `opData` — `abi.encode(Execution[], bytes)`.
    function MODE_BATCH_WITH_OPDATA() external view returns (bytes32);

    /// @dev Nested signed batches — `abi.encode(bytes[])`.
    function MODE_BATCH_OF_BATCHES() external view returns (bytes32);

    /**
     * @notice Executes a signed ERC-7821 batch after authorization checks.
     * @param mode Relay mode constant (`MODE_BATCH_WITH_OPDATA` or `MODE_BATCH_OF_BATCHES`).
     * @param executionData Encoded batch payload for the selected mode.
     */
    function executeBatch(bytes32 mode, bytes calldata executionData) external payable;

    /**
     * @notice Returns whether `mode` is supported by the relay entrypoint.
     * @dev Relay-only modes are intentionally excluded from inherited `supportsExecutionMode`.
     */
    function supportsBatchExecutionMode(bytes32 mode) external view returns (bool);

    /**
     * @notice EIP-712 digest for replay-protected relayed execution.
     * @param executions Executions authorized by the signature.
     * @param nonce Unordered nonce to consume if the batch executes.
     * @param deadline Last timestamp at which the authorization is valid.
     * @param relayer Optional authorized relayer; use `address(0)` to allow any relayer.
     */
    function hashBatchAuthorizationWithNonce(
        Execution[] calldata executions,
        uint256 nonce,
        uint256 deadline,
        address relayer
    )
        external
        view
        returns (bytes32);

    /// @notice Returns whether an unordered relay nonce has already been consumed or invalidated.
    function isNonceUsed(uint256 nonce) external view returns (bool);

    /// @notice Returns the used-nonce bitmap for `word`.
    function nonceBitmap(uint256 word) external view returns (uint256 bitmap);

    /// @notice Invalidates one relay nonce.
    function invalidateNonce(uint256 nonce) external;

    /// @notice Invalidates any nonce bits in `word` where `mask` has a 1 bit.
    function invalidateNonces(uint256 word, uint256 mask) external;
}
