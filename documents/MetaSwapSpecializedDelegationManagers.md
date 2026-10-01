# MetaSwap Order Delegation Manager

One delegation manager for two MetaSwap flows. It redeems a single root delegation, in batch mode, with one caveat whose enforcer is the manager itself. There is no redelegation chain and no external caveat hook.

`executeFromExecutor` stays on the EIP-7702 account. An account that uses this manager cannot also redeem through `DelegationManager`.

## Gasless swap

The user is shown the swap batch and signs its hash. The relayer submits that same batch once. Expiry stays off-chain.

```text
terms = intent(1) | executionHash(32)
executionCallDatas[0] = ExecutionLib.encodeBatch(executions)
```

`executionHash` is `keccak256(executionCallDatas[0])`. The batch is executed directly. `delegate` is the redeemer, or `ANY_DELEGATE`. `disabledDelegations` is the one-shot.

## Limit order

The user signs the settlement bounds. The redeemer supplies the batch and chooses the route. The manager checks the approval and swap shape, not the aggregator id or the route data, then requires `tokenOutMin` to arrive at the signed recipient.

```text
terms = intent(1) | metaSwap(20) | tokenIn(20) | tokenInAmount(32) | approvalMode(1)
        | tokenOut(20) | recipient(20) | tokenOutMin(32)
        | timestampAfter(16) | timestampBefore(16) | id(32) | redeemers(20*N)
```

- Redeemers are required (`N >= 1`). `address(0)` is a normal allowlist entry for Sentinel pre-sign simulation. A multi-signer order sets `delegate` to `ANY_DELEGATE` and lists the stations.
- Timestamp bounds are optional. `0` disables that bound. A set bound is exclusive (`timestamp > after` and `timestamp < before`).
- `id == 0` skips the bitmap. The delegation hash is still one-shot. `id != 0` also burns that id for the delegator, so a sibling order that shares it cannot fill. `disableDelegation` does not burn the id.

Approval shapes are native swap, skip approval, approve then swap, and reset-approve then swap.

Signatures try ECDSA first. If that misses, an account with no code reverts. An account with code falls back to ERC-1271. `disabledDelegations` is both cancel and one-shot consumption. A failed execution or insufficient output reverts atomically.

## Limitations

- No delegation chains, multiple caveats, multiple batches, try mode, or generic enforcers.
- No on-chain expiry for a gasless swap. A limit order can set a timestamp window.
- No `enableDelegation` and no pause.
- A listed redeemer can choose any route that still pays the signed minimum to the signed recipient.
