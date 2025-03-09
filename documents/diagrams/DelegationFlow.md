# Delegation redemption flow

This diagram illustrates how an off-chain delegation is created and subsequently redeemed on the Delegation Manager. The Delegation Manager is in charge of validating the signature of the delegation, validating the caveat enforcers, and if everything is correct it allows a Delegate to execute an action on behalf of the Delegator.

```mermaid
sequenceDiagram
    participant Delegator
    participant Delegate
    participant DelegationManager
    participant CaveatEnforcer

    Delegator->>Delegator: Create off-chain delegation with caveat enforcers
    Delegator->>Delegator: Sign off-chain delegation
    Delegator->>Delegate: Send signed off-chain delegation
    Note right of Delegate: Hold delegation until redemption

    Delegate->>DelegationManager: redeemDelegations() with delegation & execution details
    DelegationManager->>Delegator: isValidSignature()
    Delegator-->>DelegationManager: Confirm valid (or not)

    DelegationManager->>CaveatEnforcer: beforeAllHook()
    Note right of DelegationManager: Expect no error
    DelegationManager->>CaveatEnforcer: beforeHook()
    Note right of DelegationManager: Expect no error

    DelegationManager->>Delegator: executeFromExecutor() with execution details
    Delegator->>Delegator: Perform execution
    Note right of DelegationManager: Expect no error

    DelegationManager->>CaveatEnforcer: afterHook()
    Note right of DelegationManager: Expect no error
    DelegationManager->>CaveatEnforcer: afterAllHook()
    Note right of DelegationManager: Expect no error
```
