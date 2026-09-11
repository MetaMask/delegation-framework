// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { Execution } from "@erc7579/interfaces/IERC7579Account.sol";

import { EIP7702DeleGatorCore } from "./EIP7702DeleGatorCore.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IEIP7702BatchDeleGator } from "../interfaces/IEIP7702BatchDeleGator.sol";
import { ERC1271Lib } from "../libraries/ERC1271Lib.sol";
import { BatchAuthorizationLib } from "../libraries/BatchAuthorizationLib.sol";

/**
 * @title EIP7702BatchDeleGator
 * @notice Stateful EIP-7702 DeleGator with ERC-7821 signed relay batches and unordered nonce replay protection.
 * @dev Standard ERC-7579 execution remains on inherited `execute(ModeCode,bytes)` with EntryPoint/self access control.
 * @dev Signed relay batches use the child-only `executeBatch(bytes32,bytes)` entrypoint.
 */
contract EIP7702BatchDeleGator is EIP7702DeleGatorCore, IEIP7702BatchDeleGator {
    using BatchAuthorizationLib for Execution[];

    ////////////////////////////// Constants //////////////////////////////

    /// @dev The name of the contract used in the EIP-712 domain.
    string public constant NAME = "EIP7702BatchDeleGator";

    /// @dev The version used in the domainSeparator for EIP712.
    string public constant DOMAIN_VERSION = "1";

    /// @dev The semantic version of the contract.
    string public constant VERSION = "1.0.0";

    /// @dev Single batch, revert on failure — `abi.encode(Execution[])` only.
    bytes32 public constant MODE_BATCH_SIMPLE =
        bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000000));

    /// @dev Single batch with optional `opData` — `abi.encode(Execution[], bytes)`.
    bytes32 public constant MODE_BATCH_WITH_OPDATA =
        bytes32(uint256(0x0100000000007821000100000000000000000000000000000000000000000000));

    /// @dev Nested signed batches — `abi.encode(bytes[])`.
    bytes32 public constant MODE_BATCH_OF_BATCHES =
        bytes32(uint256(0x0100000000007821000200000000000000000000000000000000000000000000));

    /// @custom:storage-location erc7201:DeleGator.EIP7702BatchDeleGator.nonce
    bytes32 private constant NONCE_STORAGE_LOCATION =
        0x1093877edb0cc0e2b2ea60a70fdf07c1dd8a109e13f7d461cf4b95c014189900;

    ////////////////////////////// Storage //////////////////////////////

    struct NonceStorage {
        /// @dev Bitmap of used relay nonces. Nonce word is `nonce >> 8`; bit is `uint8(nonce)`.
        mapping(uint256 word => uint256 bitmap) nonceBitmap;
    }

    ////////////////////////////// Events //////////////////////////////

    event NonceInvalidated(uint256 indexed nonce);
    event NoncesInvalidated(uint256 indexed word, uint256 mask);

    ////////////////////////////// Errors //////////////////////////////

    error UnsupportedBatchExecutionMode();
    error UnauthorizedBatchExecuteCaller();
    error UnauthorizedRelayer();
    error InvalidBatchSignature();
    error BatchAuthorizationExpired();
    error NonceAlreadyUsed();

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Constructor for the EIP7702Batch DeleGator.
     * @param _delegationManager Address of the trusted DelegationManager contract.
     * @param _entryPoint Address of the EntryPoint contract.
     */
    constructor(IDelegationManager _delegationManager, IEntryPoint _entryPoint)
        EIP7702DeleGatorCore(_delegationManager, _entryPoint, NAME, DOMAIN_VERSION)
    { }

    ////////////////////////////// External Methods //////////////////////////////

    /// @inheritdoc IEIP7702BatchDeleGator
    function executeBatch(bytes32 mode, bytes calldata executionData) external payable {
        _routeBatchCalldata(mode, executionData);
    }

    /// @inheritdoc IEIP7702BatchDeleGator
    function supportsBatchExecutionMode(bytes32 mode) external pure returns (bool) {
        return _batchExecutionModeId(mode) != 0;
    }

    /// @inheritdoc IEIP7702BatchDeleGator
    function hashBatchAuthorizationWithNonce(
        Execution[] calldata executions,
        uint256 nonce,
        uint256 deadline,
        address relayer
    )
        external
        view
        returns (bytes32)
    {
        return _hashBatchAuthorizationWithNonce(executions, nonce, deadline, relayer);
    }

    /// @inheritdoc IEIP7702BatchDeleGator
    function isNonceUsed(uint256 nonce) external view returns (bool) {
        (uint256 word, uint256 mask) = _nonceWordAndMask(nonce);
        return _nonceStorage().nonceBitmap[word] & mask != 0;
    }

    /// @inheritdoc IEIP7702BatchDeleGator
    function nonceBitmap(uint256 word) external view returns (uint256 bitmap) {
        return _nonceStorage().nonceBitmap[word];
    }

    /// @inheritdoc IEIP7702BatchDeleGator
    function invalidateNonce(uint256 nonce) external onlyEntryPointOrSelf {
        _consumeNonce(nonce);
        emit NonceInvalidated(nonce);
    }

    /// @inheritdoc IEIP7702BatchDeleGator
    function invalidateNonces(uint256 word, uint256 mask) external onlyEntryPointOrSelf {
        _nonceStorage().nonceBitmap[word] |= mask;
        emit NoncesInvalidated(word, mask);
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Verifies relay signatures against the delegated EOA address.
     * @param _hash The data signed.
     * @param _signature A 65-byte signature produced by the EIP7702 EOA.
     */
    function _isValidSignature(bytes32 _hash, bytes calldata _signature) internal view override returns (bytes4) {
        if (ECDSA.recover(_hash, _signature) == address(this)) return ERC1271Lib.EIP1271_MAGIC_VALUE;

        return ERC1271Lib.SIG_VALIDATION_FAILED;
    }

    /// @dev Mode id: 0 invalid, 1 simple batch, 2 batch + optional opData, 3 batch-of-batches.
    function _batchExecutionModeId(bytes32 mode) internal pure returns (uint256 id) {
        /// @solidity memory-safe-assembly
        assembly {
            let m := and(shr(mul(22, 8), mode), 0xffff00000000ffffffff)
            id := eq(m, 0x01000000000000000000)
            id := or(shl(1, eq(m, 0x01000000000078210001)), id)
            id := or(mul(3, eq(m, 0x01000000000078210002)), id)
        }
    }

    function _routeBatchCalldata(bytes32 mode, bytes calldata executionData) internal {
        uint256 id = _batchExecutionModeId(mode);
        if (id == 0) revert UnsupportedBatchExecutionMode();

        if (id == 3) {
            mode ^= bytes32(uint256(3 << (22 * 8)));
            bytes[] memory batches = abi.decode(executionData, (bytes[]));
            uint256 n = batches.length;
            for (uint256 i = 0; i < n;) {
                _routeBatchMemory(mode, batches[i]);
                unchecked {
                    ++i;
                }
            }
            return;
        }

        Execution[] memory executions;
        bytes memory opData;

        if (id == 2) {
            (executions, opData) = abi.decode(executionData, (Execution[], bytes));
        } else {
            executions = abi.decode(executionData, (Execution[]));
            opData = "";
        }

        _authorizeAndExecuteBatch(executions, opData);
    }

    function _routeBatchMemory(bytes32 mode, bytes memory executionData) internal {
        uint256 id = _batchExecutionModeId(mode);
        if (id == 0) revert UnsupportedBatchExecutionMode();

        if (id == 3) {
            mode ^= bytes32(uint256(3 << (22 * 8)));
            bytes[] memory batches = abi.decode(executionData, (bytes[]));
            uint256 n = batches.length;
            for (uint256 i = 0; i < n;) {
                _routeBatchMemory(mode, batches[i]);
                unchecked {
                    ++i;
                }
            }
            return;
        }

        Execution[] memory executions;
        bytes memory opData;

        if (id == 2) {
            (executions, opData) = abi.decode(executionData, (Execution[], bytes));
        } else {
            executions = abi.decode(executionData, (Execution[]));
            opData = "";
        }

        _authorizeAndExecuteBatch(executions, opData);
    }

    function _authorizeAndExecuteBatch(Execution[] memory executions, bytes memory opData) internal {
        if (opData.length != 0) {
            _verifyBatchAuthorization(executions, opData);
        } else if (msg.sender != address(this)) {
            revert UnauthorizedBatchExecuteCaller();
        }

        _executeExecutions(executions);
    }

    function _verifyBatchAuthorization(Execution[] memory executions, bytes memory opData) internal {
        (uint256 nonce, uint256 deadline, address relayer, bytes memory signature) =
            abi.decode(opData, (uint256, uint256, address, bytes));

        if (block.timestamp > deadline) revert BatchAuthorizationExpired();
        if (relayer != address(0) && relayer != msg.sender) revert UnauthorizedRelayer();

        (uint256 word, uint256 mask) = _nonceWordAndMask(nonce);
        NonceStorage storage $ = _nonceStorage();
        uint256 bitmap = $.nonceBitmap[word];
        if (bitmap & mask != 0) revert NonceAlreadyUsed();

        bytes32 callsDigest = BatchAuthorizationLib.executionsDigest(executions);
        bytes32 structHash = BatchAuthorizationLib.batchAuthorizationWithNonceStructHash(callsDigest, nonce, deadline, relayer);
        bytes32 digest = _hashTypedDataV4(structHash);

        address recovered = ECDSA.recover(digest, signature);
        if (recovered != address(this)) revert InvalidBatchSignature();

        $.nonceBitmap[word] = bitmap | mask;
    }

    function _hashBatchAuthorizationWithNonce(
        Execution[] calldata executions,
        uint256 nonce,
        uint256 deadline,
        address relayer
    )
        internal
        view
        returns (bytes32)
    {
        bytes32 callsDigest = BatchAuthorizationLib.executionsDigestCalldata(executions);
        bytes32 structHash = BatchAuthorizationLib.batchAuthorizationWithNonceStructHash(callsDigest, nonce, deadline, relayer);
        return _hashTypedDataV4(structHash);
    }

    function _executeExecutions(Execution[] memory executions) internal {
        uint256 n = executions.length;
        for (uint256 i = 0; i < n;) {
            Execution memory execution = executions[i];
            address target = execution.target == address(0) ? address(this) : execution.target;
            bytes memory callData = execution.callData;
            bool ok;

            /// @solidity memory-safe-assembly
            assembly {
                ok := call(gas(), target, mload(add(execution, 0x20)), add(callData, 0x20), mload(callData), 0, 0)
                if iszero(ok) {
                    let ptr := mload(0x40)
                    let size := returndatasize()
                    returndatacopy(ptr, 0, size)
                    revert(ptr, size)
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    function _nonceWordAndMask(uint256 nonce) internal pure returns (uint256 word, uint256 mask) {
        word = nonce >> 8;
        mask = 1 << uint8(nonce);
    }

    function _consumeNonce(uint256 nonce) internal {
        (uint256 word, uint256 mask) = _nonceWordAndMask(nonce);
        NonceStorage storage $ = _nonceStorage();
        uint256 bitmap = $.nonceBitmap[word];
        if (bitmap & mask != 0) revert NonceAlreadyUsed();
        $.nonceBitmap[word] = bitmap | mask;
    }

    function _nonceStorage() private pure returns (NonceStorage storage $) {
        /// @solidity memory-safe-assembly
        assembly {
            $.slot := NONCE_STORAGE_LOCATION
        }
    }
}
