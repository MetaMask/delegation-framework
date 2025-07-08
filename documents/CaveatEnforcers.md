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

These enforcers are introduced in parallel to the normal `Balance Change enforcers` for scenarios where we have a delegation chain where multiple instances of the same enforcer can be present. 

#### Key Differences from Regular Balance Change Enforcers

**Regular Balance Change Enforcers** (e.g., `NativeBalanceChangeEnforcer`) track balance changes by comparing the recipient's balance before and after execution using `beforeHook` and `afterHook`. Since enforcers watching the same recipient and token share state, a single balance modification may satisfy multiple enforcers simultaneously, which can lead to unintended behavior in delegation chains.

**Total Balance Change Enforcers** address this issue by:

1. **Using `beforeAllHook` and `afterAllHook`**: These hooks enable proper handling of inner delegations and ensure all enforcers in the chain are processed together.

2. **Accumulating Expected Changes**: Each enforcer maintains a `BalanceTracker` struct that accumulates the expected increases and decreases for a specific recipient + token combination across all enforcers in the delegation chain.

3. **State Isolation**: The hash key is generated using the delegation manager address and recipient (plus token address and token ID for ERC1155), ensuring that different delegation managers don't interfere with each other.

4. **Aggregated Validation**: The final validation in `afterAllHook` combines all expected changes and validates the total net change against the actual balance change.

#### How It Works

1. **Initialization**: When the first enforcer in a chain calls `beforeAllHook`, it records the initial balance and starts tracking expected changes.

2. **Accumulation**: Subsequent enforcers in the chain add their expected increases or decreases to the running totals.

3. **Validation**: In `afterAllHook`, the enforcer calculates the net expected change (total increases minus total decreases) and validates that the actual balance change meets this requirement.

4. **Cleanup**: The balance tracker is deleted after validation to prevent state pollution.

#### Example Scenario

Consider a delegation chain with 3 instances of `ERC20TotalBalanceChangeEnforcer`:
- Enforcer 1: Expects an increase of at least 1000 tokens
- Enforcer 2: Expects an increase of at least 200 tokens  
- Enforcer 3: Expects a decrease of at most 300 tokens

The total balance enforcer will:
1. Track the initial balance
2. Accumulate expected changes: +1000 + 200 - 300 = +900
3. Validate that the final balance has increased by at least 900 tokens

This ensures that the combined effect of all enforcers is properly validated, preventing scenarios where individual enforcers might be satisfied by the same balance change.  

#### Delegating to EOA

If you are delegating to an EOA a delegation chain the EOA cannot execute directly since it cannot redeem inner delegations. EOA can become a deleGator by using EIP7702 or it can use an adapter contract to execute the delegation. An example for that is available in `./src/helpers/DelegationMetaSwapAdapter.sol`.