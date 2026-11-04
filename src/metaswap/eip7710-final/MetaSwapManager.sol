// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { ModeCode } from "../../utils/Types.sol";
import { IDeleGatorCore } from "../../interfaces/IDeleGatorCore.sol";
import { NonceBitmap } from "./NonceBitmap.sol";
import { MetaSwapOrderLib } from "./MetaSwapOrderLib.sol";
import { MetaSwapPackedLib } from "./MetaSwapPackedLib.sol";

/**
 * @title MetaSwapManager (eip7710-final)
 * @notice EIP-7710 Exact + Limit redeemer (ABI batch in `executionCallDatas`).
 * @dev Auth packing lives in `permissionContexts[0]`; parse/offsets in `MetaSwapPackedLib`.
 *      Batch is only in `executionCallDatas[0]`. Type byte is unsigned (dispatch only).
 */
contract MetaSwapManager is EIP712, NonceBitmap {
    using ExecutionLib for bytes;

    string public constant DOMAIN_VERSION = "1";
    ModeCode public constant SIMPLE_BATCH_MODE = ModeCode.wrap(0x0100000000000000000000000000000000000000000000000000000000000000);

    /// @dev First byte of `permissionContexts[0]`: Exact vs Limit dispatch (not part of the signed digest).
    uint8 internal constant TYPE_EXACT = 0;
    uint8 internal constant TYPE_LIMIT = 1;

    bytes32 public constant EXACT_BATCH_TYPEHASH = keccak256("ExactBatch(address delegator,uint256 nonce,bytes32 executionHash)");
    bytes32 public constant LIMIT_ORDER_TYPEHASH = keccak256(
        "LimitOrder(address delegator,uint256 nonce,address metaSwap,address tokenIn,uint256 tokenInAmount,uint8 approvalMode,address tokenOut,address recipient,uint256 tokenOutMin,uint128 validAfter,uint128 validUntil,address[] redeemers)"
    );

    event ExactBatchRedeemed(address indexed delegator, uint256 indexed nonce);
    event LimitOrderRedeemed(address indexed delegator, uint256 indexed nonce);

    error AccountHasNoCode();
    error BatchDataLengthMismatch();
    error InvalidDelegator();
    error InvalidEOASignature();
    error InvalidIntent();
    error InvalidMode();

    /// @dev Memory shape for off-chain hashing / tests. Hot-path Limit redeem uses `MetaSwapPackedLib.LimitTerms`.
    struct LimitOrder {
        address delegator;
        uint256 nonce;
        address metaSwap;
        address tokenIn;
        uint256 tokenInAmount;
        uint8 approvalMode;
        address tokenOut;
        address recipient;
        uint256 tokenOutMin;
        uint128 validAfter;
        uint128 validUntil;
        address[] redeemers;
    }

    string public constant NAME = "MetaSwapEip7710Manager";

    constructor() EIP712(NAME, DOMAIN_VERSION) { }

    /// @notice EIP-712 domain separator used when signing Exact / Limit digests off-chain.
    function getDomainHash() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice EIP-712 struct hash for Exact (sign this under the domain from `getDomainHash`).
     * @param batchHash_ `keccak256` of the ERC-7579 batch passed in `executionCallDatas[0]`.
     */
    function hashExactBatch(address delegator_, uint256 nonce_, bytes32 batchHash_) public pure returns (bytes32) {
        return keccak256(abi.encode(EXACT_BATCH_TYPEHASH, delegator_, nonce_, batchHash_));
    }

    /**
     * @notice EIP-712 struct hash for Limit from a memory struct.
     * @dev Must match `_limitOrderStructHash` for signatures to verify on redeem.
     */
    function hashLimitOrder(LimitOrder memory order_) public pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    LIMIT_ORDER_TYPEHASH,
                    order_.delegator,
                    order_.nonce,
                    order_.metaSwap,
                    order_.tokenIn,
                    order_.tokenInAmount,
                    order_.approvalMode
                ),
                abi.encode(order_.tokenOut, order_.recipient, order_.tokenOutMin, order_.validAfter, order_.validUntil),
                abi.encode(keccak256(abi.encodePacked(order_.redeemers)))
            )
        );
    }

    /**
     * @notice ERC-7710 entry. Single redemption only (each array length must be 1).
     * @param permissionContexts_ `[0]` = packed auth (`type | delegator | nonce | … | signature`).
     * @param modes_ `[0]` must be `SIMPLE_BATCH_MODE`.
     * @param executionCallDatas_ `[0]` = Exact/Limit ERC-7579 batch (not inside the permission blob).
     */
    function redeemDelegations(
        bytes[] calldata permissionContexts_,
        ModeCode[] calldata modes_,
        bytes[] calldata executionCallDatas_
    )
        external
    {
        if (permissionContexts_.length != 1 || modes_.length != 1 || executionCallDatas_.length != 1) {
            revert BatchDataLengthMismatch();
        }
        if (ModeCode.unwrap(modes_[0]) != ModeCode.unwrap(SIMPLE_BATCH_MODE)) revert InvalidMode();

        bytes calldata permission_ = permissionContexts_[0];
        uint8 type_ = MetaSwapPackedLib.readType(permission_);
        if (type_ == TYPE_EXACT) {
            _redeemExact(permission_, executionCallDatas_[0]);
        } else if (type_ == TYPE_LIMIT) {
            _redeemLimit(permission_, executionCallDatas_[0]);
        } else {
            revert InvalidIntent();
        }
    }

    /// @dev Exact: decode `permission_` → EIP-712 over `keccak256(batch)` → ECDSA + exact nonce → execute batch.
    function _redeemExact(bytes calldata permission_, bytes calldata batch_) private {
        (address delegator_, uint256 nonce_, bytes calldata signature_) = MetaSwapPackedLib.decodeExact(permission_);

        _validateSignature(delegator_, hashExactBatch(delegator_, nonce_, keccak256(batch_)), signature_);
        _useExactBatchNonce(delegator_, nonce_);
        _executeOnDelegator(delegator_, batch_);
        emit ExactBatchRedeemed(delegator_, nonce_);
    }

    /// @dev Limit: decode `permission_` → EIP-712 from terms → ECDSA + limit nonce → redeemer/time → settle.
    function _redeemLimit(bytes calldata permission_, bytes calldata execution_) private {
        (
            address delegator_,
            uint256 nonce_,
            MetaSwapPackedLib.LimitTerms memory terms_,
            bytes32 redeemersHash_,
            uint256 signatureOffset_,
            bytes calldata signature_
        ) = MetaSwapPackedLib.decodeLimit(permission_);

        _validateSignature(delegator_, _limitOrderStructHash(delegator_, nonce_, terms_, redeemersHash_), signature_);
        _useLimitOrderNonce(delegator_, nonce_);
        MetaSwapPackedLib.requireRedeemer(permission_, msg.sender, signatureOffset_);
        MetaSwapOrderLib.validateTimestamp(terms_.validAfter, terms_.validUntil);
        _executeLimitOrder(delegator_, terms_, execution_);
        emit LimitOrderRedeemed(delegator_, nonce_);
    }

    /**
     * @dev Limit fill: terms + batch-shape checks, `_executeOnDelegator(batch_)`, then require
     *      `recipient` gained ≥ `tokenOutMin` of `tokenOut`.
     */
    function _executeLimitOrder(address delegator_, MetaSwapPackedLib.LimitTerms memory terms_, bytes calldata batch_) private {
        MetaSwapOrderLib.validateTerms(
            terms_.metaSwap,
            terms_.tokenIn,
            terms_.tokenInAmount,
            terms_.approvalMode,
            terms_.tokenOut,
            terms_.recipient,
            terms_.tokenOutMin
        );
        MetaSwapOrderLib.validateExecutions(
            batch_.decodeBatch(), terms_.metaSwap, terms_.tokenIn, terms_.tokenInAmount, terms_.approvalMode
        );

        uint256 balanceBefore_ = MetaSwapOrderLib.balanceOf(terms_.tokenOut, terms_.recipient);
        _executeOnDelegator(delegator_, batch_);
        uint256 balanceAfter_ = MetaSwapOrderLib.balanceOf(terms_.tokenOut, terms_.recipient);
        if (balanceAfter_ < balanceBefore_ || balanceAfter_ - balanceBefore_ < terms_.tokenOutMin) {
            revert MetaSwapOrderLib.InsufficientOutput();
        }
    }

    function _limitOrderStructHash(
        address delegator_,
        uint256 nonce_,
        MetaSwapPackedLib.LimitTerms memory terms_,
        bytes32 redeemersHash_
    )
        private
        pure
        returns (bytes32)
    {
        return keccak256(
            bytes.concat(
                abi.encode(
                    LIMIT_ORDER_TYPEHASH,
                    delegator_,
                    nonce_,
                    terms_.metaSwap,
                    terms_.tokenIn,
                    terms_.tokenInAmount,
                    terms_.approvalMode
                ),
                abi.encode(
                    terms_.tokenOut, terms_.recipient, terms_.tokenOutMin, terms_.validAfter, terms_.validUntil, redeemersHash_
                )
            )
        );
    }

    function _validateSignature(address delegator_, bytes32 structHash_, bytes calldata signature_) internal view {
        if (delegator_ == address(0)) revert InvalidDelegator();
        if (ECDSA.recover(_hashTypedDataV4(structHash_), signature_) != delegator_) revert InvalidEOASignature();
    }

    function _executeOnDelegator(address delegator_, bytes memory batch_) internal {
        if (delegator_.code.length == 0) revert AccountHasNoCode();

        bytes memory callData_ = abi.encodeCall(IDeleGatorCore.executeFromExecutor, (SIMPLE_BATCH_MODE, batch_));

        assembly ("memory-safe") {
            let payload := add(callData_, 0x20)
            let payloadSize := mload(callData_)
            let success := call(gas(), delegator_, 0, payload, payloadSize, 0, 0)

            if iszero(success) {
                let freeMem := mload(0x40)
                let revertSize := returndatasize()
                returndatacopy(freeMem, 0, revertSize)
                revert(freeMem, revertSize)
            }
        }
    }
}
