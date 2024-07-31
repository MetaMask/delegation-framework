// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { FCL_Elliptic_ZZ } from "@freshCryptoLib/FCL_elliptic.sol";
import { FCL_ecdsa } from "@freshCryptoLib/FCL_ecdsa.sol";

import { WebAuthn } from "./WebAuthn.sol";

/**
 * @title P256FCLVerifierLib
 * @notice Provides functionality to verify the P256 signature utilizing the Fresh Crypto library
 * (https://github.com/rdubois-crypto/FreshCryptoLib)
 */
library P256FCLVerifierLib {
    uint256 constant P256_N_DIV_2 = FCL_Elliptic_ZZ.n / 2;

    // As mentioned in the 7212 RIP Spec, the P256Verify Precompile address is 0x100
    // https://github.com/ethereum/RIPs/blob/master/RIPS/rip-7212.md
    address constant VERIFIER = address(0x100);

    /**
     *
     * @param _x The X coordinate of the public key that signed the message
     * @param _y The Y coordinate of the public key that signed the message
     */
    function isValidPublicKey(uint256 _x, uint256 _y) internal pure returns (bool) {
        return FCL_Elliptic_ZZ.ecAff_isOnCurve(_x, _y);
    }

    /**
     *
     * @param message_hash The hash to be verified
     * @param r The r component of the signature
     * @param s The s component of the signature
     * @param x The X coordinate of the public key that signed the message
     * @param y The Y coordinate of the public key that signed the message
     */
    function verifySignature(bytes32 message_hash, uint256 r, uint256 s, uint256 x, uint256 y) internal view returns (bool) {
        // check for signature malleability
        if (s > P256_N_DIV_2) {
            return false;
        }

        bytes memory args = abi.encode(message_hash, r, s, x, y);

        // attempt to verify using the RIP-7212 precompiled contract
        (bool success, bytes memory ret) = VERIFIER.staticcall(args);

        // staticcall returns true when the precompile does not exist but the ret.length is 0.
        // an invalid signature gets validated twice, simulate this offchain to save gas.
        bool valid = ret.length > 0;
        if (success && valid) return abi.decode(ret, (uint256)) == 1;

        return FCL_ecdsa.ecdsa_verify(message_hash, r, s, x, y);
    }
}
