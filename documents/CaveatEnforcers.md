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

Consider a scenario where D1 includes an array of caveats: one caveat is the `NativeBalanceChangeEnforcer`, which verifies that Bob’s balance has increased as a result of the execution attached to D1. The second caveat is the `NativeTokenPaymentEnforcer`, which deducts from Bob’s balance by redeeming D2. If these enforcers are not correctly ordered, they could conflict. For instance, if the `NativeTokenPaymentEnforcer` is executed before the `NativeBalanceChangeEnforcer`, Bob’s balance would be reduced first, potentially causing the `NativeBalanceChangeEnforcer` to fail its validation of ensuring Bob’s balance exceeds a certain threshold.

Because the `NativeTokenPaymentEnforcer` modifies the state of external contracts, it is essential to carefully order enforcers in the delegation to prevent conflicts. The enforcers are designed to protect the execution process, but they do not guarantee a final state after the redemption. This means that even if the `NativeBalanceChangeEnforcer` validates Bob’s balance at one point, subsequent enforcers, such as the `NativeTokenPaymentEnforcer`, may modify it later.

### Balance Change Enforcers

This includes:
- `NativeBalanceChangeEnforcer`
- `ERC20BalanceChangeEnforcer`
- `ERC721BalanceChangeEnforcer`
- `ERC1155BalanceChangeEnforcer`

Balance Change Enforcers allow setting up guardrails around balance changes for specific token types. By specifying an amount and a direction (decrease/increase), you can enforce a maximum decrease or minimum increase in the recipient's balance after execution.

#### How They Work

**Regular Balance Change Enforcers** use `beforeHook` and `afterHook` to track balance changes:

1. **State Management**: Each enforcer maintains a `balanceCache` mapping and an `isLocked` mapping to prevent concurrent access to the same delegation.

2. **Hash Key Generation**: The hash key is generated using the delegation manager address and delegation hash (plus token address and token ID for ERC1155), ensuring each delegation has its own isolated state.

3. **Balance Caching**: In `beforeHook`, the enforcer:
   - Checks that the enforcer isn't already locked for this delegation
   - Locks the enforcer to prevent concurrent access
   - Caches the current balance of the recipient

4. **Balance Validation**: In `afterHook`, the enforcer:
   - Unlocks the enforcer
   - Compares the current balance against the cached balance
   - Validates that the balance change meets the specified requirements

#### Use Cases

Balance Change Enforcers are ideal for:

1. **Single Delegation Scenarios**: When you have only one enforcer tracking a specific recipient's balance
2. **Simple Balance Guards**: Basic checks like "ensure balance increases by at least X" or "ensure balance doesn't decrease by more than Y"
3. **Payment Validation**: Verifying that a recipient received the expected payment amount
4. **Loss Prevention**: Preventing excessive token transfers from an account

#### Limitations and Considerations

**⚠️ Important Security Notice**: These enforcers track balance changes by comparing the recipient's balance before and after execution. Since enforcers watching the same recipient share state, a single balance modification may satisfy multiple enforcers simultaneously. This can lead to unintended behavior in delegation chains.

**Key Limitations**:
1. **State Sharing**: Multiple enforcers tracking the same recipient may interfere with each other
2. **No Aggregation**: Each enforcer operates independently and doesn't consider other enforcers in the chain
3. **Delegation Chain Issues**: In complex delegation chains, the same balance change might satisfy multiple enforcers, potentially bypassing intended security measures

**When to Use Regular vs Total Balance Enforcers**:
- Use **Regular Balance Enforcers** for simple, single-enforcer scenarios
- Use **Total Balance Enforcers** when multiple enforcers might track the same recipient in a delegation chain


### Total Balance Change Enforcers

This includes: 
- `ERC20TotalBalanceChangeEnforcer`
- `ERC721TotalBalanceChangeEnforcer`
- `ERC1155TotalBalanceChangeEnforcer`
- `NativeTokenTotalBalanceChangeEnforcer`

Use these when multiple total-balance constraints may apply to the same recipient and token within a single redemption, and you need a single, coherent end-of-redemption check.

#### Key differences from Regular Balance Change Enforcers

**Regular Balance Change Enforcers** (e.g., `NativeBalanceChangeEnforcer`) check deltas around one execution using `beforeHook`/`afterHook`. Because multiple enforcers watching the same recipient can be satisfied by the same balance movement, they are best for independent, per-delegation constraints.

