# Comparison: `refactor/delegation-meta-swap-adapter-v2` vs `feat/delegation-meta-swap-adapter-operator-allowlist`

This document identifies features present on `feat/delegation-meta-swap-adapter-operator-allowlist` that are **not** on `refactor/delegation-meta-swap-adapter-v2`, to help decide whether to port them.

---

## Summary Table

| Feature | v2 branch | operator-allowlist branch | Notes |
|---|---|---|---|
| Single delegation (no subVault) | Yes | No (still vault→subVault→adapter) | v2 is simpler |
| Period-based enforcers | Yes | No (old enforcer stack) | v2 modernized |
| Caller/operator whitelist | Yes (`isCallerAllowed`) | Yes (`allowedOperators`) | Equivalent, different naming |
| ArgsEqualityCheckEnforcer removed | Yes | No (still uses it) | v2 removed it |
| Aggregator ID validation removed | Yes | No (still uses it) | v2 removed it |
| `executeFromExecutor` removed | Yes | No (still has it) | v2 removed it |
| `forceApprove` (USDT-safe) | Yes | No (`safeIncreaseAllowance`) | v2 is safer |
| **MetaSwapParamsEnforcer** | **No** | **Yes** | **New enforcer — see below** |
| **Slippage protection** | **No** | **Yes (scaffolded, disabled)** | **See below** |
| **Per-token max slippage mapping** | **No** | **Yes** | **See below** |
| **Custom recipient via delegation** | **No** | **Yes** | **See below** |
| **Delegator-controlled output token whitelist** | **No** | **Yes** | **See below** |
| **Public `decodeApiData`** | **No** | **Yes** | **See below** |
| **`SwapParams` struct (stack-too-deep fix)** | **No** | **Yes** | **See below** |
| **Pre-encoded `emptyDelegationsContext`** | **No** | **N/A (v2 doesn't need it)** | Operator branch caches the empty delegation encoding |

---

## Features on `operator-allowlist` Not Present on v2

### 1. MetaSwapParamsEnforcer (new CaveatEnforcer)

A brand new enforcer contract (`src/enforcers/MetaSwapParamsEnforcer.sol` + interface) that the **root delegator** includes in their delegation caveats to control:

- **Allowed output tokens**: The delegator specifies which `tokenTo` values are permitted. Supports a wildcard (`ANY_TOKEN = address(0xa11)`) to allow any output token. The enforcer checks `tokenTo` during `beforeHook`.
- **Custom recipient**: The delegator can specify an address to receive swap output instead of themselves. `address(0)` defaults to the root delegator.
- **Max slippage percent per delegation**: The delegator can set a max slippage (18-decimal fixed point, `100e18 = 100%`). `0` means "use the admin default."

**How the adapter uses it:** In `_getRootSwapParams`, the adapter iterates the root delegation's caveats (starting after the ArgsEqualityCheckEnforcer at index 0), finds the MetaSwapParamsEnforcer caveat, reads `recipient` and `maxSlippagePercent` from its terms, and sets `args = abi.encode(tokenTo)` so the enforcer can validate during redemption.

**Consideration for v2:** This is the most significant feature gap. It gives the **delegator** (not just the contract owner) control over which output tokens are acceptable and where swapped tokens go. In v2, output token control is purely via the owner's `isTokenAllowed` mapping, and the recipient is always the root delegator.

### 2. Slippage Protection (scaffolded but disabled)

The operator-allowlist branch adds a post-swap slippage check in `_executeSwap` (renamed from `swapTokens`):

```solidity
// Post-swap slippage check disabled for now. Re-enable when desired.
// if (p_.minAmountOut > 0 && p_.effectiveMaxSlippagePercent > 0) {
//     uint256 minAllowed_ = p_.minAmountOut * (PERCENT_100 - p_.effectiveMaxSlippagePercent) / PERCENT_100;
//     if (obtainedAmount_ < minAllowed_) {
//         revert SlippageExceeded(p_.minAmountOut, obtainedAmount_, p_.effectiveMaxSlippagePercent);
//     }
// }
```

The code is **commented out** — the check is not active. But the infrastructure is fully wired:
- `minAmountOut` is decoded from `_decodeApiData` (the `amountTo` field from swapData)
- `effectiveMaxSlippagePercent` comes from either the delegation's MetaSwapParamsEnforcer or the admin per-token default
- New errors: `SlippageExceeded`, `InvalidMaxSlippage`, `DelegationSlippageExceedsTokenCap`, `PerTokenSlippageNotSet`

**Consideration for v2:** If you want on-chain slippage protection, this is the plumbing. However, it's currently disabled, so it's opt-in to actually activate.

### 3. Per-Token Max Slippage Mapping (admin-side)

```solidity
mapping(IERC20 token => uint256) public maxSlippagePercentPerToken;
```

Owner sets defaults via `setMaxSlippagePercentForToken(IERC20[], uint256[])`. When a delegation's `maxSlippagePercent` is 0, the per-token cap is used instead. The adapter also validates that a delegation's slippage never exceeds the per-token cap.

**Validation rules:**
- `maxSlippagePercentPerToken[tokenTo]` must be > 0 (reverts `PerTokenSlippageNotSet` otherwise)
- Delegation slippage must be <= per-token cap (reverts `DelegationSlippageExceedsTokenCap` otherwise)

**Consideration for v2:** This is tightly coupled to the MetaSwapParamsEnforcer. Without the enforcer, per-token slippage has no source of delegation-level slippage to compare against. However, the admin-side cap alone could be useful as a safety rail.

### 4. Custom Recipient via Delegation

On the operator-allowlist branch, the root delegator can set `recipient != address(0)` in the MetaSwapParamsEnforcer terms, and the swap output goes to that address instead of the root delegator.

On v2, the recipient is always `_delegations[delegationsLength_ - 1].delegator` (the root delegator). There is no mechanism for the delegator to route output elsewhere.

**Consideration for v2:** This is a nice UX feature (e.g., delegator wants swapped tokens sent to a cold wallet or a different account). It requires the MetaSwapParamsEnforcer or similar mechanism.

### 5. Delegator-Controlled Output Token Whitelist

Beyond the owner-level `isTokenAllowed` mapping (which both branches have), the operator-allowlist branch lets the **delegator** specify their own allowed output tokens per-delegation via the MetaSwapParamsEnforcer.

This is a two-tier system:
- Owner controls `isTokenAllowed` (global whitelist)
- Delegator controls allowed output tokens per delegation (via enforcer)

On v2, only the owner-level whitelist exists.

**Consideration for v2:** Useful when different delegators want different output restrictions. However, this also reintroduces the old pattern of mutating caveat `args` before redemption (setting `args = abi.encode(tokenTo)`).

### 6. Public `decodeApiData` Function

The operator-allowlist branch exposes `decodeApiData` as an `external pure` function so off-chain callers or other contracts can decode apiData without reimplementing the logic. It also returns `amountTo` (which the old internal version didn't).

On v2, `_decodeApiData` is `private` and does not return `amountTo`.

**Consideration for v2:** Easy to add if needed. Low risk.

### 7. `SwapParams` Struct

The operator-allowlist branch introduces a `SwapParams` struct to bundle all swap parameters (aggregatorId, tokenFrom, tokenTo, recipient, amountFrom, balanceFromBefore, swapData, minAmountOut, effectiveMaxSlippagePercent) into a single variable, avoiding stack-too-deep errors.

v2 passes these as individual parameters to `_swapTokens`.

**Consideration for v2:** Only needed if you add enough parameters to hit stack-too-deep. Currently v2 is fine without it.

---

## Features on v2 That operator-allowlist Does NOT Have

For completeness, here's what v2 has that the other branch lacks:

| Feature | Detail |
|---|---|
| Single delegation flow | No subVault, no redelegation, simpler delegation array |
| Period-based enforcers | `ERC20PeriodTransferEnforcer` / `NativeTokenPeriodTransferEnforcer` instead of the 5-enforcer stack |
| ArgsEqualityCheckEnforcer removed | Eliminates the whitelist toggle and `_useTokenWhitelist` param |
| Aggregator ID validation removed | No `isAggregatorAllowed` mapping, simpler swap flow |
| `executeFromExecutor` removed | No `ExecutionHelper` inheritance, no self-call pattern |
| `forceApprove` | Safe for USDT and other tokens that require zero-first approval |
| Always-on token whitelist | No toggle; simpler mental model |

---

## Decision Framework

**Port the MetaSwapParamsEnforcer + slippage + custom recipient if:**
- Delegators need per-delegation control over output tokens (beyond the owner whitelist)
- You want on-chain slippage protection (even if initially disabled)
- Delegators need to route output to a different address
- You're okay adding the MetaSwapParamsEnforcer as a new immutable constructor dependency

**Skip them if:**
- The owner-level token whitelist is sufficient control
- Slippage protection is handled off-chain (e.g., API-side quote validation)
- Output always goes to the root delegator
- You want to keep the contract surface minimal

**If porting, adapt to v2's architecture:**
- The operator-allowlist branch still uses the old vault→subVault→adapter chain and ArgsEqualityCheckEnforcer. You'd need to re-implement MetaSwapParamsEnforcer reading against the new single-delegation structure (caveat iteration starts at index 0, not 1).
- The `_useTokenWhitelist` parameter is gone in v2, so the MetaSwapParamsEnforcer's output token list would be **additive** to the owner whitelist, not a replacement.
- The `emptyDelegationsContext` optimization is unnecessary in v2 since there's only one `redeemDelegations` call.
