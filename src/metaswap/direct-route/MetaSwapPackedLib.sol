// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MetaSwapOrderLib } from "./MetaSwapOrderLib.sol";

/**
 * @title MetaSwapPackedLib
 * @notice Packed `msg.data` layout + decode for the `direct-route` MetaSwapManager.
 * @dev Same Exact/Limit auth packing as `final`; Limit trailing payload is DirectRoute `route`, not a batch.
 *
 * Layout (byte offsets include the 4-byte selector):
 *   Exact:  sel | delegator(20) offset 4 | nonce(32) offset 24 | validAfter(16) offset 56 | validUntil(16) offset 72 |
 *           redeemerCount(1) offset 88 | redeemers(20*n) offset 89 | signature(65) | batch…
 *   Limit:  sel | delegator(20) offset 4 | nonce(32) offset 24 | terms offsets 56..232 | redeemerCount(1) offset 233 |
 *           redeemers(20*n) offset 234 | signature(65) | route…
 */
library MetaSwapPackedLib {
    /// @dev Exact auth loaded once for the hash, the redeemer scan, and the timestamp check.
    struct ExactAuth {
        address delegator;
        uint256 nonce;
        uint128 validAfter;
        uint128 validUntil;
        bytes32 redeemersHash;
        uint256 redeemersOffset;
        uint256 signatureOffset;
    }

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

    uint256 private constant DELEGATOR_OFFSET = 4;
    uint256 private constant NONCE_OFFSET = 24;
    /// @dev End of `delegator | nonce`. Both flows start their own fields here.
    uint256 private constant AUTH_LENGTH = 56;
    uint256 private constant EXACT_VALID_AFTER_OFFSET = 56;
    uint256 private constant EXACT_VALID_UNTIL_OFFSET = 72;
    uint256 private constant EXACT_REDEEMER_COUNT_OFFSET = 88;
    uint256 private constant EXACT_REDEEMERS_OFFSET = 89;
    uint256 private constant METASWAP_OFFSET = 56;
    uint256 private constant TOKEN_IN_OFFSET = 76;
    uint256 private constant TOKEN_IN_AMOUNT_OFFSET = 96;
    uint256 private constant APPROVAL_MODE_OFFSET = 128;
    uint256 private constant TOKEN_OUT_OFFSET = 129;
    uint256 private constant RECIPIENT_OFFSET = 149;
    uint256 private constant TOKEN_OUT_MIN_OFFSET = 169;
    uint256 private constant VALID_AFTER_OFFSET = 201;
    uint256 private constant VALID_UNTIL_OFFSET = 217;
    uint256 private constant REDEEMER_COUNT_OFFSET = 233;
    uint256 private constant REDEEMERS_OFFSET = 234;

    uint256 private constant SIGNATURE_LENGTH = 65;
    /// @dev Packed address byte length (redeemer stride / field size)
    uint256 private constant ADDRESS_LENGTH = 20;
    /// @dev Right-shift after `calldataload` to right-align a packed address: (32 - 20) * 8
    uint256 private constant ADDRESS_RSHIFT = 96;
    /// @dev Right-shift after `calldataload` to right-align a packed uint128: (32 - 16) * 8
    uint256 private constant UINT128_RSHIFT = 128;
    /// @dev ABI word size when packing redeemers for `keccak256`
    uint256 private constant WORD_SIZE = 32;

    function decodeExact(bytes calldata data_)
        internal
        pure
        returns (ExactAuth memory auth_, bytes calldata signature_, bytes calldata batch_)
    {
        (auth_.delegator, auth_.nonce) = _auth(data_);
        if (data_.length < EXACT_REDEEMERS_OFFSET) revert InvalidCalldata();

        uint256 redeemerCount_;
        assembly ("memory-safe") {
            redeemerCount_ := byte(0, calldataload(add(data_.offset, EXACT_REDEEMER_COUNT_OFFSET)))
        }
        if (redeemerCount_ == 0) revert MetaSwapOrderLib.InvalidTerms();

        auth_.validAfter = uint128(_loadUint128(data_, EXACT_VALID_AFTER_OFFSET));
        auth_.validUntil = uint128(_loadUint128(data_, EXACT_VALID_UNTIL_OFFSET));
        auth_.redeemersOffset = EXACT_REDEEMERS_OFFSET;
        auth_.signatureOffset = EXACT_REDEEMERS_OFFSET + redeemerCount_ * ADDRESS_LENGTH;
        auth_.redeemersHash = _hashRedeemers(data_, auth_.redeemersOffset, redeemerCount_);
        (signature_, batch_) = _sliceSignatureAndPayload(data_, auth_.signatureOffset);
    }

    function decodeLimit(bytes calldata data_)
        internal
        pure
        returns (
            address delegator_,
            uint256 nonce_,
            LimitTerms memory terms_,
            bytes32 redeemersHash_,
            uint256 signatureOffset_,
            bytes calldata signature_,
            bytes calldata batch_
        )
    {
        (delegator_, nonce_) = _auth(data_);
        if (data_.length < REDEEMERS_OFFSET) revert InvalidCalldata();

        uint256 redeemerCount_;
        assembly ("memory-safe") {
            redeemerCount_ := byte(0, calldataload(add(data_.offset, REDEEMER_COUNT_OFFSET)))
        }
        if (redeemerCount_ == 0) revert MetaSwapOrderLib.InvalidTerms();

        terms_ = _loadLimitTerms(data_);
        signatureOffset_ = REDEEMERS_OFFSET + redeemerCount_ * ADDRESS_LENGTH;
        redeemersHash_ = _hashRedeemers(data_, REDEEMERS_OFFSET, redeemerCount_);
        (signature_, batch_) = _sliceSignatureAndPayload(data_, signatureOffset_);
    }

    /// @dev Require `who_` appears in the Limit redeemer list.
    function requireRedeemer(bytes calldata data_, address who_, uint256 signatureOffset_) internal pure {
        requireRedeemer(data_, who_, REDEEMERS_OFFSET, signatureOffset_);
    }

    /// @dev Require `who_` appears in packed redeemers `[redeemersOffset_, signatureOffset_)`.
    function requireRedeemer(bytes calldata data_, address who_, uint256 redeemersOffset_, uint256 signatureOffset_) internal pure {
        for (uint256 offset_ = redeemersOffset_;; offset_ += ADDRESS_LENGTH) {
            if (offset_ == signatureOffset_) revert UnauthorizedRedeemer();
            if (_loadAddress(data_, offset_) == who_) return;
        }
    }

    /// @dev `keccak256(abi.encodePacked(redeemers))` without building a memory address[].
    function _hashRedeemers(
        bytes calldata data_,
        uint256 redeemersOffset_,
        uint256 redeemerCount_
    )
        private
        pure
        returns (bytes32 redeemersHash_)
    {
        assembly ("memory-safe") {
            let packedRedeemers := mload(0x40)
            let dataStart := data_.offset
            for { let index := 0 } lt(index, redeemerCount_) { index := add(index, 1) } {
                let calldataOffset := add(dataStart, add(redeemersOffset_, mul(index, ADDRESS_LENGTH)))
                let addressWord := calldataload(calldataOffset)
                let redeemer := shr(ADDRESS_RSHIFT, addressWord)
                mstore(add(packedRedeemers, mul(index, WORD_SIZE)), redeemer)
            }
            redeemersHash_ := keccak256(packedRedeemers, mul(redeemerCount_, WORD_SIZE))
        }
    }

    function _auth(bytes calldata data_) private pure returns (address delegator_, uint256 nonce_) {
        if (data_.length < AUTH_LENGTH) revert InvalidCalldata();
        assembly ("memory-safe") {
            let dataStart := data_.offset
            let delegatorWord := calldataload(add(dataStart, DELEGATOR_OFFSET))
            delegator_ := shr(ADDRESS_RSHIFT, delegatorWord)
            nonce_ := calldataload(add(dataStart, NONCE_OFFSET))
        }
    }

    function _loadLimitTerms(bytes calldata data_) private pure returns (LimitTerms memory terms_) {
        terms_.metaSwap = _loadAddress(data_, METASWAP_OFFSET);
        terms_.tokenIn = _loadAddress(data_, TOKEN_IN_OFFSET);
        terms_.tokenInAmount = _loadUint256(data_, TOKEN_IN_AMOUNT_OFFSET);
        terms_.approvalMode = uint8(_loadByte(data_, APPROVAL_MODE_OFFSET));
        terms_.tokenOut = _loadAddress(data_, TOKEN_OUT_OFFSET);
        terms_.recipient = _loadAddress(data_, RECIPIENT_OFFSET);
        terms_.tokenOutMin = _loadUint256(data_, TOKEN_OUT_MIN_OFFSET);
        terms_.validAfter = uint128(_loadUint128(data_, VALID_AFTER_OFFSET));
        terms_.validUntil = uint128(_loadUint128(data_, VALID_UNTIL_OFFSET));
    }

    function _sliceSignatureAndPayload(
        bytes calldata data_,
        uint256 signatureStart_
    )
        private
        pure
        returns (bytes calldata signature_, bytes calldata payload_)
    {
        uint256 signatureEnd_ = signatureStart_ + SIGNATURE_LENGTH;
        if (data_.length < signatureEnd_) revert InvalidCalldata();
        assembly ("memory-safe") {
            let dataStart := data_.offset
            signature_.offset := add(dataStart, signatureStart_)
            signature_.length := SIGNATURE_LENGTH
            payload_.offset := add(dataStart, signatureEnd_)
            payload_.length := sub(data_.length, signatureEnd_)
        }
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
