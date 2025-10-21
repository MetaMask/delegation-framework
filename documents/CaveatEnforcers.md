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
- Use **Multi Operation Balance Enforcers** when multiple enforcers might track the same recipient in a delegation chain

### Multi Operation Increase Balance Enforcers

This includes:

- `ERC20MultiOperationIncreaseBalanceEnforcer`
- `ERC721MultiOperationIncreaseBalanceEnforcer`
- `ERC1155MultiOperationIncreaseBalanceEnforcer`
- `NativeTokenMultiOperationIncreaseBalanceEnforcer`

Use these when multiple **increase** balance constraints may apply to the same recipient and token within a single redemption, and you need a single, coherent end-of-redemption.

Stated more simply when you want to enforce an outcome of a batch delegation.

#### When to Use Multi Operation Increase Balance Enforcers

**✅ Use Multi Operation Increase Balance Enforcers when:**

- You have a **complex transaction** that requires multiple steps
- Multiple delegations need to **coordinate** to achieve a shared goal
- You want to **accumulate** balance increase requirements across the entire redemption flow
- You need to verify the **final end state** of the recipient after all steps complete

**❌ Do NOT use Multi Operation Increase Balance Enforcers when:**

- You want **independent, per-delegation constraints** (non-aggregating semantics)
- You need progressive restrictions (e.g., “max 100 ETH” then “max 50 ETH”)
- You want the **strictest constraint** to win (these enforcers aggregate increases rather than picking the minimum)
- You need to enforce **decreases** or **loss limits**

#### Key Differences from Regular Balance Change Enforcers

**Regular Balance Change Enforcers** (e.g., `NativeBalanceChangeEnforcer`) check deltas around one execution using `beforeHook`/`afterHook`. Because multiple enforcers watching the same recipient can be satisfied by the same balance movement, they are best for independent, per-delegation constraints.

**Multi Operation Increase Balance Enforcers** are designed for coordinated multi-step flows and behave as follows:

1. **Redemption-wide tracking**: Balance is tracked from the first `beforeAllHook` to the last `afterAllHook` for a given state key. The state key is defined by the recipient; for token-based variants it also includes the token address, and for ERC1155 it additionally includes the token ID. The state is scoped to the current `DelegationManager`. Any balance changes that happen between these hooks including those from other enforcers (even ones that update state in `afterAllHook`, like `NativeTokenPaymentEnforcer`, though mixing with it is discouraged) are counted in the final validation.

2. **Initialization rule**: The first enforcer that starts tracking can be created by any account in the delegation chain.

3. **Aggregation behavior**: All enforcers in the delegation chain that target the same state key will aggregate their expected amounts, regardless of who the delegator is. The overall value becomes more restrictive (higher total balance requirement) as more enforcers are added to the chain.

4. **State scope and keying**: State is defined by the `DelegationManager` and the recipient; for ERC20/721 it also includes the token address; for ERC1155 it additionally includes the token ID. **Important**: The state key does not include the delegation hash, which means Multi Operation Increase Balance Enforcers can share state across multiple, unrelated execution call datas. Within a single redemption that performs multiple executions, different total enforcers that target the same state key will share and coordinate on the same state. State is cleared when the final `afterAllHook` for that state key runs.

5. **Single final validation**: At the last `afterAllHook`, the net expected increase is computed and validated against the actual end balance.

#### How It Works

1. **Initialization**: The first enforcer in the chain caches the initial balance for the state key.

2. **Accumulation**: All enforcers in the delegation chain that target the same state key accumulate their expected amounts, making the overall requirement more restrictive.

3. **Validation**: After the last `afterAllHook` for the key, the final balance is checked against the total accumulated expected increase and state is cleared.

#### Example Scenario: Coordinated Multi-Operation Transaction

Consider a complex DeFi operation that requires multiple delegations to work together:

**Delegation Chain:**

- **Alice → Bob**: "Can execute complex DeFi operation that should increase treasury by at least 1000 tokens"
- **Bob → Charlie**: "Can execute DeFi step 1 that should increase treasury by at least 200 tokens"
- **Charlie → Dave**: "Can execute DeFi step 2 that should increase treasury by at least 300 tokens"

