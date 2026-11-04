// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Execution } from "@erc7579/interfaces/IERC7579Account.sol";

/**
 * @title BatchAuthorizationLib
 * @notice Shared helpers for EIP-712 batch authorization digests.
 */
library BatchAuthorizationLib {
    bytes32 internal constant BATCH_AUTH_WITH_NONCE_TYPEHASH =
        keccak256("BatchAuthorizationWithNonce(bytes32 callsDigest,uint256 nonce,uint256 deadline,address relayer)");

    /// @notice Computes the ordered digest over `(target, value, keccak256(callData))` for each execution.
    function executionsDigest(Execution[] memory executions) internal pure returns (bytes32 digest) {
        uint256 len = executions.length;
        bytes memory encoded = _newExecutionsDigestBuffer(len);

        for (uint256 i = 0; i < len;) {
            Execution memory execution = executions[i];
            bytes32 dataHash = keccak256(execution.callData);

            /// @solidity memory-safe-assembly
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, mload(execution))
                mstore(add(ptr, 0x20), mload(add(execution, 0x20)))
                mstore(add(ptr, 0x40), dataHash)
                mstore(add(add(encoded, 0x60), shl(5, i)), keccak256(ptr, 0x60))
            }

            unchecked {
                ++i;
            }
        }

        /// @solidity memory-safe-assembly
        assembly {
            digest := keccak256(add(encoded, 0x20), mload(encoded))
        }
    }

    /// @notice Computes the ordered digest over calldata executions.
    function executionsDigestCalldata(Execution[] calldata executions) internal pure returns (bytes32 digest) {
        uint256 len = executions.length;
        bytes memory encoded = _newExecutionsDigestBuffer(len);

        for (uint256 i = 0; i < len;) {
            Execution calldata execution = executions[i];
            address target = execution.target;
            uint256 value = execution.value;
            bytes32 dataHash = keccak256(execution.callData);

            /// @solidity memory-safe-assembly
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, target)
                mstore(add(ptr, 0x20), value)
                mstore(add(ptr, 0x40), dataHash)
                mstore(add(add(encoded, 0x60), shl(5, i)), keccak256(ptr, 0x60))
            }

            unchecked {
                ++i;
            }
        }

        /// @solidity memory-safe-assembly
        assembly {
            digest := keccak256(add(encoded, 0x20), mload(encoded))
        }
    }

    function batchAuthorizationWithNonceStructHash(
        bytes32 callsDigest,
        uint256 nonce,
        uint256 deadline,
        address relayer
    )
        internal
        pure
        returns (bytes32 structHash)
    {
        bytes32 typeHash = BATCH_AUTH_WITH_NONCE_TYPEHASH;

        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), callsDigest)
            mstore(add(ptr, 0x40), nonce)
            mstore(add(ptr, 0x60), deadline)
            mstore(add(ptr, 0x80), relayer)
            structHash := keccak256(ptr, 0xa0)
        }
    }

    function _newExecutionsDigestBuffer(uint256 len) private pure returns (bytes memory encoded) {
        uint256 encodedLen;
        unchecked {
            encodedLen = 0x40 + (len << 5);
        }
        encoded = new bytes(encodedLen);

        /// @solidity memory-safe-assembly
        assembly {
            mstore(add(encoded, 0x20), 0x20)
            mstore(add(encoded, 0x40), len)
        }
    }
}
