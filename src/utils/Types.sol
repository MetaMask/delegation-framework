// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { PackedUserOperation } from "@account-abstraction/interfaces/PackedUserOperation.sol";

/**
 * @title EIP712Domain
 * @notice Struct representing the EIP712 domain for signature validation.
 */
struct EIP712Domain {
    string name;
    string version;
    uint256 chainId;
    address verifyingContract;
}

/**
 * @title Delegation
 * @notice Struct representing a delegation to give a delegate authority to act on behalf of a delegator.
 * @dev `signature` is ignored during delegation hashing so it can be manipulated post signing.
 */
struct Delegation {
    address delegate;
    address delegator;
    bytes32 authority;
    Caveat[] caveats;
    uint256 salt;
    bytes signature;
}

/**
 * @title Caveat
 * @notice Struct representing a caveat to enforce on a delegation.
 * @dev `args` is ignored during caveat hashing so it can be manipulated post signing.
 */
struct Caveat {
    address enforcer;
    bytes terms;
    bytes args;
}

/**
 * @title Action
 * @notice This struct represents an action to be taken.
 * @dev It is used to pass the action of a transaction to a CaveatEnforcer.
 * It only includes the functional part of a transaction, allowing it to be
 * agnostic whether this was sent from a protocol-level tx or UserOperation.
 */
struct Action {
    address to;
    uint256 value;
    bytes data;
}

/**
 * @title P256 Public Key
 * @notice Struct containing the X and Y coordinates of a P256 public key.
 */
struct P256PublicKey {
    uint256 x;
    uint256 y;
}

struct DecodedWebAuthnSignature {
    uint256 r;
    uint256 s;
    bytes authenticatorData;
    bool requireUserVerification;
    string clientDataJSONPrefix;
    string clientDataJSONSuffix;
    uint256 responseTypeLocation;
}