**Total Balance Change Enforcers** are designed for coordinated multi-step flows and now behave as follows:

1. **Redemption-wide tracking**: Balance is tracked from the first `beforeAllHook` to the last `afterAllHook` for a given state key. The state key is defined by the recipient; for token-based variants it also includes the token address, and for ERC1155 it additionally includes the token ID. The state is scoped to the current `DelegationManager`. Any balance changes caused between those points (including by other enforcers, even those that modify state in `afterAllHook`, such as `NativeTokenPaymentEnforcer` even tho mixing with `NativeTokenPaymentEnforcer` is not recomended) are included in the final check.
2. **Initialization rule**: The first enforcer that starts tracking must be created by the account whose balance is being constrained. In other words, for the first `beforeAllHook` on a state key, the delegator must equal the recipient. If this is not true, the enforcer reverts.
3. **Aggregation vs redelegation**:
   - **Aggregation only when the delegator must equal the recipient**: Multiple total enforcers created by the owner for the same state key will aggregate their expected amounts.
   - **Redelegations must be strictly more restrictive**: When the delegator does not equal the recipient, the new terms must tighten the requirement and they replace (do not add to) the aggregated value:
     - For decreases (max loss), the new amount must be less than or equal to the existing amount.
     - For increases (min gain), the new amount must be greater than or equal to the existing amount.
   - This ensures the final required end balance is never lower than before; redelegations can only make the constraint stricter.
4. **State scope and keying**: State is defined by the `DelegationManager` and the recipient; for ERC20/721 it also includes the token address; for ERC1155 it additionally includes the token ID. The state key does not include the delegation hash. Within a single redemption that performs multiple executions, different total enforcers that target the same state key will share and coordinate on the same state. State is cleared when the final `afterAllHook` for that state key runs.
5. **Single final validation**: At the last `afterAllHook`, the net expected change is computed and validated against the actual end balance.

#### How it works (concise)

1. First owner-created total enforcer (the delegator must equal the recipient) caches the initial balance for the state key.
2. Owner-created total enforcers accumulate expected amounts. Redelegations override with stricter terms only.
3. After the last `afterAllHook` for the key, the final balance is checked against the net expected change and state is cleared.

#### Choosing between Regular vs Total balance enforcers

- **Independent security constraints (per-delegation limits)**: Use Regular Balance Change Enforcers. Example: progressively stricter risk caps.
  - Alice → Bob: “Treasury can lose max 100 ETH”
  - Bob → Dave: “Treasury can lose max 50 ETH” (stricter)
  - With Regular enforcers, each delegation enforces its own limit, so the effective cap is 50 ETH.
- **Coordinated multi-operation transactions (one complex flow with multiple steps)**: Use Total Balance Change Enforcers. Example: a swap + fee + settlement that together must result in a minimum net profit for a recipient, or must not exceed a net loss cap across the whole flow. The owner may aggregate multiple requirements; redelegations can only make them stricter.

Why accumulation is appropriate in coordinated flows: the intention is to verify the final end state of the recipient after all steps complete, not to enforce separate independent limits. In contrast, for independent limits, prefer Regular enforcers so each delegation remains self-contained.

#### Example: coordinated accumulation

Owner sets three total constraints on the same key during one redemption:
- Min increase: 1000 tokens
- Min increase: 200 tokens
- Max decrease: 300 tokens

Net requirement: +1000 + 200 − 300 = +900. The final recipient balance must be at least initial + 900.

If a redelegation introduces a new term on the same key, it must be more restrictive and will override the accumulated value rather than add to it (e.g., a new max decrease of 250 replaces 300; a new min increase of 1200 replaces 1000).

#### Batch execution and shared state

- Multiple executions within the same redemption that reference the same state key share one `BalanceTracker` and coordinate via `validationRemaining`.
- Because the state key does not include the delegation hash, separate delegations in the same redemption that target the same state key will share state. Group related steps together; avoid mixing unrelated flows that target the same state key in one redemption if that could cause confusion.

#### Delegating to EOAs

If you delegate to an EOA in a delegation chain, the EOA cannot redeem inner delegations directly. The EOA can:
- Become a deleGator via EIP-7702, or
- Use an adapter contract to execute the delegation (see `src/helpers/DelegationMetaSwapAdapter.sol`).