# Token Transfer Delegation Flow

This diagram illustrates how an off-chain delegation is created and subsequently redeemed, allowing a Delegate to transfer an ERC20 token on behalf of a Delegator.

```mermaid
sequenceDiagram
    participant Delegator
    participant Delegate
    participant DelegationManager
    participant CaveatEnforcer
    participant ERC20TokenContract

    Delegator->>Delegator: Create off-chain delegation with caveat enforcers to restrict an ERC20 transfer
    Delegator->>Delegator: Sign off-chain delegation
    Delegator->>Delegate: Send signed off-chain delegation
    Note right of Delegate: Hold delegation until redemption

    Delegate->>DelegationManager: redeemDelegations() with delegation & execution (ERC20 transfer)
    DelegationManager->>Delegator: isValidSignature()
    Delegator-->>DelegationManager: Confirm valid (or not)

    DelegationManager->>CaveatEnforcer: beforeAllHook()
    Note right of DelegationManager: Expect no error
    DelegationManager->>CaveatEnforcer: beforeHook()
    Note right of DelegationManager: Expect no error

    DelegationManager->>Delegator: executeFromExecutor() with execution (ERC20 transfer)
    Delegator->>ERC20TokenContract: Perform ERC20 transfer
    Note right of DelegationManager: Expect no error

    DelegationManager->>CaveatEnforcer: afterHook()
    Note right of DelegationManager: Expect no error
    DelegationManager->>CaveatEnforcer: afterAllHook()
    Note right of DelegationManager: Expect no error
```
