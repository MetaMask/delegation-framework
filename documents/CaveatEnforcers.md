# Caveats Enforcers

`CaveatEnforcer` contracts enable a delegator to place granular restrictions on the delegations, So dApps can create highly specific delegations that permit actions only under certain conditions. Caveats serve as a mechanism to verify the state both before and after execution, but not the final state post-redemption. However, caveats can still influence the final state of the transaction.

> **Note**: Each `CaveatEnforcer` is always called by the `DelegationManager`. This means `msg.sender` inside the enforcer will be the `DelegationManager`'s address. Keep this in mind if you plan to store data within the enforcer.

> **Important**: There is no guarantee that the action allowed by the enforcer will be executed. If your enforcer logic depends on the action actually happening, be sure to use `afterHook` and `afterAllHook` to confirm any expected state changes.

## Hook Sequence

The order in which the caveat hooks are called can vary depending on the `DelegationManager` implementation, but generally:

1. `beforeAllHook`: Called for all delegations before any executions begin, proceeding from the leaf delegation to the root delegation.
2. `beforeHook`: Called before each individual execution tied to a delegation, also proceeding from the leaf delegation to the root delegation.
3. Execution: The specified execution is performed.
4. `afterHook`: Called after each individual execution tied to a delegation, proceeding from the root delegation back to the leaf delegation.
5. `afterAllHook`: Called for all delegations after all executions have been processed, proceeding from the root delegation back to the leaf delegation.

- These hooks are optional. If a hook has no logic, the enforcer performs no checks at that stage.
- Each hook has access to the same delegation-related data in the function parameters (delegator, delegation hash, args, redeemer, terms, execution call data, and execution mode).

### Execution Modes

Enforcers can target specific call type modes: **single** or **batch**, and execution types: **default** or **revert**. Because execution call data is encoded differently for each mode, you can use modifiers like `onlySingleCallTypeMode`, `onlyBatchCallTypeMode` to restrict a call type, or `onlyDefaultExecutionMode`, `onlyTryExecutionMode` to restrict an execution type, it is possible to combine an execution mode modifier with a call type modifier.

---

## Enforcer Details

### NativeTokenPaymentEnforcer

The `NativeTokenPaymentEnforcer` is a mechanism used within a delegation (D1) that requires a payment in order to allow the execution of an action. In this enforcer, the redeemer provides a secondary delegation (D2) that grants an allowance, which the enforcer redeems to process the payment.

This redemption may alter the state of other contracts. For example, the balance of the delegator providing the allowance will decrease, while the balance of the recipient specified by the payment delegation will increase. These state changes can impact other enforcers that rely on balance validations, depending on their order in the caveats array.

Consider a scenario where D1 includes an array of caveats: one caveat is the `NativeBalanceGteEnforcer`, which verifies that Bob’s balance has increased as a result of the execution attached to D1. The second caveat is the `NativeTokenPaymentEnforcer`, which deducts from Bob’s balance by redeeming D2. If these enforcers are not correctly ordered, they could conflict. For instance, if the `NativeTokenPaymentEnforcer` is executed before the `NativeBalanceGteEnforcer`, Bob’s balance would be reduced first, potentially causing the `NativeBalanceGteEnforcer` to fail its validation of ensuring Bob’s balance exceeds a certain threshold.

Because the `NativeTokenPaymentEnforcer` modifies the state of external contracts, it is essential to carefully order enforcers in the delegation to prevent conflicts. The enforcers are designed to protect the execution process, but they do not guarantee a final state after the redemption. This means that even if the `NativeBalanceGteEnforcer` validates Bob’s balance at one point, subsequent enforcers, such as the `NativeTokenPaymentEnforcer`, may modify it later.
