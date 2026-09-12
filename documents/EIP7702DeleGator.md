# EIP-7702 Smart Contracts

## Overview

These contracts let an EOA delegate its code to a DeleGator implementation under EIP-7702. EIP-7702 changes code through an EOA authorization and has no initializer.

## Production Stateless account

`EIP7702DeleGatorCore` and `EIP7702StatelessDeleGator` provide the single-`DelegationManager` account. They support ERC-4337 and require ERC-1271 and UserOperation signatures to recover to the EOA whose address hosts the delegated code.

## EIP7702MultiManagerDeleGator

`EIP7702MultiManagerDeleGator` is a non-ERC-4337 account with two immutable default `DelegationManager` contracts and optional additional approved `DelegationManager` contracts.

See the [implementation](../src/EIP7702/EIP7702MultiManagerDeleGator.sol) and [core](../src/EIP7702/EIP7702MultiManagerDeleGatorCore.sol) source for API and implementation behavior.

### Security considerations

> **Warning:** Every default or approved `DelegationManager` is a root authority over the account. It can execute arbitrary calls, self-call the account, and modify mutable manager approvals.

- Unknown, unofficial, unaudited, compromised, or upgradeable `DelegationManager` contracts can compromise the account. Users and integrators must carefully verify and trust each one before configuring or approving it.
- The two default `DelegationManager` contracts cannot be revoked for this implementation.
- Under EIP-7702, changing the delegated implementation does not clear the EOA's storage. Mutable approvals use the ERC-7201 namespace `DeleGator.EIP7702MultiManager.v1`; a replacement implementation should use a different namespace unless it intentionally adopts the same approvals. There is no on-chain enumeration or revoke-all operation.
