# DelegationMetaSwapAdapter v2 Changelog

This document details all changes made to the `DelegationMetaSwapAdapter` (and its tests/deploy script) compared to the previous version (v1). Use this as a reference when comparing against future versions.

---

## Architecture Changes

### Single Delegation (no redelegation)

**Before:** The flow required a two-hop delegation chain: `vault → subVault → adapter`. The `subVault` acted as an intermediary that redelegated to the adapter.

**After:** A single delegation from `vault → adapter`. No `subVault` is needed. The delegation chain array in `swapByDelegation` is length 1 instead of 2.

### Removed `ExecutionHelper` / `executeFromExecutor`

**Before:** The contract inherited `ExecutionHelper` (from ERC-7579) and exposed `executeFromExecutor(ModeCode, bytes)`, gated by `onlyDelegationManager`. The swap flow issued **two** `redeemDelegations` calls: one to transfer tokens in, and a second (with an empty delegation) to call back into `swapTokens` on the adapter via `executeFromExecutor`.

**After:** The contract no longer inherits `ExecutionHelper`. There is no `executeFromExecutor` function. The swap flow issues a **single** `redeemDelegations` call (to pull tokens), then calls the private `_swapTokens` directly. This eliminates the self-call pattern entirely.

### `swapTokens` → `_swapTokens` (private)

**Before:** `swapTokens(...)` was `external` with an `onlySelf` modifier.

**After:** `_swapTokens(...)` is `private`. It cannot be called externally at all. The balance-before snapshot is taken before `redeemDelegations`, and the balance delta is verified inside `_swapTokens`.

---

## Access Control Changes

### Removed modifiers: `onlyDelegationManager`, `onlySelf`

These modifiers and their associated errors (`NotDelegationManager`, `NotSelf`, `NotLeafDelegator`) were removed since neither `executeFromExecutor` nor the self-call pattern exist anymore.

### Added: `onlyAllowedCaller` modifier + `isCallerAllowed` mapping

**Before:** `swapByDelegation` had no caller restriction (anyone could call it; the `msg.sender` had to match `_delegations[0].delegator`).

**After:** `swapByDelegation` is gated by `onlyAllowedCaller`. The owner manages the whitelist via `updateAllowedCallers(address[], bool[])`.

**New state:**
- `mapping(address caller => bool allowed) public isCallerAllowed`
- `event ChangedCallerStatus(address indexed caller, bool status)`
- `error CallerNotAllowed()`

### Removed: `NotLeafDelegator` check

The old code verified `_delegations[0].delegator == msg.sender`. This is no longer needed since the caller whitelist replaces it.

---

## Removed Features

### ArgsEqualityCheckEnforcer

**Before:** The constructor accepted an `_argsEqualityCheckEnforcer` address. The root delegation's first caveat had to be this enforcer. The adapter would set `args` on this caveat to either `"Token-Whitelist-Enforced"` or `"Token-Whitelist-Not-Enforced"` depending on the `_useTokenWhitelist` flag, and the enforcer would verify args matched terms at redemption time.

**After:** Completely removed. No `argsEqualityCheckEnforcer` immutable, no `WHITELIST_ENFORCED` / `WHITELIST_NOT_ENFORCED` constants, no `MissingArgsEqualityCheckEnforcer` error, no `SetArgsEqualityCheckEnforcer` event. The `_useTokenWhitelist` parameter is gone from `swapByDelegation`.

### Token Whitelist Toggle (`_useTokenWhitelist` parameter)

**Before:** `swapByDelegation` accepted a `bool _useTokenWhitelist` parameter. When `false`, token whitelist checks were skipped entirely.

**After:** Token whitelist is **always enforced**. `_validateTokens` is now a simple private view function that always checks both `tokenFrom` and `tokenTo` against the owner's whitelist. No toggle.

### Aggregator ID Validation

**Before:** The contract maintained `mapping(bytes32 aggregatorIdHash => bool allowed) public isAggregatorAllowed`. The owner managed it via `updateAllowedAggregatorIds(string[], bool[])`. Swaps reverted with `AggregatorIdIsNotAllowed` if the aggregator wasn't whitelisted.

**After:** Completely removed. No aggregator ID mapping, no `updateAllowedAggregatorIds`, no `ChangedAggregatorIdStatus` event, no `AggregatorIdIsNotAllowed` error. Any aggregator ID is accepted.

