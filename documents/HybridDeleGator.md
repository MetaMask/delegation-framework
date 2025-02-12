# Hybrid DeleGator Smart Contract

### Overview

The Hybrid DeleGator is a Solidity smart contract that extends the functionality of the DeleGatorCore contract. It facilitates externally owned account (EOA) signatures and NIST P256 elliptic curve signatures to manage access control for the DeleGator.

### Considerations

- Multiple signers can be added but only 1 signer is needed for a valid signature.
- There must always be at least one active signer either EOA or P256.
- There is a function to completely replace all the signers and more specific functions to add or remove signers.
- Contracts as the owner are valid for delegation signature validation but are not valid for UserOp validation.

### Features

EOA-Signature Support: Enables signers to use the EOAs signature generation.
P256-Signature Support: Enables signers to use the P256 curve for signature generation.

Delegation: Allows for delegation of transaction execution to other accounts.

### P256 Signature Verification

Signature verification is handled through [SmoothCryptoLib](https://github.com/get-smooth/crypto-lib) contract. The `P256Verifier` contract is a "Progressive Precompile" contract which will forward verification calls to a precompiled version of the contract if [EIP7212](https://eips.ethereum.org/EIPS/eip-7212) is included on the chain, reducing signature verification gas costs from ~330k to ~3k.

### P256 Signatures

Signatures for the P256 DeleGator can be of two types: **Raw P256**, signatures generated using the NIST P256 elliptic curve and **WebAuthn P256**, a signature generated using the P-256 elliptic curve as part of the WebAuthn specification.

Both signatures use the same elliptic curve but the data signed and how the keys are generated and managed differs.
