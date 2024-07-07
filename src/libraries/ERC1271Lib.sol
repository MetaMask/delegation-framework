// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title ERC1271 Library
 */
library ERC1271Lib {
    /// @dev Magic value to be returned upon successful validation.
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;

    /// @dev Magic value to be returned upon failed validation.
    bytes4 internal constant SIG_VALIDATION_FAILED = 0xffffffff;
}