---

## Enforcer Changes (Delegation Caveats)

### Removed enforcer stack

The old delegation caveats used:
- `ArgsEqualityCheckEnforcer` (args equality)
- `AllowedTargetsEnforcer` (restrict call targets)
- `AllowedMethodsEnforcer` (restrict callable methods)
- `AllowedCalldataEnforcer` (restrict calldata parameters)
- `ValueLteEnforcer` (cap native token value per call)

### New enforcer stack

The new delegation caveats use:
- **`ERC20PeriodTransferEnforcer`** — rate-limits ERC20 transfers per time period (replaces the old target/method/calldata/amount stack for ERC20 delegations)
- **`NativeTokenPeriodTransferEnforcer`** — rate-limits native token transfers per time period (replaces `ValueLteEnforcer` for native token delegations)
- **`RedeemerEnforcer`** — restricts who can redeem the delegation (unchanged, still used)

---

## ERC20 Approval Change

**Before:** Used `safeIncreaseAllowance` to increase MetaSwap allowance.

**After:** Uses `forceApprove` (sets allowance to `type(uint256).max`). This is safer for tokens like USDT that require the allowance to be zero before setting a new non-zero value.

---

## Constructor Changes

**Before:** 5 parameters: `_owner, _swapApiSigner, _delegationManager, _metaSwap, _argsEqualityCheckEnforcer`

**After:** 4 parameters: `_owner, _swapApiSigner, _delegationManager, _metaSwap`

---

## Removed Imports

- `ExecutionHelper` from `@erc7579/core/ExecutionHelper.sol`
- `CallType, ExecType` from `../utils/Types.sol`
- `CALLTYPE_SINGLE, EXECTYPE_DEFAULT` from `../utils/Constants.sol`

---

## Error Changes

### Removed errors
- `NotDelegationManager()`
- `NotSelf()`
- `NotLeafDelegator()`
- `UnsupportedCallType(CallType)`
- `UnsupportedExecType(ExecType)`
- `AggregatorIdIsNotAllowed(string)`
- `MissingArgsEqualityCheckEnforcer()`

### Added errors
- `CallerNotAllowed()`

---

## Event Changes

### Removed events
- `SetArgsEqualityCheckEnforcer(address indexed)`
- `ChangedAggregatorIdStatus(bytes32 indexed, string, bool)`

### Added events
- `ChangedCallerStatus(address indexed caller, bool status)`

---

## Deploy Script Changes

- `ARGS_EQUALITY_CHECK_ENFORCER_ADDRESS` env var removed from `.env.example`
- `DeployDelegationMetaSwapAdapter.s.sol` constructor call reduced from 5 to 4 args

---

## Test Changes Summary

- Removed `subVault` (no redelegation)
- Delegation arrays reduced from length 2 to length 1
- Removed old enforcer deployments (`AllowedCalldataEnforcer`, `AllowedTargetsEnforcer`, `AllowedMethodsEnforcer`, `ValueLteEnforcer`, `ArgsEqualityCheckEnforcer`)
- Added new enforcer deployments (`ERC20PeriodTransferEnforcer`, `NativeTokenPeriodTransferEnforcer`)
- Added period-based test: `test_canSwapMultipleTimesWithPeriodRefill`
- Added caller whitelist tests: `test_revert_swapByDelegation_callerNotAllowed`, `test_whitelistedCallerCanSwap`, `test_canUpdateAllowedCallers`, `test_revert_updateAllowedCallers_ifNotOwner`, `test_revert_updateAllowedCallers_arrayLengthMismatch`, `test_event_ChangedCallerStatus`
- Added allowance coverage: `test_swapByDelegation_setsAllowanceToMax`
- Removed tests for deleted features: `executeFromExecutor`, `swapTokens` (external), aggregator ID CRUD, `NotSelf`, `NotDelegationManager`, `NotLeafDelegator`, `MissingArgsEqualityCheckEnforcer`, token whitelist toggle
- All `vm.prank(address(subVault.deleGator))` calls removed
- `_whiteListAggregatorId` helper replaced with `_whiteListCaller`
- Mock/fork setup no longer whitelists aggregator IDs; whitelists `address(this)` as caller instead
