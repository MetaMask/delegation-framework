// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { FCL_ecdsa } from "@freshCryptoLib/FCL_ecdsa.sol";
import { FCL_ecdsa_utils } from "@freshCryptoLib/FCL_ecdsa_utils.sol";
import { FCL_Elliptic_ZZ } from "@freshCryptoLib/FCL_elliptic.sol";

// NOTE - This Library has been taken from
// https://github.com/rdubois-crypto/FreshCryptoLib/blob/ec7122f20900f9486a7c018d635f69738b14dfc3/solidity/tests/WebAuthn_forge/script/DeployElliptic.s.sol#L18
// and modified for test usage. The original returns abi.encodePacked(bool), it has been modified to use abi.encode(bool).
contract FCL_all_wrapper {
    /* default is EIP7212 precompile as described in https://eips.ethereum.org/EIPS/eip-7212*/
    fallback(bytes calldata input) external returns (bytes memory) {
        if ((input.length != 160) && (input.length != 180)) {
            return abi.encode(0);
        }

        bytes32 message = bytes32(input[0:32]);
        uint256 r = uint256(bytes32(input[32:64]));
        uint256 s = uint256(bytes32(input[64:96]));
        uint256 Qx = uint256(bytes32(input[96:128]));
        uint256 Qy = uint256(bytes32(input[128:160]));
        /* no precomputations */
        if (input.length == 160) {
            return abi.encode(FCL_ecdsa.ecdsa_verify(message, r, s, Qx, Qy));
        }

        /* with precomputations written at address prec (previously generated using ecdsa_precalc_8dim*/
        if (input.length == 180) {
            //untested:TODO
            address prec = address(uint160(uint256(bytes32(input[160:180]))));
            return abi.encode(FCL_ecdsa.ecdsa_precomputed_verify(message, r, s, prec));
        }
    }

    /* ecdsa functions */
    function ecdsa_verify(bytes32 message, uint256 r, uint256 s, uint256 Qx, uint256 Qy) external view returns (bool) {
        return FCL_ecdsa.ecdsa_verify(message, r, s, Qx, Qy);
    }

    function ecdsa_verify(bytes32 message, uint256[2] calldata rs, uint256[2] calldata Q) external view returns (bool) {
        return FCL_ecdsa_utils.ecdsa_verify(message, rs, Q);
    }

    function ecdsa_precomputed_verify(bytes32 message, uint256 r, uint256 s, address prec) external view returns (bool) {
        return FCL_ecdsa.ecdsa_precomputed_verify(message, r, s, prec);
    }

    function ecdsa_sign(bytes32 message, uint256 k, uint256 kpriv) external view returns (uint256 r, uint256 s) {
        return FCL_ecdsa_utils.ecdsa_sign(message, k, kpriv);
    }

    function ecdsa_DerivKpub(uint256 kpriv) external view returns (uint256 x, uint256 y) {
        return FCL_ecdsa_utils.ecdsa_derivKpub(kpriv);
    }

    function ecdsa_GenKeyPair() external view returns (uint256 kpriv, uint256 x, uint256 y) {
        kpriv = block.prevrandao ^ 0xcacacacacaca; //avoid null key for chain not implementing prevrandao
        (x, y) = FCL_ecdsa_utils.ecdsa_derivKpub(kpriv);
    }

    function ecdsa_precalc_8dim(uint256 Qx, uint256 Qy) external view returns (uint256[2][256] memory Prec) {
        return FCL_ecdsa_utils.Precalc_8dim(Qx, Qy);
    }
}
