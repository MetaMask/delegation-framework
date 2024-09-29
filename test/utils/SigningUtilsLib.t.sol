// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Vm } from "forge-std/Vm.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";

import { P256SCLVerifierLib } from "../../src/libraries/P256SCLVerifierLib.sol";

import { TestUser, SignatureType } from "./Types.t.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

// NOTE: These signature schemes are tightly coupled to our DeleGator. We should eventually move things closer
// together.

// Default Signature Schemes
// Ownable - Owned by the TestUser
// MultiSigDeleGator - 1/1 owned by the TestUser
// HybridDeleGator - 1 Raw P256 Key using the TestUser's PK for the key generation and their name as Key ID OR 1 EOA.
library SigningUtilsLib {
    ////////////////////////////// State //////////////////////////////

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant P256_N = 115792089210356248762697446949407573529996955224135760342422259061068512044369;

    ////////////////////// Public Helpers //////////////////////

    /// @notice Uses the private key to sign a hash.
    function signHash_EOA(uint256 _privateKey, bytes32 _hash) public pure returns (bytes memory signature_) {
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_privateKey, _hash);
        signature_ = abi.encodePacked(r_, s_, v_);
    }

    /// @notice Generates the private keys from seeds and uses them to sign a hash and combine the signatures.
    function signHash_MultiSig(uint256[] memory _privateKeys, bytes32 _hash) public pure returns (bytes memory signature_) {
        for (uint256 i = 0; i < _privateKeys.length; ++i) {
            uint256 privateKey_ = _privateKeys[i];
            bytes memory usersSignature_ = signHash_EOA(privateKey_, _hash);
            signature_ = BytesLib.concat(signature_, usersSignature_);
        }
    }

    /// @notice Generates the private keys from seeds and uses them to sign a hash and combine the signatures.
    function signHash_P256(
        string memory _keyId,
        uint256 _privateKey,
        bytes32 _hash
    )
        public
        pure
        returns (bytes memory signature_)
    {
        (bytes32 r_, bytes32 s_) = vm.signP256(_privateKey, sha256(abi.encodePacked(_hash)));

        if (uint256(s_) > P256SCLVerifierLib.P256_N_DIV_2) {
            s_ = bytes32(P256_N - uint256(s_));
        }

        signature_ = abi.encodePacked(keccak256(abi.encodePacked(_keyId)), r_, s_);
    }
}
