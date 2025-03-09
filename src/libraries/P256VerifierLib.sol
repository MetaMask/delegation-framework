// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { WebAuthn } from "./WebAuthn.sol";
import { P256SCLVerifierLib } from "./P256SCLVerifierLib.sol";
import { DecodedWebAuthnSignature } from "../utils/Types.sol";

/**
 * @title P256VerifierLib
 * @notice Provides functionality to decode P256 signatures into their components
 * @dev This library wraps Daimo's Progressive Precompile P256 Verifier
 */
library P256VerifierLib {
    /**
     * @notice Decodes a raw P256 signature and verifies it against the provided hash using a progressive precompile P256 verifier
     * @dev Raw P256 signatures encode: keyId hash, r, s
     * @param _hash The hash to be verified
     * @param _signature The signature to be verified
     * @param _x The X coordinate of the public key that signed the message
     * @param _y The Y coordinate of the public key that signed the message
     */
    function _verifyRawP256Signature(bytes32 _hash, bytes memory _signature, uint256 _x, uint256 _y) internal view returns (bool) {
        (uint256 r_, uint256 s_) = _decodeRawP256Signature(_signature);
        bytes32 messageHash_ = sha256(abi.encodePacked(_hash));
        return P256SCLVerifierLib.verifySignature(messageHash_, r_, s_, _x, _y);
    }

    /**
     * @notice Decodes a WebAuthn P256 signature and verifies it against the provided hash using a progressive precompile P256
     * verifier
     * @dev WebAuthn P256 signatures encode: keyId hash, r, s, challenge, authenticatorData, requireUserVerification,
     * clientDataJSON,
     * challengeLocation, responseTypeLocation
     * @param _hash The hash to be verified
     * @param _signature The signature to be verified
     * @param _x The X coordinate of the public key that signed the message
     * @param _y The Y coordinate of the public key that signed the message
     */
    function _verifyWebAuthnP256Signature(
        bytes32 _hash,
        bytes memory _signature,
        uint256 _x,
        uint256 _y
    )
        internal
        view
        returns (bool)
    {
        DecodedWebAuthnSignature memory decodedSignature = _decodeWebAuthnP256Signature(_signature);

        return WebAuthn.verifySignature({
            challenge: abi.encodePacked(_hash),
            authenticatorData: decodedSignature.authenticatorData,
            requireUserVerification: decodedSignature.requireUserVerification,
            clientDataJSONPrefix: decodedSignature.clientDataJSONPrefix,
            clientDataJSONSuffix: decodedSignature.clientDataJSONSuffix,
            responseTypeLocation: decodedSignature.responseTypeLocation,
            r: decodedSignature.r,
            s: decodedSignature.s,
            x: _x,
            y: _y
        });
    }

    /**
     * @notice This function decodes a raw P256 signature
     * @dev The signature consists of: bytes32, uint256, uint256
     * @param _signature The signature to be decoded
     * @return r_ The r component of the signature
     * @return s_ The s component of the signature
     */
    function _decodeRawP256Signature(bytes memory _signature) internal pure returns (uint256 r_, uint256 s_) {
        (, r_, s_) = abi.decode(_signature, (bytes32, uint256, uint256));
    }

    /**
     * @notice This function decodes the signature for WebAuthn P256 signature
     * @dev The signature consists of: bytes32, uint256, uint256, bytes, bytes, bool, string, uint256, uint256
     * @param _signature The signature to be decoded
     * @return decodedSig the decoded signature
     */
    function _decodeWebAuthnP256Signature(bytes memory _signature)
        internal
        pure
        returns (DecodedWebAuthnSignature memory decodedSig)
    {
        (
            ,
            decodedSig.r,
            decodedSig.s,
            decodedSig.authenticatorData,
            decodedSig.requireUserVerification,
            decodedSig.clientDataJSONPrefix,
            decodedSig.clientDataJSONSuffix,
            decodedSig.responseTypeLocation
        ) = abi.decode(_signature, (bytes32, uint256, uint256, bytes, bool, string, string, uint256));
    }
}
