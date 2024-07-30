# DeleGator Smart Account

A DeleGator Smart Account is a 4337-compatible Smart Account that implements delegation functionality. An end user will operate through a DeleGatorProxy which uses a chosen DeleGator implementation.

## Overview

An end user controls a DeleGator Proxy that USES a DeleGator Implementation which IMPLEMENTS DeleGatorCore and interacts with a DelegationManager.

### Delegations

A Delegation enables the ability to share the capability to invoke some onchain action entirely offchain in a secure manner. [Caveats](#caveats) can be combined to create delegations with restricted functionality that users can extend, share or redeem.

A simple example is "Alice delegates the ability to use her USDC to Bob limiting the amount to 100 USDC".

[Read more on "Delegations" ->](/documents/DelegationManager.md#Delegations)

### DeleGator

A DeleGator is the contract an end user controls and uses to interact with other contracts onchain. A DeleGator is an [EIP-1967](https://eips.ethereum.org/EIPS/eip-1967[EIP1967]) proxy contract that uses a DeleGator Implementation which defines the granular details of how the DeleGator works. Users are free to migrate their DeleGator Implementation as their needs change.

### DeleGator Core

The DeleGator Core includes the Delegation execution and ERC-4337 functionality to make the Smart Account work.

[Read more on "DeleGator Core" ->](/documents/DeleGatorCore.md)

### DeleGator Implementation

A DeleGator Implementation contains the logic for a DeleGator Smart Account. Each DeleGator Implementation must include the required methods for a DeleGator Smart Account, namely the signature scheme to be used for verifying access to control the contract. A few examples are the MultiSigDeleGator and the HybridDeleGator.

[Read more on "MultiSig DeleGator" ->](/documents/MultisigDeleGator.md)

[Read more on "Hybrid DeleGator" ->](/documents/HybridDeleGator.md)

### Delegation Manager

The Delegation Manager includes the logic for validating and executing Delegations.

[Read more on "Delegation Manager" ->](/documents/DelegationManager.md)

### Caveat Enforcers

Caveats are used to add restrictions and rules for Delegations. By default, a Delegation allows the delegate to make **any** onchain action so caveats are strongly recommended. They are managed by Caveat Enforcer contracts.

Developers can build new Caveat Enforcers for their own use cases, and the possibilities are endless. Developers can optimize their Delegations by making extremely specific and granular caveats for their individual use cases.

[Read more on "Caveats" ->](/documents/DelegationManager.md#Caveats)

## Development

### Third Party Developers

There's several touchpoints where developers may be using or extending a DeleGator Smart Account.

- Developers can build custom DeleGator Implementations that use the [DeleGator Core](/src/DeleGatorCore.sol) to create new ways for end users to control and manage their Smart Accounts.
- Developers can write any contract that meets the [DeleGator Core Interface](/src/interfaces/IDeleGatorCore.sol) to create novel ways of delegating functionality.
- Developers can create custom Caveat Enforcers to refine the capabilities of a delegation for any use case they imagine.
- Developers can craft Delegations to then share onchain capabilities entirely offchain.

### Foundry

This repo uses [Foundry](https://book.getfoundry.sh/).

#### Build

```shell
forge build
```

#### Test

```shell
forge test
```

#### Deploying

0. Copy `.env.example` to `.env` and populate the variables you plan to use if you plan to deploy any contracts.

```shell
source .env
```

1. Use [Anvil](https://book.getfoundry.sh/reference/anvil/) to run a local fork of a blockchain to develop in an isolated environment.

```shell
anvil -f <your_rpc_url>
```

2. Deploy the necessary environment contracts.

> NOTE: As this system matures, this step will no longer be required for public chains where the DeleGator is in use.

```shell
forge script script/DeployEnvironmentSetUp.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
```

### Javascript

Read more [here](https://www.notion.so/DeleGator-Developer-Guide-aaa11e5462e8422a85bc8ad70b8d14dc?pvs=4).

### Notes
[tool.poetry]
name = "my-package"
version = "0.1.0"
description = "The description of the package"

license = "MIT"

authors = [
    "Sébastien Eustace <sebastien@eustace.io>"
]

repository = "https://github.com/python-poetry/poetry"
homepage = "https://python-poetry.org"

# README file(s) are used as the package description
readme = ["README.md", "LICENSE"]

# Keywords (translated to tags on the package index)
keywords = ["packaging", "poetry"]

[tool.poetry.dependencies]
# Compatible Python versions
python = ">=3.8"
# Standard dependency with semver constraints
aiohttp = "^3.8.1"
# Dependency with extras
requests = { version = "^2.28", extras = ["security"] }
# Version-specific dependencies with prereleases allowed
tomli = { version = "^2.0.1", python = "<3.11", allow-prereleases = true }
# Git dependencies
cleo = { git = "https://github.com/python-poetry/cleo.git", branch = "main" }
# Optional dependencies (installed by extras)
pendulum = { version = "^2.1.2", optional = true }

# Dependency groups are supported for organizing your dependencies
[tool.poetry.group.dev.dependencies]
pytest = "^7.1.2"
pytest-cov = "^3.0"

# ...and can be installed only when explicitly requested
[tool.poetry.group.docs]
optional = true
[tool.poetry.group.docs.dependencies]
Sphinx = "^5.1.1"

# Python-style entrypoints and scripts are easily expressed
[tool.poetry.scripts]
my-script = "my_package:main"
- We're building against solidity version [0.8.23](https://github.com/ethereum/solidity/releases/tag/v0.8.23) for the time being.
- Format on save using the Forge formatter.

### Style Guide

[Read more on "Style Guide" ->](/documents/StyleGuide.md)

## Relevant Documents

- [EIP-712](https://eips.ethereum.org/EIPS/eip-712)
- [EIP-1014](https://eips.ethereum.org/EIPS/eip-1014)
- [EIP-1271](https://eips.ethereum.org/EIPS/eip-1271)
- [EIP-1822](https://eips.ethereum.org/EIPS/eip-1822)
- [EIP-1967](https://eips.ethereum.org/EIPS/eip-1967)
- [EIP-4337](https://eips.ethereum.org/EIPS/eip-4337)
- [EIP-7201](https://eips.ethereum.org/EIPS/eip-7201)
- [EIP-7212](https://eips.ethereum.org/EIPS/eip-7212)
