// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @dev Interface for minimal batch executor.
 */
interface IERC7821 {
    /**
     * @notice Executes the function calls specified in `executionData` according to the provided `mode`.
     *
     * @dev The `executionData` must be encoded according to EIP-7579 standards.
     * @param mode Execution mode as defined above.
     * @param executionData Encoded function calls and associated data to execute.
     * Supported modes:
     * - `bytes32(0x0000...)`: Single execution, revert on failure.
     * - `bytes32(0x0001...)`: Single execution, skip on failure.
     * - `bytes32(0x0100...)`: Batch execution, revert on failure.
     * - `bytes32(0x0101...)`: Batch execution, skip on failure.
     *
     */
    function execute(bytes32 mode, bytes calldata executionData) external payable;

    /**
     * @notice Indicates whether the contract supports a given execution mode.
     *
     * @param mode The execution mode to check.
     * @return bool True if the specified execution mode is supported, false otherwise.
     *
     * Supported modes:
     * - `bytes32(0x0000...)`: Single execution, revert on failure.
     * - `bytes32(0x0001...)`: Single execution, skip on failure.
     * - `bytes32(0x0100...)`: Batch execution, revert on failure.
     * - `bytes32(0x0101...)`: Batch execution, skip on failure.
     */
    function supportsExecutionMode(bytes32 mode) external view returns (bool);
}
