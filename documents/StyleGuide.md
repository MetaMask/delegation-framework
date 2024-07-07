# Solidity Contracts Style Guide

Welcome to our Solidity Contracts Style Guide! 🚀

#### Consistency is Key

Maintaining a consistent naming convention throughout the contract enhances readability and makes the codebase more approachable for collaborators.

## Contract Layout

- structs
- state variables (constants and immutable first)
- events
- custom errors
- modifiers
- constructor / initializers / reinitialize
- external
- external view
- external pure
- public
- public view
- public pure
- internal
- internal view
- internal pure
- private
- private view
- private pure

## Imports

The imports should be sorted by external dependencies an empty line and then local dependencies.

```solidity
// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.21;

import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IDeleGatorCore } from "./interfaces/IDeleGatorCore.sol";
import { Action, SignedDelegation, Delegation } from "./utils/Types.sol";
```

## Naming Conventions

### Contracts and Interfaces

The name of the file should match the name of the contract or interface.

```
src/DeleGatorCore.sol
abstract contract DeleGatorCore is IDeleGatorCore, ERC4337Core {}

src/interfaces/ICaveatEnforcer.sol
interface ICaveatEnforcer {}
```

### Constant Variables

Constants should be named with all capital letters with underscores separating words.
For constants that external sources may want access to, opt for `public` access modifier for consistent compiler generated getters.

```solidity
uint256 public constant MAX_SUPPLY1 = 1000;
uint256 internal constant MAX_SUPPLY2 = 1000;
uint256 private constant MAX_SUPPLY3 = 1000;
```

### State Variables

State variables should be named in mixedCase with no underscore.

```solidity
bytes32 public domainHash;
DelegationManager internal delegationManager;
mapping(bytes32 delegationHash => Delegation delegation) delegations;
```

### Immutable Variables

Immutable variables follow the same style as state variables.

### Modifiers

Modifiers should use mixedCase.

```solidity
modifier onlyDelegationManager() {}
```

### Events

Event names should use CapWords style.

```solidity
event EnabledDelegation(bytes32 indexed delegationHash, address indexed delegator, address indexed delegate);

```

### Custom Errors

Custom error names should use CapWords style.

```solidity
error InvalidSignature();
```

### Event parameters

Event parameters should be named in mixedCase with no underscore.

```solidity
event EnabledDelegation(address indexed delegator, bytes32 indexed delegationHash);
```

### Enums

Enums should use CapWords style.

```solidity
enum Implementation {
    Ownable,
    MultiSig,
    P256
}
```

### Function Parameters

Function parameters should use an underscore prefix to enhance clarity and distinguish them from other variables. For example:

```solidity
function updateBalance(address _user, uint256 _amount) internal {
    // function logic here
}
```

### Function Scope Variables

Internal variables within functions should use an underscore suffix. For example:

```solidity
function _calculateInterest(uint256 _principal, uint256 _rate) internal returns (uint256 interest_) {
    // calculation logic here
    uint256 magicNumber_ = 9999;
    interest_ = _principal * magicNumber_ * _rate / 100;
}
```

### Internal and Private Functions

Function names for internal and private functions should start with an underscore.

```solidity
function externalFunction() external {}

function publicFunction() public {}

function _internalFunction() internal {}

function _privateFunction() private {}
```