**Using Multi Operation Increase Balance Enforcers:**

- Enforcer 1: Expects an increase of at least 1000 tokens
- Enforcer 2: Expects an increase of at least 200 tokens
- Enforcer 3: Expects an increase of at least 300 tokens

**Result:**

1. Track the initial treasury balance
2. Accumulate expected increases: +1000 + 200 + 300 = +1500
3. Validate that the final treasury balance has increased by at least 1500 tokens

This ensures that the **combined effect** of all DeFi steps achieves the overall goal of increasing the treasury by the required amount.

Note that in this scenario we have the same end recipient (treasury) and the same token. If the recipient in any of the steps would be different, that would be tracked in a separate state.

#### Delegating to EOA

If you are delegating to an EOA in a delegation chain, the EOA cannot execute directly since it cannot redeem inner delegations. The EOA can become a deleGator by using EIP7702 or it can use an adapter contract to execute the delegation. An example for that is available in `./src/helpers/DelegationMetaSwapAdapter.sol`.

## LogicalOrWrapperEnforcer Context Switching

The `LogicalOrWrapperEnforcer` enables logical OR functionality between groups of enforcers, allowing flexibility in delegation constraints. This enforcer is designed for a narrow set of use cases, and careful attention must be given when constructing caveats. The enforcer introduces an important architectural consideration: **context switching**.

### How Context Switching Works

When the `LogicalOrWrapperEnforcer` calls inner enforcers, it uses external calls (`Address.functionCall`), which changes the caller context:

- **Direct call**: `DelegationManager` → `NonceEnforcer`
  - Inside `NonceEnforcer`: `msg.sender == DelegationManager`
- **Through wrapper**: `DelegationManager` → `LogicalOrWrapperEnforcer` → `NonceEnforcer`
  - Inside `NonceEnforcer`: `msg.sender == LogicalOrWrapperEnforcer`

This context switch creates separate storage namespaces for enforcers that key their state by `msg.sender`.

### Context-Sensitive Enforcers

Some enforcers maintain state using `msg.sender` as a key and require special consideration with `LogicalOrWrapperEnforcer`. In general, nonce or ID caveats should be top-level caveats rather than children of a logical OR caveat.

#### NonceEnforcer

- **Purpose**: Enables delegation revocation by incrementing nonces
- **State keying**: `mapping(address delegationManager => mapping(address delegator => uint256 nonce))`
- **Context dependency**: When wrapped, nonces are tracked under the wrapper's address, creating a separate nonce space
- **Important**: A nonce caveat within a logical OR caveat is distinct from one created at the top level
- **Advanced usage**: If specifically required as a child of logical OR, the `LogicalOrWrapperEnforcer` address must be provided when incrementing the nonce

#### IdEnforcer

- **Purpose**: Ensures delegation IDs can only be used once
- **State keying**: `mapping(address delegationManager => mapping(address delegator => BitMaps.BitMap id))`
- **Context dependency**: When wrapped, used IDs are tracked under the wrapper's address
- **Important**: An ID caveat within a logical OR caveat is distinct from one created at the top level
- **Advanced usage**: If specifically required as a child of logical OR, understand that ID uniqueness applies only within the wrapper's context

### Recommended Usage Patterns

#### ✅ Correct Pattern - Top-level Only

Place context-sensitive enforcers at the top level of your delegation:

```solidity
delegation {
  enforcers: [
    nonceEnforcer,        // ← Top-level placement
    idEnforcer,           // ← Top-level placement
    logicalOrEnforcer: [
      erc20TransferEnforcer,
      nativeTransferEnforcer
    ]
  ]
}
```

#### ❌ Incorrect Pattern - Nested Placement

Avoid placing context-sensitive enforcers inside the wrapper:

```solidity
delegation {
  enforcers: [
    logicalOrEnforcer: [
      nonceEnforcer,      // ← Creates separate state namespace
      erc20TransferEnforcer
    ]
  ]
}
```

### Understanding the Implications

If you have deep knowledge of the delegation framework and specifically need to use context-sensitive enforcers within `LogicalOrWrapperEnforcer`, understand that:

- State will be isolated under the wrapper's address namespace
- This pattern should only be used when the isolation is intentional and well-understood
