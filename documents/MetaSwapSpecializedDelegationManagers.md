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

Same economics as `MetaSwapFlexibleSettlementEnforcer` / the hookless manager:

```text
terms = intent(1) | metaSwap(20) | tokenIn(20) | tokenInAmount(32) | approvalMode(1)
        | tokenOut(20) | recipient(20) | tokenOutMin(32)
```

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

| Purpose                  | Swap shape        | Existing `DelegationManager` path             | Existing gas | Order gas | Saving |
| ------------------------ | ----------------- | --------------------------------------------- | ------------ | --------- | ------ |
| Gasless exact swap       | Native swap       | `ExactExecutionBatch` + `LimitedCalls(1)`     | `167,475`    | `96,618`  | 42.3%  |
| Gasless exact swap       | `approve + swap`  | `ExactExecutionBatch` + `LimitedCalls(1)`     | `230,987`    | `152,242` | 34.1%  |
| Gasless exact swap       | `reset + approve + swap` | `ExactExecutionBatch` + `LimitedCalls(1)` | `244,355`    | `157,710` | 35.5%  |
| Flexible limit order     | Native swap       | `MetaSwapFlexibleSettlementEnforcer`          | `143,414`    | `101,730` | 29.1%  |
| Flexible limit order     | `approve + swap`  | `MetaSwapFlexibleSettlementEnforcer`          | `200,783`    | `158,990` | 20.8%  |
| Flexible limit order     | `reset + approve + swap` | `MetaSwapFlexibleSettlementEnforcer`    | `207,974`    | `166,072` | 20.1%  |

Takeaways:

- Exact orders save 34–42% by replacing generic delegation loops, hook calls, full execution terms, and the
  `LimitedCallsEnforcer` state/event with a specialized one-shot path.
- Flexible orders save 20–29% while retaining the existing enforcer's approval-shape, swap-calldata, and output-delta
  validations.
- The specialized manager's compact redemption event is part of the measured saving; the generic manager emits the full
  delegation.

## Limitations

- Delegation chains, multiple caveats, multiple redemption batches, self-authorized empty contexts, try mode, and generic
  enforcers are intentionally unsupported.
- No on-chain expiry for exact/gasless; relayers enforce freshness off-chain.
- No `enableDelegation` or pause controls.
- Flexible route data retains the same trusted-delegate and unrelated-balance-increase assumptions as the settlement
  enforcer.
