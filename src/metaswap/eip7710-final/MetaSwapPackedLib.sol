// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MetaSwapOrderLib } from "./MetaSwapOrderLib.sol";

/**
 * @title MetaSwapPackedLib
 * @notice Permission-context layout + decode for the `eip7710-final` MetaSwapManager.
 * @dev Offsets are relative to `permissionContexts[0]`. Batch/route lives in `executionCallDatas[0]`.
 *
 * Layout:
 *   Exact:  type(1) offset 0 | delegator(20) offset 1 | nonce(32) offset 21 | signature(65) offset 53
 *           — length `EXACT_CONTEXT_LENGTH` (118)
 *   Limit:  type(1) offset 0 | delegator(20) offset 1 | nonce(32) offset 21 | terms offsets 53..229 |
 *           redeemerCount(1) offset 230 | redeemers(20*n) offset 231 | signature(65)
 */
library MetaSwapPackedLib {
    /// @dev Limit terms loaded once for hash / validate / min-out (value types only).
    struct LimitTerms {
        address metaSwap;
        address tokenIn;
        uint256 tokenInAmount;
        uint8 approvalMode;
        address tokenOut;
        address recipient;
        uint256 tokenOutMin;
        uint128 validAfter;
        uint128 validUntil;
    }

    error InvalidCalldata();
    error UnauthorizedRedeemer();

    uint256 private constant DELEGATOR_OFFSET = 1;
    uint256 private constant NONCE_OFFSET = 21;
    uint256 private constant EXACT_SIGNATURE_OFFSET = 53;
    uint256 private constant EXACT_CONTEXT_LENGTH = 118;

    uint256 private constant METASWAP_OFFSET = 53;
    uint256 private constant TOKEN_IN_OFFSET = 73;
    uint256 private constant TOKEN_IN_AMOUNT_OFFSET = 93;
    uint256 private constant APPROVAL_MODE_OFFSET = 125;
    uint256 private constant TOKEN_OUT_OFFSET = 126;
    uint256 private constant RECIPIENT_OFFSET = 146;
    uint256 private constant TOKEN_OUT_MIN_OFFSET = 166;
    uint256 private constant VALID_AFTER_OFFSET = 198;
    uint256 private constant VALID_UNTIL_OFFSET = 214;
    uint256 private constant REDEEMER_COUNT_OFFSET = 230;
    uint256 private constant REDEEMERS_OFFSET = 231;

    uint256 private constant SIGNATURE_LENGTH = 65;
    /// @dev Packed address byte length (redeemer stride / field size)
    uint256 private constant ADDRESS_LENGTH = 20;
    /// @dev Right-shift after `calldataload` to right-align a packed address: (32 - 20) * 8
    uint256 private constant ADDRESS_RSHIFT = 96;
    /// @dev Right-shift after `calldataload` to right-align a packed uint128: (32 - 16) * 8
    uint256 private constant UINT128_RSHIFT = 128;
    /// @dev ABI word size when packing redeemers for `keccak256`
    uint256 private constant WORD_SIZE = 32;

    function readType(bytes calldata permission_) internal pure returns (uint8 type_) {
        if (permission_.length == 0) revert InvalidCalldata();
        assembly ("memory-safe") {
            type_ := byte(0, calldataload(permission_.offset))
        }
    }

    function decodeExact(bytes calldata permission_)
        internal
        pure
        returns (address delegator_, uint256 nonce_, bytes calldata signature_)
    {
        if (permission_.length != EXACT_CONTEXT_LENGTH) revert InvalidCalldata();
        delegator_ = _loadAddress(permission_, DELEGATOR_OFFSET);
        nonce_ = _loadUint256(permission_, NONCE_OFFSET);
        signature_ = permission_[EXACT_SIGNATURE_OFFSET:EXACT_CONTEXT_LENGTH];
    }

    function decodeLimit(bytes calldata permission_)
        internal
        pure
        returns (
            address delegator_,
            uint256 nonce_,
            LimitTerms memory terms_,
            bytes32 redeemersHash_,
            uint256 signatureOffset_,
            bytes calldata signature_
        )
    {
        if (permission_.length < REDEEMERS_OFFSET) revert InvalidCalldata();

        uint256 redeemerCount_;
        assembly ("memory-safe") {
            redeemerCount_ := byte(0, calldataload(add(permission_.offset, REDEEMER_COUNT_OFFSET)))
        }
        if (redeemerCount_ == 0) revert MetaSwapOrderLib.InvalidTerms();

        signatureOffset_ = REDEEMERS_OFFSET + redeemerCount_ * ADDRESS_LENGTH;
        uint256 sigEnd_ = signatureOffset_ + SIGNATURE_LENGTH;
        if (permission_.length != sigEnd_) revert InvalidCalldata();

        delegator_ = _loadAddress(permission_, DELEGATOR_OFFSET);
        nonce_ = _loadUint256(permission_, NONCE_OFFSET);
        terms_ = _loadLimitTerms(permission_);
        redeemersHash_ = _hashRedeemers(permission_, redeemerCount_);
        signature_ = permission_[signatureOffset_:sigEnd_];
    }

    /// @dev Require `who_` appears in packed redeemers `[REDEEMERS_OFFSET, signatureOffset_)`.
    function requireRedeemer(bytes calldata permission_, address who_, uint256 signatureOffset_) internal pure {
        for (uint256 offset_ = REDEEMERS_OFFSET;; offset_ += ADDRESS_LENGTH) {
            if (offset_ == signatureOffset_) revert UnauthorizedRedeemer();
            if (_loadAddress(permission_, offset_) == who_) return;
        }
    }

    function _hashRedeemers(bytes calldata permission_, uint256 redeemerCount_) private pure returns (bytes32 redeemersHash_) {
        assembly ("memory-safe") {
            let packedRedeemers := mload(0x40)
            let permissionStart := permission_.offset
            for { let index := 0 } lt(index, redeemerCount_) { index := add(index, 1) } {
                let calldataOffset := add(permissionStart, add(REDEEMERS_OFFSET, mul(index, ADDRESS_LENGTH)))
                let addressWord := calldataload(calldataOffset)
                let redeemer := shr(ADDRESS_RSHIFT, addressWord)
                mstore(add(packedRedeemers, mul(index, WORD_SIZE)), redeemer)
            }
            redeemersHash_ := keccak256(packedRedeemers, mul(redeemerCount_, WORD_SIZE))
        }
    }

    function _loadLimitTerms(bytes calldata permission_) private pure returns (LimitTerms memory terms_) {
        terms_.metaSwap = _loadAddress(permission_, METASWAP_OFFSET);
        terms_.tokenIn = _loadAddress(permission_, TOKEN_IN_OFFSET);
        terms_.tokenInAmount = _loadUint256(permission_, TOKEN_IN_AMOUNT_OFFSET);
        terms_.approvalMode = uint8(_loadByte(permission_, APPROVAL_MODE_OFFSET));
        terms_.tokenOut = _loadAddress(permission_, TOKEN_OUT_OFFSET);
        terms_.recipient = _loadAddress(permission_, RECIPIENT_OFFSET);
        terms_.tokenOutMin = _loadUint256(permission_, TOKEN_OUT_MIN_OFFSET);
        terms_.validAfter = uint128(_loadUint128(permission_, VALID_AFTER_OFFSET));
        terms_.validUntil = uint128(_loadUint128(permission_, VALID_UNTIL_OFFSET));
    }

    function _loadAddress(bytes calldata data_, uint256 offset_) private pure returns (address value_) {
        assembly ("memory-safe") {
            let word := calldataload(add(data_.offset, offset_))
            value_ := shr(ADDRESS_RSHIFT, word)
        }
    }

    function _loadUint256(bytes calldata data_, uint256 offset_) private pure returns (uint256 value_) {
        assembly ("memory-safe") {
            value_ := calldataload(add(data_.offset, offset_))
        }
    }

    function _loadUint128(bytes calldata data_, uint256 offset_) private pure returns (uint256 value_) {
        assembly ("memory-safe") {
            let word := calldataload(add(data_.offset, offset_))
            value_ := shr(UINT128_RSHIFT, word)
        }
    }

    function _loadByte(bytes calldata data_, uint256 offset_) private pure returns (uint256 value_) {
        assembly ("memory-safe") {
            let word := calldataload(add(data_.offset, offset_))
            value_ := byte(0, word)
        }
    }
}
