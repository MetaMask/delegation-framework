## Caveats Enforcers

`CaveatEnforcer` contracts enable a delegator to place granular restrictions on the delegations, So dApps can create highly specific delegations that permit actions only under certain conditions. Caveats serve as a mechanism to verify the state both before and after execution, but not the final state post-redemption. However, caveats can still influence the final state of the transaction.

> NOTE: Each `CaveatEnforcer` is called by the `DelegationManager` contract. This is important when storing data in the `CaveatEnforcer`, as `msg.sender` will always be the address of the `DelegationManager`.

> NOTE: There is no guarantee that the action will be executed. Keep this in mind when designing Caveat Enforcers. If your logic depends on the action being performed, ensure you use the afterHook and afterAllHook methods to validate any expected state changes.

The execution order of the caveat hooks may vary depending on the delegation manager implementation, but they are designed to be used in the following sequence:

1. `beforeAllHook`: Called for all delegations before any executions begin, proceeding from the leaf delegation to the root delegation.
2. `beforeHook`: Called before each individual execution tied to a delegation, also proceeding from the leaf delegation to the root delegation.
3. Execution: The specified execution is performed.
4. `afterHook`: Called after each individual execution tied to a delegation, proceeding from the root delegation back to the leaf delegation.
5. `afterAllHook`: Called for all delegations after all executions have been processed, proceeding from the root delegation back to the leaf delegation.

## Enforcer Details

### NativeTokenPaymentEnforcer

The `NativeTokenPaymentEnforcer` is a mechanism used within a delegation (D1) that requires a payment in order to allow the execution of an action. In this enforcer, the redeemer provides a secondary delegation (D2) that grants an allowance, which the enforcer redeems to process the payment.

This redemption may alter the state of other contracts. For example, the balance of the delegator providing the allowance will decrease, while the balance of the recipient specified by the payment delegation will increase. These state changes can impact other enforcers that rely on balance validations, depending on their order in the caveats array.

Consider a scenario where D1 includes an array of caveats: one caveat is the `NativeBalanceGteEnforcer`, which verifies that Bob’s balance has increased as a result of the execution attached to D1. The second caveat is the `NativeTokenPaymentEnforcer`, which deducts from Bob’s balance by redeeming D2. If these enforcers are not correctly ordered, they could conflict. For instance, if the `NativeTokenPaymentEnforcer` is executed before the `NativeBalanceGteEnforcer`, Bob’s balance would be reduced first, potentially causing the `NativeBalanceGteEnforcer` to fail its validation of ensuring Bob’s balance exceeds a certain threshold.

Because the `NativeTokenPaymentEnforcer` modifies the state of external contracts, it is essential to carefully order enforcers in the delegation to prevent conflicts. The enforcers are designed to protect the execution process, but they do not guarantee a final state after the redemption. This means that even if the `NativeBalanceGteEnforcer` validates Bob’s balance at one point, subsequent enforcers, such as the `NativeTokenPaymentEnforcer`, may modify it later.

### ERC20SubscriptionEnforcer

A delegate (i.e., redeemer) can use the `ERC20SubscriptionEnforcer` to transfer ERC20 tokens from the delegator's account once every `x` day.

Given an initial timestamp from the redeemer, the `next allowed timestamp` is calculated dynamically, checking this value against the current `block.timestamp` to ensure the redemption fits within the next cycle before execution. `ERC20SubscriptionEnforcer` will enforce the following constraints:

1. The redeemer can only redeem the subscription token amount once per cycle, preventing duplicate claims in the same cycle
2. The redeemer can claim missed a cycle. They skip a claim period at a later date.

### References

Here are a few implementations of subscriptions in the wild that we have taken some inspiration from:

- [OG delegatable framework DistrictERC20PermitSubscriptionsEnforcer](https://github.com/district-labs/delegatable-enforcers/blob/main/contracts/DistrictERC20PermitSubscriptionsEnforcer.sol)
- [Coinbase SpendPermissionManager](https://github.com/coinbase/spend-permissions/blob/main/src/SpendPermissionManager.sol)

### Caveat input:

#### Start Timestamp

An initial timestamp is passed into the caveat args to determine the subscription's start date.

---

#### Formulas:

Below is a set of formulas used in the `ERC20SubscriptionEnforcer` to enforce on-chain subscriptions.

#### Elapsed time

Determines in **seconds** how much time has passed since the subscription start date.

```math
\text{elapsedTime} = \text{block.timestamp} - \text{startTimestamp}
```

---

#### Periods passed(cycles)

We will use integer division to dynamically determine how many full `x-day` periods have passed since the `elapsed time` while ignoring any remainder(i.e., accumulated extra days/hours toward the current cycle in progress). We `elapsedTime` evaluates to `0`. No full cycle has passed, and the first cycle is in progress.

```math
\text{periodsPassed} = \frac{\text{elapsedTime}}{30 \text{ days}}
```

For example:

- If an of `elapsedTime = 75 days`, then:
  \[
  \frac{75}{30} = 2
  \]
  (meaning **2 full cycles** have passed and the **third cycle** is in progress. Once the 90-day mark is reached, the redeemer can claim tokens for the third cycle).

For example:

- If an of `elapsedTime = 10 days`, then:
  \[
  \frac{10}{30} = 0
  \]
  (meaning **first full cycles** is in progress).

---

#### Next valid timestamp

We can use a simple calculation with values derived from the previous formula to determine the next timestamp the redeemer is eligible to claim the subscription token amount.

Since `periodsPassed` will give us the last completed cycle, we need to `+1` to know where to start the next cycle (i.e., cycle actively in progress).

```math
\text{nextValidTimestamp} = \text{startTimestamp} + (\text{periodsPassed} + 1) \times 30 \text{ days}
```

---

##### Example Calculation

Given the following input for the `ERC20SubscriptionEnforcer`:

- `cycle = 30 days`
- `startTimestamp = 1,000,000` (Unix time)(Mon Jan 12 1970 13:46:40)
- `block.timestamp = 1,090,000` (current time)(Tue Jan 13 1970 14:46:40)

1. Compute `elapsedTime`
   \[
   \text{elapsedTime} = 1,090,000 - 1,000,000 = 90,000 \text{ seconds}
   \]

2. Compute `periodsPassed`
   \[
   \text{periodsPassed} = \frac{90,000}{30 \times 24 \times 60 \times 60} = \frac{90,000}{2,592,000} = 0
   \]

(No full periods have passed, since `90,000` seconds is **less than 30 days**. The first cycle is still in progress.)

1. Compute `nextValidTimestamp`
   \[
   \text{nextValidTimestamp} = 1,000,000 + (0 + 1) \times 2,592,000
   \]

\[
= 1,000,000 + 2,592,000 = 3,592,000
\]

(This means the redeemer can submit a transaction with a timestamp **3,592,000** or later to claim the token amount for the first 30-day cycle.)
