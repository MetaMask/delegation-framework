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

### LiFiSwapEnforcer

The `LiFiSwapEnforcer` enables unattended DCA-style swap and bridge delegations through the [LI.FI](https://li.fi) Diamond. A user signs **delegation terms once** (input token, output asset, recipient, destination chain, periodic budget, slippage cap, trusted quote signer, diamond address). At redemption time, a backend quote signer provides a **per-execution signed quote** that binds the exact diamond calldata, amounts, and expiration.

**Prerequisite:** ERC-20 approval to the LiFi Diamond is **not** handled by this enforcer. Set up a separate onboarding delegation (e.g. `AllowedTargetsEnforcer` + `AllowedMethodsEnforcer` on `approve`) before swaps can execute.

#### Terms layout (284 bytes, signed at delegation time)

| Offset | Field | Size | Notes |
| --- | --- | --- | --- |
| 0 | `lifiDiamond` | 20 | LiFi Diamond on the source chain |
| 20 | `inputToken` | 20 | Source-chain ERC-20 (e.g. USDC) |
| 40 | `outputAssetId` | 32 | Desired output asset; LiFi/API encoding |
| 72 | `outputRecipient` | 32 | EVM or non-EVM recipient |
| 104 | `destinationChainId` | 32 | EVM `chainId` or LiFi non-EVM id |
| 136 | `quoteSigner` | 20 | Trusted backend that signs quotes |
| 156 | `periodAmount` | 32 | Max input token units per period |
| 188 | `periodDuration` | 32 | Period length in seconds |
| 220 | `startDate` | 32 | Schedule start timestamp |
| 252 | `slippageBps` | 32 | Max slippage; 50 = 0.5% |

Pack with `LiFiSwapQuoteLib.encodeTerms()` or `abi.encodePacked(...)` in the same field order.

#### Args layout (redemption time)

```solidity
args = abi.encode(SignedLiFiQuote quote, bytes signature)
```

The `SignedLiFiQuote` struct and signing helpers live in `./src/libraries/LiFiSwapQuoteLib.sol`. Caveat **args are not part of the delegation signature hash** — only `terms` and `enforcer` are hashed when the user signs the delegation. The quote signer therefore controls per-execution calldata and amounts at redemption time, within the bounds of the signed terms.

#### Recipient and asset encoding (`bytes32`)

The enforcer checks **equality** with terms; it does not validate address format. Integrators must use consistent encoding between delegation signing and quote signing.

| Destination | Example `outputRecipient` encoding |
| --- | --- |
| EVM address | `bytes32(uint256(uint160(evmAddress)))` |
| Solana | LiFi API `bytes32` representation of base58 pubkey |
| Bitcoin | LiFi API `bytes32` representation of BTC address |

For same-chain DCA with an ERC-20 output and on-chain balance verification, use `outputAssetId = bytes32(uint256(uint160(tokenAddress)))`.

Non-EVM chain ids (e.g. Bitcoin) come from the LiFi API — copy from LiFi tooling rather than hardcoding in the enforcer.

#### Signed quote workflow

1. User signs delegation terms (period budget, assets, recipient, destination chain, slippage, quote signer).
2. Redeemer requests a route from the quote signer backend (e.g. USDC → BTC on Bitcoin).
3. Backend builds full LiFi diamond calldata, constructs `SignedLiFiQuote`, and signs it (EIP-191 over `keccak256(abi.encode(quote, quote.expiration))`).
4. Redeemer calls `redeemDelegations` with `args = abi.encode(quote, signature)` and execution targeting `terms.lifiDiamond` with `value == 0`.

#### `beforeHook` checks

1. Execution decodes to `(target, value, callData)` — **single-call, default mode only**.
2. `target == terms.lifiDiamond`, `value == 0`, `callData.length >= 4`.
3. Quote signature from `terms.quoteSigner`; quote not expired.
4. `keccak256(callData) == quote.calldataHash` — **calldata-hash-first** design; no facet-specific ABI decoding in v1.
5. Quote fields match terms and `_delegator`.
6. Slippage: `minAmountOut >= expectedAmountOut * (10000 - slippageBps) / 10000`.
7. Period budget: consume `quote.inputAmount` from `(delegationManager, delegationHash)` allowance (same pattern as `ERC20PeriodTransferEnforcer`).

Any LiFi diamond calldata is allowed if the signed quote's `calldataHash` matches. Native-fee bridges requiring `msg.value > 0` are out of scope for v1.

#### Same-chain vs cross-chain `afterHook`

| Scenario | `afterHook` behavior |
| --- | --- |
| Same-chain (`destinationChainId == block.chainid`) and clean EVM `outputRecipient` / `outputAssetId` (high 96 bits zero) | Cache output token balance at recipient in `beforeHook`; verify increase ≥ `quote.minAmountOut` after execution |
| Cross-chain or non-EVM recipient | **Skip balance check.** Enforcement ends at successful source-chain execution (bridge initiated). Destination delivery cannot be proven on the source chain. |

#### DCA examples

**Same-chain USDC → WBTC (EVM wallet):**

```solidity
terms: abi.encodePacked(
    lifiDiamond, USDC,
    bytes32(uint256(uint160(WBTC))),
    bytes32(uint256(uint160(userEvmWallet))),
    uint256(block.chainid),
    quoteSigner,
    uint256(10e6), uint256(1 days), startDate, uint256(50)
)
```

**Cross-chain USDC on Ethereum → BTC on Bitcoin:**

```solidity
terms: abi.encodePacked(
    lifiDiamond, USDC,
    btcOutputAssetId,        // bytes32 from LiFi API
    btcRecipientBytes32,     // bytes32 from LiFi API
    uint256(20000000000001), // LiFi BTC chain id
    quoteSigner,
    uint256(10e6), uint256(1 days), startDate, uint256(50)
)
```

#### Trust model

- **User (terms):** input token, output asset id, output recipient, destination chain, period budget, slippage cap, quote signer, diamond address.
- **Quote signer (per execution):** full route calldata, amounts, expiration; signatures must stay consistent with terms.
- **LiFi Diamond:** swap/bridge execution and protocol-level min-out reverts on the source chain.
- **Not enforced on-chain:** destination-chain delivery for bridges; absolute market price (requires oracle); recipient address format correctness (equality only).

#### Composition

Pair with separate caveats for token approval to the diamond. Consider `AllowedTargetsEnforcer` if you want to restrict the diamond address independently (redundant if already pinned in terms).

#### Replay binding

The signed quote binds `delegationHash` and the source `chainid` (in `hashQuote`), so a quote signed for one delegation cannot be replayed against another delegation with identical terms, and a quote signed for chain A is invalid on chain B even if the diamond address coincides. Within the quote's validity window, replay against the **same** delegation is still possible; it is bounded by the period budget (each replay consumes `inputAmount`) and by calldata idempotency (the identical diamond calldata usually self-reverts on the second call). A per-quote nonce is not implemented in v1 because it would require off-chain replay tracking by the quote signer.

#### Slippage bounds

`slippageBps` must be **strictly less than** `10000`. At `10000` the slippage check accepts any non-zero `minAmountOut`, effectively disabling protection — the enforcer rejects this value to prevent a footgun. Pick a value such as `50` (0.5%).

#### Trust assumptions

- **`msg.sender` namespacing.** The enforcer keys period-budget and afterHook-context storage by `msg.sender`, expecting it to be the `DelegationManager`. A direct external call to `beforeHook`/`afterHook` only pollutes the caller's own namespace and cannot affect a real delegation's storage (consistent with `ERC20PeriodTransferEnforcer`).
- **Output token for same-chain `afterHook`.** When on-chain verification applies, `beforeHook` calls `balanceOf` on the user-pinned `outputAssetId` (decoded as an EVM address). `DelegationManager.redeemDelegations` has no `nonReentrant` guard, so this is a reentrancy surface; impact is bounded (period budget already consumed; afterHook context not yet written so a reentrant `afterHook` no-ops). The pinned `outputAssetId` must be a trusted ERC20.
- **`afterHook` silent no-op.** For cross-chain / non-EVM recipients, `beforeHook` does not set an afterHook context and `afterHook` returns without reverting. This is intentional — destination delivery cannot be proven on the source chain.

### ApprovalRevocationEnforcer

The `ApprovalRevocationEnforcer` lets a delegator grant a delegate the narrow authority to **clear an existing token approval** on the delegator's behalf, without granting any other power over the delegator's assets. It covers six revocation primitives — three standard token-contract primitives and three against the canonical Permit2 deployment:

- ERC-20 `approve(spender, 0)`
- ERC-721 per-token `approve(address(0), tokenId)`
- ERC-721 / ERC-1155 `setApprovalForAll(operator, false)` (both standards share the selector)
- Permit2 `approve(token, spender, 0, 0)` — single-pair on-chain allowance revocation
- Permit2 `lockdown((address,address)[])` — batched on-chain allowance revocation
- Permit2 `invalidateNonces(token, spender, newNonce)` — invalidate signed-but-unredeemed `permit` payloads

The Permit2 branches are restricted to the canonical deployment at `0x000000000022D473030F116dDEE9F6B43aC78BA3` (deterministic across mainnet, Base, Arbitrum, Optimism, etc.). On chains where canonical Permit2 is not deployed, do not enable the Permit2 bits — see [Trust Assumptions](#trust-assumptions) below.

#### Terms

The enforcer reads a **1-byte bitmask** from `terms` to control which revocation primitives the delegate may use:

| Bit | Hex mask | Allowed primitive |
|-----|----------|-------------------|
| 0   | `0x01`   | ERC-20 `approve(spender, 0)` |
| 1   | `0x02`   | ERC-721 `approve(address(0), tokenId)` |
| 2   | `0x04`   | `setApprovalForAll(operator, false)` (ERC-721 & ERC-1155) |
| 3   | `0x08`   | Permit2 `approve(token, spender, 0, 0)` |
| 4   | `0x10`   | Permit2 `lockdown((address,address)[])` |
| 5   | `0x20`   | Permit2 `invalidateNonces(token, spender, newNonce)` |
| 6–7 | —        | Reserved; MUST be zero |

- Terms MUST be exactly 1 byte.
- A zero mask (`0x00`) is rejected — at least one primitive must be permitted.
- Any reserved bit (6–7) set is rejected.
- `0x3F` enables all six primitives.

**Common examples:**

```
terms = 0x01  →  ERC-20 revocations only
terms = 0x04  →  operator (setApprovalForAll) revocations only
terms = 0x08  →  single-pair Permit2 revocations only
terms = 0x10  →  batched Permit2 revocations only
terms = 0x20  →  Permit2 nonce invalidation only
terms = 0x18  →  both Permit2 on-chain revocation primitives
terms = 0x38  →  all three Permit2 primitives (full Permit2 sever: on-chain allowance + pending signed permits)
terms = 0x3F  →  all six primitives allowed
```

#### Permit2 Revocation Surface

The three Permit2 primitives target different parts of Permit2's state, and **none of them subsumes the others**:

| Primitive             | Zeros `amount`? | Resets `expiration`?            | Bumps `nonce`? | Invalidates pending signed permits? |
|-----------------------|-----------------|---------------------------------|----------------|-------------------------------------|
| `approve(_,_,0,0)`    | yes             | yes (set to `block.timestamp`) | no             | no                                  |
| `lockdown(pairs)`     | yes             | no                              | no             | no                                  |
| `invalidateNonces(…)` | no              | no                              | yes            | yes                                 |

To **fully sever** a delegator's Permit2 exposure to a `(token, spender)` pair, both an on-chain allowance revocation (bit 3 or 4) **and** a nonce invalidation (bit 5) are typically required. Enabling only on-chain revocation leaves any signed-but-unredeemed `permit` payloads live; enabling only nonce invalidation leaves the existing on-chain allowance intact. Bit-mask `0x38` enables all three.

> **Note (DoS surface on bit 5).** A delegate granted `invalidateNonces` (bit `0x20`) can advance the stored nonce for any `(token, spender)` pair the caveat does not pin (Permit2 caps the per-call delta at `type(uint16).max`, but a determined delegate can repeat until `nonce == type(uint48).max`, after which the root delegator can no longer sign new permits for that pair). This is never an authority escalation — it can only invalidate, never create — but it is a denial-of-service vector for the delegator's future signed-permit flow. When granting bit 5, pin the `(token, spender)` pair via `AllowedCalldataEnforcer` / `ExactCalldataEnforcer` and/or rate-limit the delegation with `LimitedCallsEnforcer`.

#### How It Works

The enforcer runs only in single call type and default execution mode and makes no assumption about the target contract (other than the Permit2 branches, which require the canonical Permit2 address). In `beforeHook` it:

1. Decodes and validates the 1-byte terms bitmask (rejects empty, zero, or reserved-bit-set terms).
2. Requires the execution to transfer zero native value and to carry at least 4 bytes of calldata.
3. Dispatches by selector and applies the permitted-primitive check (per the bitmask), then branches:
   - **Permit2 `approve(address,address,uint160,uint48)`** — requires `target == _PERMIT2`, calldata length `== 132`, `amount == 0`, and `expiration == 0`. No on-chain liveness check is performed.
   - **Permit2 `lockdown((address,address)[])`** — requires `target == _PERMIT2`. The calldata is otherwise unconstrained: every entry of the array structurally forces `amount = 0` for the corresponding `(token, spender)` pair (`expiration` and `nonce` are left untouched), so no parameter the delegate could supply can grant new authority. A malformed array reverts inside Permit2 itself.
   - **Permit2 `invalidateNonces(address,address,uint48)`** — requires `target == _PERMIT2`. The calldata is otherwise unconstrained: Permit2 enforces strict nonce monotonicity (and a per-call delta capped at `type(uint16).max`), so the call can only invalidate signed-but-unredeemed `permit` payloads, never create or extend an allowance.
   - **`setApprovalForAll(address operator, bool approved)`** (calldata length 68) — requires `approved == false` and `isApprovedForAll(delegator, operator) == true` on the target.
   - **`approve(address, uint256)`** (calldata length 68, shared by ERC-20 and ERC-721) — disambiguated by the first parameter:
     - First parameter is `address(0)` → treated as an ERC-721 per-token revocation; requires `getApproved(tokenId)` on the target to return a non-zero address.
     - First parameter is non-zero → treated as an ERC-20 revocation; requires the second parameter (amount) to be zero and `allowance(delegator, spender) > 0` on the target.
4. Reverts on any other selector.

All six accepted calldatas structurally reduce permissions (amount `0`, spender `address(0)`, `approved` `false`, per-pair Permit2 amount zeroing, or strictly monotonic Permit2 nonce bump). A delegate using this enforcer can therefore **never be granted new authority** over the delegator's assets — only existing approvals can be cleared and pending Permit2 signatures invalidated.

#### Liveness vs. Race-Freedom

The ERC-20, ERC-721, and `setApprovalForAll` branches each include a "pre-existing approval" check on the target token contract. This is a liveness / sanity guard ensuring the call is not a no-op at the time the hook runs. It is **not** a race-free invariant: the delegator could independently clear the approval between the hook and the execution. In that case the execution is still safe — it simply becomes a no-op on the token contract.

The three Permit2 branches intentionally **omit** this on-chain liveness pre-check. Permit2 silently overwrites any existing allowance, so a call against a `(token, spender)` pair with no live allowance is a harmless no-op (or, for `invalidateNonces` against a triple whose stored nonce already meets the new value, reverts inside Permit2 itself). The structural constraints (canonical Permit2 target, fixed selector, and — for `approve` — zero amount and zero expiration) already guarantee the call can only reduce permissions.

#### Trust Assumptions

The Permit2 branches assume the canonical Uniswap-deployed Permit2 contract is at `_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3` on the target chain. On chains where Uniswap has deployed Permit2 this is a safe deterministic address. On chains where canonical Permit2 is **not** deployed:

- if the address is empty, the executor's call returns successfully with no effect (harmless no-op);
- if a *different* contract happens to live at that address, the selector dispatches into whatever that contract does. The `approve(0, 0)` branch is partially self-protected by its structural calldata checks (any contract under that selector would have to interpret the layout identically to grant authority), but `lockdown` and `invalidateNonces` have no such structural moat.

Delegators on chains without canonical Permit2 should NOT enable bits 3, 4, or 5.

#### Incompatibility: ERC-20 Tokens That Revert on Zero-Value `approve`

A small number of non-standard ERC-20 tokens — most notably **BNB on Ethereum mainnet**, and a handful of older tokens — revert when `approve(spender, 0)` is called. Because the ERC-20 branch of this enforcer strictly requires `amount == 0` and provides no alternative revocation primitive (e.g. `decreaseAllowance`), **allowances previously granted on such tokens cannot be revoked through this enforcer**: the executed `approve(spender, 0)` reverts inside the token contract.

Implications for delegators:

- Do not rely on a delegation carrying `ApprovalRevocationEnforcer` (bit `0x01`) to clear an outstanding allowance for one of these tokens.
- Be aware before signing a **batch** that includes this enforcer for such a token — the entire batch will revert at the token call.
- Revoke these allowances directly from the owning account (or via a different revocation path) instead.

The ERC-721, `setApprovalForAll`, and Permit2 branches are unaffected.

#### Use Cases

- **Revocation bots / keepers**: Delegate to a third party that can proactively clean up stale or compromised approvals.
- **Post-incident remediation**: Issue a short-lived delegation to revoke a specific approval after a spender contract is found to be malicious. For Permit2, combine bit 3/4 (on-chain) with bit 5 (signature invalidation) to fully sever the spender.
- **User-facing "revoke all" flows**: Let a UI batch revocations on the user's behalf without asking for a new signature per clear. `lockdown` is particularly useful here for clearing many Permit2 allowances in a single transaction; pair it with `invalidateNonces` if the user also wants to kill any outstanding signed permits.

#### Composition

The enforcer is intentionally not scoped to any particular spender, operator, or `(token, spender)` pair. To restrict it further, compose it with existing enforcers:

- `AllowedTargetsEnforcer` — restrict revocation to specific token contracts. Note that for the Permit2 branches the target is already pinned to the canonical Permit2 address by the enforcer itself.
- `AllowedCalldataEnforcer` / `ExactCalldataEnforcer` — pin the exact spender, operator, tokenId, or `(token, spender, newNonce)` triple. For the static branches (`approve`, `setApprovalForAll`, Permit2 `approve`, Permit2 `invalidateNonces`) these compare cleanly against fixed offsets. For Permit2 `lockdown` the calldata is dynamic (offset + array length + entries), so `ExactCalldataEnforcer` is usually the cleaner option for pinning a specific list of pairs.

#### Redelegation Caveat (Link-Local Semantics)

The `_delegator` argument passed to `beforeHook` is the delegator of the specific delegation that carries the caveat, **not** the root of a redelegation chain. The `DelegationManager` always executes the downstream call against the root delegator's account. On a root-level delegation (chain length 1) the two are the same and the pre-check queries the account whose storage will actually be mutated — this is the intended usage.

On an intermediate (redelegation) link the two differ. The implications are different per primitive group:

- **ERC-20 / ERC-721 / `setApprovalForAll` branches** — the pre-check queries the intermediate delegator's approval state while the execution mutates the root delegator's storage. Concretely:
  - If the intermediate delegator has no matching approval, the hook reverts even when the root does (the chain cannot be used, even though the revocation would have been valid for the root).
  - If the intermediate delegator happens to have some approval, the hook passes and the execution clears the root's approval regardless of whether the root actually had one to clear.

- **Permit2 branches** — no per-delegator pre-check is performed. On an intermediate link the link-local sanity guard is simply absent: the hook always passes (subject only to the per-flag and target checks), and the executed call zeros / bumps the root delegator's Permit2 state for whatever `(token, spender)` pair the delegate supplies. Composition with `AllowedCalldataEnforcer` / `ExactCalldataEnforcer` to pin the pair is therefore **load-bearing** — not belt-and-suspenders — for any redelegated Permit2 caveat.

Neither case is an authority escalation (the structural constraints above still hold — the call can only reduce permissions), but the sanity guard is misaligned with the executed effect for the standard branches and absent entirely for the Permit2 branches.

If a redelegator needs a root-scoped guarantee (e.g. "Carol may only revoke one of Alice's specific approvals"), they should rely on structural caveats that compose cleanly across links, such as `AllowedTargetsEnforcer`, `AllowedCalldataEnforcer`, or `ExactCalldataEnforcer`. Placing `ApprovalRevocationEnforcer` on an intermediate link in the hope of validating the root's approval state does not achieve that.

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

---

### ChainlinkPriceRuleEnforcer

The `ChainlinkPriceRuleEnforcer` gates a delegation's redemption on a Chainlink price condition. It composes alongside other enforcers (e.g. `LiFiSwapEnforcer`) on the same delegation — all `beforeHook` checks must pass (AND semantics).

#### Rule kinds

| Kind | Value | Description |
| --- | --- | --- |
| `DIP` | 0 | Price fell ≥ `thresholdBps` over ≤ `windowSeconds` |
| `RISE` | 1 | Price rose ≥ `thresholdBps` over ≤ `windowSeconds` |
| `ABSOLUTE_GTE` | 2 | Current price ≥ `triggerPrice` |
| `ABSOLUTE_LTE` | 3 | Current price ≤ `triggerPrice` |

#### Terms layout (68 bytes, signed at delegation time)

| Offset | Field | Size | Type | Notes |
| --- | --- | --- | --- | --- |
| 0 | `priceFeed` | 20 | `address` | Chainlink proxy (e.g. Base ETH/USD `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70`) |
| 20 | `ruleKind` | 1 | `uint8` | See rule kind table |
| 21 | `expectedDecimals` | 1 | `uint8` | Must match `feed.decimals()` (1-18); prevents decimal mismatch errors |
| 22 | `windowSeconds` | 4 | `uint32` | For DIP/RISE; 0 for absolute |
| 26 | `thresholdBps` | 2 | `uint16` | e.g. 1000 = 10%; 0 for absolute |
| 28 | `maxStaleSeconds` | 4 | `uint32` | Max age of current round |
| 32 | `minGapSeconds` | 4 | `uint32` | Min age of reference round (anti-noise); 0 = only blocks future timestamps |
| 36 | `triggerPrice` | 32 | `int256` | Feed decimals; 0 = unused (relative rules) |

Pack with `ChainlinkPriceRuleLib.encodeTerms()` or `abi.encodePacked(...)` in the same field order.

#### Args layout (redemption time)

```solidity
args = abi.encode(uint80 referenceRoundId)  // 0 for absolute-only rules
```

#### Trust model

- **Current price**: always `latestRoundData()` on `terms.priceFeed` (never from args). Validates `answeredInRound >= roundId` (round is complete), `updatedAt > 0`, and `block.timestamp - updatedAt <= maxStaleSeconds`.
- **Reference price**: `args.referenceRoundId` → `getRoundData()` + timestamp validation against `terms.windowSeconds`. Validates `answeredInRound >= referenceRoundId`, `referenceRoundId < latestRoundId`, and `updatedAt` is within `[now - windowSeconds, now - minGapSeconds]`.
- **Decimals**: `feed.decimals()` must match `terms.expectedDecimals` — prevents decimal mismatch errors on `triggerPrice`.
- **afterHook**: no-op (price check is pre-execution only; no state writes).

A malicious redeemer cannot game the condition by supplying a stale `referenceRoundId` — the enforcer validates `updatedAt` against the user-specified window and `minGapSeconds`, and rejects future timestamps even when `minGapSeconds == 0`.

**Feed address verification (critical):** The enforcer does NOT validate `priceFeed` against a registry. Integrators building delegation-construction UIs MUST hard-verify the feed address (e.g. against the [Chainlink feeds list](https://docs.chain.link/data-feeds/price-feeds/addresses)) before presenting terms to the user for signing. A malicious feed address completely bypasses all price checks and allows the redeemer to trigger the rule at will.

#### Composition with LiFiSwapEnforcer

Stack on the same delegation:

| Caveat | Enforcer | Purpose |
| --- | --- | --- |
| `allowedTargets` | `AllowedTargetsEnforcer` | Only LiFi diamond |
| `valueLte` | `ValueLteEnforcer` | No ETH |
| `chainlinkPriceRule` | `ChainlinkPriceRuleEnforcer` | Price gate (dip / rise / absolute) |
| `lifiSwap` | `LiFiSwapEnforcer` | Budget, slippage, signed quote |

Use cases: "buy the dip" (DIP rule), "take profit" (RISE or ABSOLUTE_GTE), "spike sell" (RISE with short window).

#### Base mainnet price feeds

| Pair | Proxy address |
| --- | --- |
| ETH/USD | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| USDC/USD | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` |

Always verify feed addresses via the [Chainlink price feed addresses page](https://docs.chain.link/data-feeds/price-feeds/addresses) before production use.

#### L2 considerations

On L2s (Base, Arbitrum, etc.), consider also using a [sequencer uptime feed](https://docs.chain.link/data-feeds/l2-sequencer-feeds) to avoid reading stale prices during sequencer downtime. This enforcer only checks `maxStaleSeconds`; it does not integrate a sequencer feed directly.
