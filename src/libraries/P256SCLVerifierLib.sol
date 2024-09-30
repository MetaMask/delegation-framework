// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { SCL_RIP7212 } from "@SCL/lib/libSCL_RIP7212.sol";
import { ec_isOnCurve } from "@SCL/elliptic/SCL_ecOncurve.sol";
import { a, b, p, n } from "@SCL/fields/SCL_secp256r1.sol";

import { WebAuthn } from "./WebAuthn.sol";

/**
 * @title P256SCLVerifierLib
 * @notice Provides functionality to verify the P256 signature utilizing the Smooth Crypto library
 * (https://github.com/get-smooth/crypto-lib)
 */
library P256SCLVerifierLib {
    uint256 constant P256_N_DIV_2 = n / 2;

    // As mentioned in the 7212 RIP Spec, the P256Verify Precompile address is 0x100
    // https://github.com/ethereum/RIPs/blob/master/RIPS/rip-7212.md
    address constant VERIFIER = address(0x100);

    /**
     *
     * @param _x The X coordinate of the public key that signed the message
     * @param _y The Y coordinate of the public key that signed the message
     */
    function isValidPublicKey(uint256 _x, uint256 _y) internal pure returns (bool) {
        return ec_isOnCurve(p, a, b, _x, _y);
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

        return SCL_RIP7212.verify(message_hash, r, s, x, y);
    }
}
