# MetaSwap Specialized Delegation Managers

These experimental managers preserve the existing three-array `redeemDelegations` entrypoint but intentionally support
only one batch/default settlement, one root delegation, and one caveat. The caveat's enforcer address must be the manager
itself because settlement enforcement is internal and no caveat hooks are called.

`executeFromExecutor` remains on the EIP-7702 account. Managers only call it.

## MetaSwapOrderDelegationManager

One manager for both product intents. Terms start with a one-byte `Intent`.

### ExactCalldata (gasless)

Replaces `ExactExecutionBatchEnforcer` + `LimitedCallsEnforcer(1)`. The user is shown the real swap batch and signs its
hash. Expiry stays off-chain (relayer stops submitting).

```text
terms = intent(1) | executionHash(32)
executionCallDatas[0] = ExecutionLib.encodeBatch(executions)
```

Require `keccak256(executionCallDatas[0]) == executionHash`, then execute the batch directly. No nested self-`execute`
wrap. Supported shapes:

- `[swap]`
- `[approve(amount), swap]`
- `[approve(0), approve(amount), swap]`
- `[swap{value}]` native

### FlexibleSettlement (limit order)

Same settlement shape as the hookless manager, plus the limit-order policies. There is still no redelegation chain.

```text
terms = intent(1) | metaSwap(20) | tokenIn(20) | tokenInAmount(32) | approvalMode(1)
        | tokenOut(20) | recipient(20) | tokenOutMin(32)
        | timestampAfter(16) | timestampBefore(16) | id(32) | redeemers(20*N)
```

- Redeemers are required (`N >= 1`). `address(0)` is a normal allowlist entry for Sentinel pre-sign simulation. The base
  `delegate` check still applies, so a multi-signer order sets `delegate` to `ANY_DELEGATE` and lists the stations.
- Timestamp bounds are optional. `0` disables that bound. A set bound is exclusive (`timestamp > after` and
  `timestamp < before`).
- `id == 0` skips the bitmap. The delegation hash is still one-shot. `id != 0` also burns that id for the delegator, so
  a sibling order with the same id cannot fill. `disableDelegation` does not burn the id.

Redeemer supplies an encoded `Execution[]`. The manager validates approval/swap shape (not `aggregatorId` / route),
snapshots the output balance in memory, executes, then enforces `tokenOutMin`.

## Prototype managers kept for A/B

### MetaSwapHooklessDelegationManager

Flexible-only. Redeemer supplies a complete ABI-encoded `Execution[]`. Validates shape, then executes.

### MetaSwapExecutionBuilderDelegationManager

Flexible-only. Redeemer supplies `abi.encode(aggregatorId, routeData)`. Manager constructs approvals and swap.

Signatures try ECDSA first (EOA and EIP-7702 ETH keys). If that misses, empty accounts revert; accounts with code fall back to ERC-1271.

`disabledDelegations` is both cancel and one-shot consumption. Failed execution or insufficient output reverts atomically.

## Redemption gas comparison (EIP-7702)

Measured with `gasleft()` immediately around `redeemDelegations` in
`test/MetaSwapOrderDelegationManager.t.sol`. Each pair executes the same swap shape from a one-element root delegation,
using an ECDSA signature and a zero starting output-token balance. Values include the manager call but exclude top-level
transaction intrinsic calldata gas.

| Purpose            | Swap shape               | Existing `DelegationManager` path         | Existing gas | Order gas | Saving |
| ------------------ | ------------------------ | ----------------------------------------- | ------------ | --------- | ------ |
| Gasless exact swap | Native swap              | `ExactExecutionBatch` + `LimitedCalls(1)` | `167,475`    | `96,618`  | 42.3%  |
| Gasless exact swap | `approve + swap`         | `ExactExecutionBatch` + `LimitedCalls(1)` | `230,987`    | `152,242` | 34.1%  |
| Gasless exact swap | `reset + approve + swap` | `ExactExecutionBatch` + `LimitedCalls(1)` | `244,355`    | `157,710` | 35.5%  |

Takeaways:

- Exact orders save 34–42% by replacing generic delegation loops, hook calls, full execution terms, and the
  `LimitedCallsEnforcer` state/event with a specialized one-shot path.
- Flexible order redemption gas, with one redeemer, an open timestamp window, and `id == 0`: native `101,491`,
  `approve + swap` `158,750`, `reset + approve + swap` `165,828`.
- The specialized manager's compact redemption event is part of the measured saving; the generic manager emits the full
  delegation.

## Limitations

- Delegation chains, multiple caveats, multiple redemption batches, self-authorized empty contexts, try mode, and generic
  enforcers are intentionally unsupported.
- No on-chain expiry for exact/gasless; relayers enforce freshness off-chain. Flexible orders can set an optional
  timestamp window.
- No `enableDelegation` or pause controls.
- Flexible route data retains the same trusted-delegate and unrelated-balance-increase assumptions as the settlement
  enforcer.
