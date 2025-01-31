// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { DeleGatorCore } from "../../src/DeleGatorCore.sol";

struct TestUser {
    string name;
    address payable addr;
    uint256 privateKey;
    DeleGatorCore deleGator;
    uint256 x;
    uint256 y;
}

struct TestUsers {
    TestUser bundler;
    TestUser alice;
    TestUser bob;
    TestUser carol;
    TestUser dave;
    TestUser eve;
    TestUser frank;
}

/**
 * @title Implementation Enum
 * @dev This enum represents the different types of Delegator implementations.
 */
enum Implementation {
    MultiSig, // MultiSigDeleGator is a DeleGator that is owned by a set of EOA addresses.
    Hybrid, // HybridDeleGator is a DeleGator that is owned by a set of P256 Keys and EOA
    EIP7702Stateless // EIP7702Stateless is a DeleGator that is owned by the EIP7702 EOA

}

/**
 * @title Signature Type
 * @dev This enum represents the different types of Signatures.
 */
enum SignatureType {
    MultiSig,
    EOA,
    RawP256
}
