/**
 *
 */
/*
/*   ╔═╗╔╦╗╔═╗╔═╗╔╦╗╦ ╦  ╔═╗╦═╗╦ ╦╔═╗╔╦╗╔═╗╦  ╦╔╗ 
/*   ╚═╗║║║║ ║║ ║ ║ ╠═╣  ║  ╠╦╝╚╦╝╠═╝ ║ ║ ║║  ║╠╩╗
/*   ╚═╝╩ ╩╚═╝╚═╝o╩ ╩ ╩  ╚═╝╩╚═ ╩ ╩   ╩ ╚═╝╩═╝╩╚═╝
/*              
/* Copyright (C) 2024 - Renaud Dubois - This file is part of SCL (Smoo.th CryptoLib) project
/* License: This software is licensed under MIT License (and allways will)      
/* Description: This file implements the ecdsa verification protocol using Shamir's trick + 4bit windowing.                                        
/********************************************************************************************/
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import { a, b, p, gx, gy, n } from "@SCL/fields/SCL_secp256r1.sol";

//import modular inversion over prime field defined over curve subgroup of prime order
import { nModInv } from "@SCL/modular/SCL_modular.sol";
//import point on curve checking
import { ec_isOnCurve } from "@SCL/elliptic/SCL_ecOncurve.sol";
//import point double multiplication and accumulation (RIP7696)
import "@SCL/elliptic/SCL_mulmuladdX_fullgenW.sol";

library SCL_RIP7212 {
    function verify(bytes32 message, uint256 r, uint256 s, uint256 qx, uint256 qy) internal view returns (bool) {
        // check the validity of the signature
        if (r == 0 || r >= n || s == 0 || s >= n) {
            return false;
        }

        // check the public key validity (rejecting not on curve and weak keys)
        if (ec_isOnCurve(p, a, b, qx, qy) == false) {
            return false;
        }

        // calculate the scalars used for the multiplication of the point
        uint256 sInv = nModInv(s);
        uint256 scalar_u = mulmod(uint256(message), sInv, n);
        uint256 scalar_v = mulmod(r, sInv, n);
        uint256[6] memory Qpa = [qx, qy, p, a, gx, gy];

        uint256 x1;
        (x1,) = ecGenMulmuladdB4W(Qpa, scalar_u, scalar_v);

        assembly {
            x1 := addmod(x1, sub(n, r), n)
        }

        return x1 == 0;
    }
}
