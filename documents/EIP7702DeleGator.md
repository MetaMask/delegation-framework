# EIP-7702 Smart Contracts

## Overview

This document provides an overview of the implemented EIP-7702-compatible contracts. These contracts use a different upgrade mechanism than the previous UUPS proxy-based architecture (as implemented in DeleGatorCore) and instead follow the EIP-7702 standard.

Under EIP-7702, an Externally Owned Account (EOA) can submit an authorization to map the contract code of an existing contract to that EOA. Unlike UUPS proxy-based contracts, this approach neither supports contract initialization nor relies on UUPS-related code.

## Contracts

### 1. EIP7702DeleGatorCore.sol

**EIP7702DeleGatorCore** serves as the foundational contract for EIP-7702-compatible delegator functionality with ERC-7710. It acts as the primary interface for interactions under EIP-7702 and implements the EIP-7821 interface, which provides a method to execute calls in different modes (e.g., single or batch). These methods can be invoked either through the privileged ERC-4337 EntryPoint or directly via the EOA address.

Future implementations may introduce additional features, such as signature validation, as outlined in EIP-7821.

This contract also integrates OpenZeppelin’s EIP712 functionality. The name and version used in the EIP712 constructor are limited to a maximum of 31 bytes. Exceeding this limit causes those variables to be stored in the contract state without namespace storage, leading to conflicts. Restricting the name and version size helps ensure that **EIP7702DeleGatorCore** remains stateless by avoiding additional storage.

### 2. EIP7702StatelessDeleGator.sol

**EIP7702StatelessDeleGator** does not maintain signer data within the contract state. Instead, control is granted to the EOA that shares the same address, in accordance with EIP-7702. The contract can be invoked either through the privileged ERC-4337 EntryPoint or directly via the EOA address. The signature is verified via the `isValidSignature()` function.

This stateless design offers a lightweight and secure approach to delegator functionality under the EIP-7702 standard.
