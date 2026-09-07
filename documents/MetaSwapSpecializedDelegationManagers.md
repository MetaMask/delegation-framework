# MetaSwap Specialized Delegation Managers

These experimental managers preserve the existing three-array `redeemDelegations` entrypoint but intentionally support
only one batch/default settlement, one root delegation, and one caveat. The caveat's enforcer address must be the manager
itself because settlement enforcement is internal and no caveat hooks are called.

## MetaSwapHooklessDelegationManager

The redeemer supplies a complete ABI-encoded `Execution[]`. The manager validates the exact approval and swap shape,
records the delegation hash as consumed, snapshots the recipient's output balance in memory, calls the delegator's
`executeFromExecutor`, and checks the minimum output.

## MetaSwapExecutionBuilderDelegationManager

The redeemer supplies only:

```solidity
abi.encode(aggregatorId, routeData)
```

The manager constructs the signed `SkipApproval`, `Approve`, `ResetApprove`, or native-input execution shape. This makes
approval and swap targets, selectors, values, ordering, and amounts impossible for the redeemer to alter.

## Signature modes

- `DirectECDSA` recovers the EIP-712 signer directly and requires it to equal the EIP-7702 delegator address. It bypasses
  the account's ERC-1271 policy and must only be used with EIP-7702 EOAs controlled by that key.
- `ERC1271` calls the delegator's configured signature validation policy and supports broader account types.

The manager's disabled-delegation mapping also acts as permanent one-shot state. A successful delegation cannot be
re-enabled. Failed execution or insufficient output reverts the state update atomically.

## Initial gas comparison

Measured around `redeemDelegations` for an ERC-20 `approve(amount) + swap` using EIP-7702 accounts:

- Standard DelegationManager plus MetaSwap settlement enforcer: `200,781`
- Hookless manager with ERC-1271: `168,404` — `32,377` lower (`16.1%`)
- Hookless manager with direct ECDSA: `166,465` — `34,316` lower (`17.1%`)
- Execution-builder manager with direct ECDSA: `168,631` — `32,150` lower (`16.0%`)

Direct ECDSA saved `1,939` gas over ERC-1271. Constructing executions added `2,166` execution gas relative to validating
redeemer-provided calldata in this prototype; its benefit is stronger authorization and smaller transaction input rather
than lower EVM execution gas.

## Limitations

- Delegation chains, multiple caveats, multiple redemption batches, self-authorized empty contexts, try mode, and generic
  enforcers are intentionally unsupported.
- The execution-builder manager reinterprets `_executionCallDatas[0]` as route context rather than `Execution[]`.
- `enableDelegation`, pause controls, and generic manager administration are intentionally absent.
- Flexible MetaSwap route data retains the same trusted-delegate and unrelated-balance-increase assumptions as the
  settlement enforcer.
