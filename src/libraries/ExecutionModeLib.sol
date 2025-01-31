// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ModeCode } from "../utils/Types.sol";

/**
 * @title ExecutionModeLib
 * @dev Library providing constants for execution modes (single/batch, revert/try)
 *      and a helper function to check if a given ModeCode is supported.
 * @notice Related: @erc7579/ModeLib.sol
 */
library ExecutionModeLib {
    // @dev Single execution and revert on failure: bytes32(0x0000...)
    uint256 internal constant MODE_SINGLE_REVERT = 0;
    // @dev Single execution and skip on failure: bytes32(0x0001...)
    uint256 internal constant MODE_SINGLE_TRY = 1 << 240;
    // @dev Batch execution and revert on failure: bytes32(0x0100...)
    uint256 internal constant MODE_BATCH_REVERT = 1 << 248;
    // @dev Batch execution and skip on failure: bytes32(0x0101...)
    uint256 internal constant MODE_BATCH_TRY = (1 << 240) | (1 << 248);

    /**
     * @notice Checks if a given ModeCode is supported by this library.
     * @param _modeCode The mode to validate.
     * @return result_ True if the mode is supported, false otherwise.
     */
    function _supportsExecutionMode(ModeCode _modeCode) internal pure returns (bool result_) {
        uint256 mode_ = uint256(ModeCode.unwrap(_modeCode));

        return (mode_ == MODE_SINGLE_REVERT || mode_ == MODE_SINGLE_TRY || mode_ == MODE_BATCH_REVERT || mode_ == MODE_BATCH_TRY);
    }
}
