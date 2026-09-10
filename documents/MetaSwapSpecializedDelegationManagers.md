# MetaSwap Specialized Delegation Managers

These experimental managers preserve the existing three-array `redeemDelegations` entrypoint but intentionally support
only one batch/default settlement, one root delegation, and one caveat. The caveat's enforcer address must be the manager
itself because settlement enforcement is internal and no caveat hooks are called.

`executeFromExecutor` remains on the EIP-7702 account. Managers only call it.

## MetaSwapIntentDelegationManager

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

## Gas comparison (`approve(amount) + swap`, EIP-7702)

Measured around `redeemDelegations` in `test/MetaSwapIntentDelegationManager.t.sol` and the specialized suite:

| Path                                      | Gas       | vs generic flexible     |
| ----------------------------------------- | --------- | ----------------------- |
| Generic DM + ExactBatch + LimitedCalls(1) | `230,987` | —                       |
| Generic DM + FlexibleSettlementEnforcer   | `200,783` | baseline flexible       |
| Hookless flexible                         | `166,508` | −17.1%                  |
| Intent ExactCalldata                      | `158,997` | −31.2% vs exact generic |
| Intent FlexibleSettlement                 | `166,725` | −17.0%                  |

Takeaways:

- Flattened exact intent is the cheapest path: no second enforcer, no LimitedCalls nested mapping, no self-`execute` wrap.
- Intent flexible matches hookless (~same gas); the unified manager does not pay a meaningful premium for dispatch.

## Limitations

- Delegation chains, multiple caveats, multiple redemption batches, self-authorized empty contexts, try mode, and generic
  enforcers are intentionally unsupported.
- No on-chain expiry for exact/gasless; relayers enforce freshness off-chain.
- No `enableDelegation` or pause controls.
- Flexible route data retains the same trusted-delegate and unrelated-balance-increase assumptions as the settlement
  enforcer.
