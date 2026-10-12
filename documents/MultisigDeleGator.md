# MultiSig DeleGator Smart Contract

### Overview

The MultiSigDeleGator is a Solidity smart contract that extends the functionality of the DeleGatorCore contract. It facilitates multi-signature based access control and delegation. Signers can be externally owned accounts (EOAs) or ERC-1271 contracts, including other MultiSigDeleGators.

### Features

Multi-Signature Support: Enables multi-signature transactions with a flexible threshold.

Delegation: Allows for delegation of transaction execution to other accounts.

The minimum threshold of signatures must be obtained to execute a transaction.

Signatures must be sorted in ascending order by the address of the signer.

### Signature Format

The signature is exactly a threshold amount of entries joined together, sorted by signer address (ascending). Every entry starts with 65 bytes, and the last of these bytes marks the type of the entry:

```
EOA signer (65 bytes), v is 27 or 28:
+----------------+----------------+-------+
|     r (32)     |     s (32)     | v (1) |
+----------------+----------------+-------+

Contract signer, ERC-1271 (65 + N bytes), type is 0:
+------------------+---------+-----------+----------+-----------------+
| signer addr (20) | len (4) | zero (40) | type (1) |  signature (N)  |
+------------------+---------+-----------+----------+-----------------+
```

EOA signatures are only accepted with `v` 27 or 28, so an entry whose last header byte is 0 is never a valid EOA signature and the two types cannot be confused. The 40 bytes between the length and the type byte are reserved and must be zero. The length `N` is stored in 4 bytes, so in practice the transaction size is the only limit on a contract signature.

A contract signer entry is only accepted for a registered signer that has code at validation time. A contract signer can itself be a MultiSigDeleGator, in which case its signature is that MultiSigDeleGator's own signature.

`isValidSignature` returns the ERC-1271 magic value `0x1626ba7e` for a valid signature and `0xffffffff` for any invalid one. It does not revert for invalid signature bytes, or when a contract signer reverts or returns an unexpected value. The only exception is a contract signer that uses up the gas (see Considerations).

Example:

```
Root (2 of 3)
 |- Alice (EOA)
 |- Dave (EOA)
 |- Sub (2 of 2)
     |- Bob (EOA)
     |- Carol (EOA)
```

To sign a hash for `Root` with Alice and `Sub`:

```
Sub signature  = bobSig | carolSig                  (Bob and Carol sign the hash, sorted by address)
Sub entry      = Sub header | Sub signature         (header: Sub address | length | 40 zero bytes | 0)
Root signature = aliceSig | Sub entry               (Alice signs the hash, sorted by address)
```

### Considerations

- A contract signer is fully trusted. Its `isValidSignature` decides whether it approves, and its answer can change over time (for example, an upgradeable contract or an EIP-7702 re-delegation). A signature that is valid now can become invalid later.
- An EOA signer that has EIP-7702 code can sign in two ways: with a plain ECDSA signature, or with a contract signer entry that its delegated code checks. So its approval is only as strong as its delegated code, as for any contract signer.
- The gas used by a contract signer's validation counts toward the caller of `isValidSignature`, or the UserOp verification gas. A contract signer that uses up the gas, for example by returning a very large amount of data, makes validation fail with an out-of-gas error instead of returning `0xffffffff`.
- Some contract signers read their own storage to validate a signature, for example a nested MultiSigDeleGator (its signers) or a HybridDeleGator (its keys). During UserOp validation, the ERC-4337 bundler rules (ERC-7562) do not allow this for unstaked accounts, so public mempool bundlers reject such UserOps. The [EntryPoint v0.8 release notes](https://github.com/eth-infinitism/account-abstraction/releases/tag/v0.8.0) extend this storage access to all staked entities. An unstaked account with such signers needs a stake (EntryPoint v0.8 or later) or a private bundler. Signatures checked outside UserOp validation, such as in delegation redemption, are not affected.
- A contract signer that is not deployed yet (no code) cannot sign until it is deployed.
- Two MultiSigDeleGators can be signers of each other. This is harmless: each nested level validates a strictly shorter part of the signature, so validation always ends.

### Signer Management

The contract provides functions to manage signers:

- Replace Signer: Replace an existing signer with a new one.

- Add Signer: Add a new signer to the contract.

- Remove Signer: Remove a signer from the contract.

- Update Threshold: Adjust the threshold for executing transactions.
