// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import {
    CALLTYPE_SINGLE, CALLTYPE_BATCH, EXECTYPE_DEFAULT, EXECTYPE_TRY, MODE_DEFAULT, MODE_OFFSET
} from "@erc7579/lib/ModeLib.sol";

bytes32 constant EIP712_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

// NOTE: signature is omitted from the Delegation typehash
bytes32 constant DELEGATION_TYPEHASH = keccak256(
    "Delegation(address delegate,address delegator,bytes32 authority,Caveat[] caveats,uint256 salt)Caveat(address enforcer,bytes terms)"
);

bytes32 constant CAVEAT_TYPEHASH = keccak256("Caveat(address enforcer,bytes terms)");
