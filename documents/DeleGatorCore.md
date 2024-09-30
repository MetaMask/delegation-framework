# DeleGator Core

Defines the interface needed for a `DelegationManager` to invoke an `Execution` on behalf of the delegator.

This contract does not implement ERC7579 see [ERC-7579 Details](/documents/PartialERC7579.md).

# MetaMask's DeleGatorCore

Contains the logic needed for an ERC4337 SCA with delegation functionality. We provide two different "DeleGator implementations" for use: [MultiSigDeleGator](/documents/MultisigDeleGator.md) and [HybridDeleGator](/documents/HybridDeleGator.md). The distinction between the two is the signing mechanisms.

There are two methods available to upgrade your account to a different implementation.

- `upgradeToAndCall` - This method is exposed by the UUPSUpgradable contract and upgrades the account to a different implementation defaulting to clearing the storage associated to the account.
- `upgradeToAndCallAndRetainStorage` - This method upgrades the account to a different implementation and retains the storage associated to the account.

# Signing a UserOperation

Contracts that extend the DeleGatorCore contract MUST use [EIP712](https://eips.ethereum.org/EIPS/eip-712) typed data signatures for User Operations to provide legibility when signing. The typed data to be signed is a [PackedUserOperation](https://github.com/eth-infinitism/account-abstraction/blob/releases/v0.7/contracts/interfaces/PackedUserOperation.sol).

## Rules

- DeleGator Implementations MUST use namespaced storage.
- DeleGator Implementations MUST inherit from DeleGatorCore as the "most base-like" (furthest right, [more info](https://docs.soliditylang.org/en/v0.8.23/contracts.html#multiple-inheritance-and-linearization))
- DeleGator Implementations MUST implement ERC-1271 Standard Signature Validation Method for Contracts
- DeleGator Implementations SHOULD return a non ERC-1271 magic value when encountering an invalid signature

> NOTE: If a DeleGator Implementation implements `reinitialize` it SHOULD gate the method to `onlySelf` to ensure no one can unexpectedly take over the DeleGator.

> NOTE: A DeleGator Implementation MUST use namespaced storage for ALL variables if it is extending MetaMask's DeleGatorCore.
