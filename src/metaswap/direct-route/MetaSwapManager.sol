// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { ModeCode } from "../../utils/Types.sol";
import { IDeleGatorCore } from "../../interfaces/IDeleGatorCore.sol";
import { NonceBitmap } from "./NonceBitmap.sol";
import { MetaSwapOrderLib } from "./MetaSwapOrderLib.sol";
import { MetaSwapPackedLib } from "./MetaSwapPackedLib.sol";
import { RouteRebuildLib } from "./RouteRebuildLib.sol";

/**
 * @title MetaSwapManager (direct-route)
 * @notice Packed Exact + DirectRoute Limit redeemer for 7702 / DeleGator accounts.
 * @dev Same packing / EIP-712 / dual nonces as `final`, except Limit’s trailing bytes are a
 *      compact route rebuilt via `RouteRebuildLib`. Parse/offsets live in `MetaSwapPackedLib`.
 */
contract MetaSwapManager is EIP712, NonceBitmap {
    string public constant NAME = "MetaSwapDirectRouteManager";
    string public constant DOMAIN_VERSION = "1";
    ModeCode public constant SIMPLE_BATCH_MODE = ModeCode.wrap(0x0100000000000000000000000000000000000000000000000000000000000000);

    bytes32 public constant EXACT_BATCH_TYPEHASH = keccak256(
        "ExactBatch(address delegator,uint256 nonce,uint128 validAfter,uint128 validUntil,address[] redeemers,bytes32 executionHash)"
    );

    bytes32 public constant LIMIT_ORDER_TYPEHASH = keccak256(
        "LimitOrder(address delegator,uint256 nonce,address metaSwap,address tokenIn,uint256 tokenInAmount,uint8 approvalMode,address tokenOut,address recipient,uint256 tokenOutMin,uint128 validAfter,uint128 validUntil,address[] redeemers)"
    );

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

    event ExactBatchRedeemed(address indexed delegator, uint256 indexed nonce);
    event LimitOrderRedeemed(address indexed delegator, uint256 indexed nonce);

    error AccountHasNoCode();
    error InvalidDelegator();
    error InvalidEOASignature();

    constructor() EIP712(NAME, DOMAIN_VERSION) { }

    /// @notice EIP-712 domain separator used when signing Exact / Limit digests off-chain.
    function getDomainHash() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice EIP-712 struct hash for Exact (sign this under the domain from `getDomainHash`).
     * @param batchHash_ `keccak256` of the raw ERC-7579 batch bytes that will follow the signature on-chain.
     */
    function hashExactBatch(
        address delegator_,
        uint256 nonce_,
        uint128 validAfter_,
        uint128 validUntil_,
        address[] memory redeemers_,
        bytes32 batchHash_
    )
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                EXACT_BATCH_TYPEHASH,
                delegator_,
                nonce_,
                validAfter_,
                validUntil_,
                keccak256(abi.encodePacked(redeemers_)),
                batchHash_
            )
        );
    }

    function _exactStructHash(MetaSwapPackedLib.ExactAuth memory auth_, bytes32 batchHash_) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EXACT_BATCH_TYPEHASH,
                auth_.delegator,
                auth_.nonce,
                auth_.validAfter,
                auth_.validUntil,
                auth_.redeemersHash,
                batchHash_
            )
        );
    }

    /**
     * @notice EIP-712 struct hash for Limit from a memory struct.
     * @dev Must match `_limitOrderStructHash` (same typehash and field order) for signatures to verify on redeem.
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
     * @notice Redeem a signed Exact batch packed into `msg.data` (no ABI args).
     * @dev Listed redeemer, inside the signed window. The batch itself stays exact.
     */
    function redeemExactBatch() external {
        (MetaSwapPackedLib.ExactAuth memory auth_, bytes calldata signature_, bytes calldata batch_) =
            MetaSwapPackedLib.decodeExact(msg.data);

        _authorizeExactBatch(auth_.delegator, auth_.nonce, _exactStructHash(auth_, keccak256(batch_)), signature_);
        MetaSwapPackedLib.requireRedeemer(msg.data, msg.sender, auth_.redeemersOffset, auth_.signatureOffset);
        MetaSwapOrderLib.validateTimestamp(auth_.validAfter, auth_.validUntil);
        _executeOnDelegator(auth_.delegator, batch_);
        emit ExactBatchRedeemed(auth_.delegator, auth_.nonce);
    }

    /**
     * @notice Redeem a signed Limit order; bytes after the signature are DirectRoute `route`, not a batch.
     * @dev Listed redeemer only. Decode → EIP-712 Limit → ECDSA → burn limit nonce → policy →
     *      rebuild route → execute → min-out.
     */
    function redeemLimitOrder() external {
        (
            address delegator_,
            uint256 nonce_,
            MetaSwapPackedLib.LimitTerms memory terms_,
            bytes32 redeemersHash_,
            uint256 signatureOffset_,
            bytes calldata signature_,
            bytes calldata route_
        ) = MetaSwapPackedLib.decodeLimit(msg.data);

        _authorizeLimitOrder(delegator_, nonce_, _limitOrderStructHash(delegator_, nonce_, terms_, redeemersHash_), signature_);
        MetaSwapPackedLib.requireRedeemer(msg.data, msg.sender, signatureOffset_);
        MetaSwapOrderLib.validateTimestamp(terms_.validAfter, terms_.validUntil);
        _executeLimitOrder(delegator_, terms_, route_);
        emit LimitOrderRedeemed(delegator_, nonce_);
    }

    /**
     * @dev Limit fill: validate terms, `RouteRebuildLib.buildBatch` from terms+`route_`,
     *      `_executeOnDelegator`, then require `recipient` gained ≥ `tokenOutMin` of `tokenOut`.
     */
    function _executeLimitOrder(address delegator_, MetaSwapPackedLib.LimitTerms memory terms_, bytes calldata route_) private {
        MetaSwapOrderLib.validateTerms(
            terms_.metaSwap,
            terms_.tokenIn,
            terms_.tokenInAmount,
            terms_.approvalMode,
            terms_.tokenOut,
            terms_.recipient,
            terms_.tokenOutMin
        );
        uint256 balanceBefore_ = MetaSwapOrderLib.balanceOf(terms_.tokenOut, terms_.recipient);
        bytes memory batch_ =
            RouteRebuildLib.buildBatch(terms_.metaSwap, terms_.tokenIn, terms_.tokenInAmount, terms_.approvalMode, route_);
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

    function _authorizeExactBatch(address delegator_, uint256 nonce_, bytes32 structHash_, bytes calldata signature_) internal {
        _validateSignature(delegator_, structHash_, signature_);
        _useExactBatchNonce(delegator_, nonce_);
    }

    function _authorizeLimitOrder(address delegator_, uint256 nonce_, bytes32 structHash_, bytes calldata signature_) internal {
        _validateSignature(delegator_, structHash_, signature_);
        _useLimitOrderNonce(delegator_, nonce_);
    }

    function _validateSignature(address delegator_, bytes32 structHash_, bytes calldata signature_) private view {
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
