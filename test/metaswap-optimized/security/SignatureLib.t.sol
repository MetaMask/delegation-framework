// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @notice Adversarial coverage for MetaSwap's ECDSA.recover auth path (mirrors managers).
 * @dev Proves low-s / v gating via OZ ECDSA, that malleated sigs still recover under raw
 *      `ecrecover` (so the check is load-bearing), and wrong-signer / zero-delegator rejects.
 */
contract MetaSwapEcdsaHarness {
    error InvalidDelegator();
    error InvalidEOASignature();

    function validate(address delegator_, bytes32 digest_, bytes memory signature_) external pure {
        if (delegator_ == address(0)) revert InvalidDelegator();
        if (ECDSA.recover(digest_, signature_) != delegator_) revert InvalidEOASignature();
    }

    function recover(bytes32 digest_, bytes memory signature_) external pure returns (address) {
        return ECDSA.recover(digest_, signature_);
    }
}

contract SignatureLibTest is Test {
    uint256 private constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 private constant HALF_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    uint256 private constant SIGNER_KEY = 0xA11CE;
    bytes32 private constant DIGEST = keccak256("metaswap-ecdsa");

    MetaSwapEcdsaHarness internal lib;
    address internal signer;

    function setUp() public {
        lib = new MetaSwapEcdsaHarness();
        signer = vm.addr(SIGNER_KEY);
    }

    ////////////////////////////// Happy path //////////////////////////////

    function test_validSignature_recoversAndValidates() public {
        bytes memory signature_ = _sign(SIGNER_KEY, DIGEST);
        assertEq(lib.recover(DIGEST, signature_), signer);
        lib.validate(signer, DIGEST, signature_);
    }

    function test_sAtHalfOrder_acceptedWhenRecoverable() public {
        (bytes32 r_, uint8 v_) = _rsv(_sign(SIGNER_KEY, DIGEST));
        bytes memory signature_ = abi.encodePacked(r_, bytes32(HALF_ORDER), v_);
        (address oz_, ECDSA.RecoverError err_,) = ECDSA.tryRecover(DIGEST, signature_);
        if (err_ == ECDSA.RecoverError.NoError) {
            assertEq(lib.recover(DIGEST, signature_), oz_);
        } else {
            vm.expectRevert();
            lib.recover(DIGEST, signature_);
        }
    }

    ////////////////////////////// Malleability //////////////////////////////

    function test_highS_malleation_rawEcrecoverAccepts_ozRejects() public {
        bytes memory good_ = _sign(SIGNER_KEY, DIGEST);
        bytes memory bad_ = _malleate(good_);

        assertEq(_rawEcrecover(DIGEST, good_), signer, "fixture");
        assertEq(_rawEcrecover(DIGEST, bad_), signer, "malleation must still recover under raw ecrecover");

        (address oz_, ECDSA.RecoverError err_, bytes32 s_) = ECDSA.tryRecover(DIGEST, bad_);
        assertEq(oz_, address(0));
        assertTrue(err_ == ECDSA.RecoverError.InvalidSignatureS || err_ == ECDSA.RecoverError.InvalidSignature);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, s_));
        lib.validate(signer, DIGEST, bad_);
    }

    function test_sExactlyHalfOrderPlusOne_rejected() public {
        (bytes32 r_, uint8 v_) = _rsv(_sign(SIGNER_KEY, DIGEST));
        bytes memory signature_ = abi.encodePacked(r_, bytes32(HALF_ORDER + 1), v_);
        (address oz_, ECDSA.RecoverError err_,) = ECDSA.tryRecover(DIGEST, signature_);
        assertEq(uint8(err_), uint8(ECDSA.RecoverError.InvalidSignatureS));
        assertEq(oz_, address(0));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, bytes32(HALF_ORDER + 1)));
        lib.recover(DIGEST, signature_);
    }

    function test_sNearCurveOrder_rejected() public {
        (bytes32 r_, uint8 v_) = _rsv(_sign(SIGNER_KEY, DIGEST));
        bytes memory signature_ = abi.encodePacked(r_, bytes32(SECP256K1_N - 1), v_);
        vm.expectRevert();
        lib.recover(DIGEST, signature_);
    }

    ////////////////////////////// v / length / garbage //////////////////////////////

    function test_rejectsBadV_values() public {
        bytes memory signature_ = _sign(SIGNER_KEY, DIGEST);
        uint8[5] memory badVs_ = [uint8(0), 1, 26, 29, 255];
        for (uint256 i_; i_ < badVs_.length; ++i_) {
            signature_[64] = bytes1(badVs_[i_]);
            vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
            lib.validate(signer, DIGEST, signature_);
        }
    }

    function test_acceptsBothCanonicalV() public {
        bytes memory signature_ = _sign(SIGNER_KEY, DIGEST);
        uint8 v_ = uint8(signature_[64]);
        assertTrue(v_ == 27 || v_ == 28);
        assertEq(lib.recover(DIGEST, signature_), signer);
    }

    function test_rejectsWrongLengths() public {
        bytes memory good_ = _sign(SIGNER_KEY, DIGEST);
        _assertBadLength(hex"");
        _assertBadLength(_slice(good_, 64));
        _assertBadLength(bytes.concat(good_, hex"00"));
        _assertBadLength(bytes.concat(good_, good_));
    }

    function test_rejectsAllZeroSignature() public {
        bytes memory signature_ = new bytes(65);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        lib.validate(signer, DIGEST, signature_);
    }

    function test_rejectsZeroRS() public {
        bytes memory signature_ = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        assertEq(_rawEcrecover(DIGEST, signature_), address(0));
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        lib.recover(DIGEST, signature_);
    }

    function test_rejectsFlippedRByte() public {
        bytes memory signature_ = _sign(SIGNER_KEY, DIGEST);
        signature_[0] = bytes1(uint8(signature_[0]) ^ 0xff);
        vm.expectRevert();
        lib.validate(signer, DIGEST, signature_);
    }

    ////////////////////////////// Auth binding //////////////////////////////

    function test_rejectsWrongSigner() public {
        bytes memory signature_ = _sign(SIGNER_KEY, DIGEST);
        address other_ = vm.addr(0xB0B);
        vm.expectRevert(MetaSwapEcdsaHarness.InvalidEOASignature.selector);
        lib.validate(other_, DIGEST, signature_);
    }

    function test_rejectsZeroDelegator_evenWithValidSignature() public {
        bytes memory signature_ = _sign(SIGNER_KEY, DIGEST);
        vm.expectRevert(MetaSwapEcdsaHarness.InvalidDelegator.selector);
        lib.validate(address(0), DIGEST, signature_);
    }

    function test_rejectsWrongDigest() public {
        bytes memory signature_ = _sign(SIGNER_KEY, DIGEST);
        bytes32 otherDigest_ = keccak256("other");
        vm.expectRevert(MetaSwapEcdsaHarness.InvalidEOASignature.selector);
        lib.validate(signer, otherDigest_, signature_);
    }

    function test_signatureForAliceRejectedAsBob() public {
        uint256 bobKey_ = 0xB0B;
        address bob_ = vm.addr(bobKey_);
        bytes memory aliceSig_ = _sign(SIGNER_KEY, DIGEST);
        bytes memory bobSig_ = _sign(bobKey_, DIGEST);
        lib.validate(signer, DIGEST, aliceSig_);
        lib.validate(bob_, DIGEST, bobSig_);
        vm.expectRevert(MetaSwapEcdsaHarness.InvalidEOASignature.selector);
        lib.validate(bob_, DIGEST, aliceSig_);
        vm.expectRevert(MetaSwapEcdsaHarness.InvalidEOASignature.selector);
        lib.validate(signer, DIGEST, bobSig_);
    }

    ////////////////////////////// Fuzz //////////////////////////////

    function testFuzz_validSignature_matchesOz(uint256 key_, bytes32 digest_) public {
        key_ = bound(key_, 1, SECP256K1_N - 1);
        address expected_ = vm.addr(key_);
        bytes memory signature_ = _sign(key_, digest_);

        assertEq(lib.recover(digest_, signature_), expected_);
        assertEq(ECDSA.recover(digest_, signature_), expected_);
        lib.validate(expected_, digest_, signature_);
    }

    function testFuzz_malleatedSignature_rejected(uint256 key_, bytes32 digest_) public {
        key_ = bound(key_, 1, SECP256K1_N - 1);
        address expected_ = vm.addr(key_);
        bytes memory good_ = _sign(key_, digest_);
        bytes memory bad_ = _malleate(good_);

        assertEq(_rawEcrecover(digest_, bad_), expected_, "attack works on raw ecrecover");
        (address oz_, ECDSA.RecoverError err_,) = ECDSA.tryRecover(digest_, bad_);
        assertEq(oz_, address(0));
        assertTrue(err_ == ECDSA.RecoverError.InvalidSignatureS || err_ == ECDSA.RecoverError.InvalidSignature);
        vm.expectRevert();
        lib.validate(expected_, digest_, bad_);
    }

    function testFuzz_wrongSigner_rejected(uint256 key_, uint256 otherKey_, bytes32 digest_) public {
        key_ = bound(key_, 1, SECP256K1_N - 1);
        otherKey_ = bound(otherKey_, 1, SECP256K1_N - 1);
        vm.assume(key_ != otherKey_);
        bytes memory signature_ = _sign(key_, digest_);
        vm.expectRevert(MetaSwapEcdsaHarness.InvalidEOASignature.selector);
        lib.validate(vm.addr(otherKey_), digest_, signature_);
    }

    ////////////////////////////// Helpers //////////////////////////////

    function _sign(uint256 key_, bytes32 digest_) private pure returns (bytes memory) {
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, digest_);
        return abi.encodePacked(r_, s_, v_);
    }

    function _rsv(bytes memory signature_) private pure returns (bytes32 r_, uint8 v_) {
        v_ = uint8(signature_[64]);
        assembly {
            r_ := mload(add(signature_, 0x20))
        }
    }

    function _malleate(bytes memory signature_) private pure returns (bytes memory) {
        bytes32 r_;
        bytes32 s_;
        uint8 v_ = uint8(signature_[64]);
        assembly {
            r_ := mload(add(signature_, 0x20))
            s_ := mload(add(signature_, 0x40))
        }
        return abi.encodePacked(r_, bytes32(SECP256K1_N - uint256(s_)), v_ == 27 ? uint8(28) : uint8(27));
    }

    function _rawEcrecover(bytes32 digest_, bytes memory signature_) private pure returns (address) {
        require(signature_.length == 65, "len");
        bytes32 r_;
        bytes32 s_;
        uint8 v_ = uint8(signature_[64]);
        assembly {
            r_ := mload(add(signature_, 0x20))
            s_ := mload(add(signature_, 0x40))
        }
        return ecrecover(digest_, v_, r_, s_);
    }

    function _slice(bytes memory data_, uint256 length_) private pure returns (bytes memory out_) {
        out_ = new bytes(length_);
        for (uint256 i_; i_ < length_; ++i_) {
            out_[i_] = data_[i_];
        }
    }

    function _assertBadLength(bytes memory signature_) private {
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, signature_.length));
        lib.validate(signer, DIGEST, signature_);
    }
}
