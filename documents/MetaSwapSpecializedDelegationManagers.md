# MetaSwap Intent Delegation Manager (Experimental)

Status: **experimental**. Not a drop-in replacement for the generic `DelegationManager`.

## What it is

One purpose-specific manager for two MetaSwap flows:

| Intent | Product | User signs | Redeemer may change |
|--------|---------|------------|---------------------|
| **ExactCalldata** | Gasless exact swap | Full batch hash | Nothing |
| **FlexibleSettlement** | Limit order | Economics + approval shape | Route / `aggregatorId` only |

API kept: `redeemDelegations`, `disableDelegation`. Accounts still expose `executeFromExecutor`; this manager only calls it.

## Why

Generic gasless (`ExactExecutionBatchEnforcer` + `LimitedCallsEnforcer`) and generic flexible settlement pay full hook machinery. This manager inlines checks, uses one one-shot slot (`disabledDelegations`), and runs a direct batch (no self-`execute` wrap).

## Gas (`approve + swap`, EIP-7702, DirectECDSA)

| Approach | Gas |
|----------|-----|
| Generic ExactBatch + LimitedCalls(1) | ~231k |
| Unified ExactCalldata | ~159k (**~31% cheaper**) |
| Hookless flexible (prototype) | ~167k |
| Unified FlexibleSettlement | ~167k |
| Unified + ERC1271 | +~1.9k vs DirectECDSA |

## Related experiments (not required)

- `MetaSwapHooklessDelegationManager` — flexible-only, validates redeemer batch
- `MetaSwapExecutionBuilderDelegationManager` — flexible-only, builds approvals + swap from route data (~2k more gas than hookless)

## Terms

**ExactCalldata**

```text
intent(1) | executionHash(32)
```

`executionHash = keccak256(executionCallDatas[0])` where the payload is `ExecutionLib.encodeBatch(...)`.

**FlexibleSettlement**

```text
intent(1) | metaSwap(20) | tokenIn(20) | tokenInAmount(32) | approvalMode(1)
| tokenOut(20) | recipient(20) | tokenOutMin(32)
```

## Signature modes

- `DirectECDSA` (0) — cheapest; EIP-7702 EOA only
- `ERC1271` (1) — Multisig / Hybrid / custom validators

## Deploy

```bash
# SIGNATURE_MODE=0 DirectECDSA, 1 ERC1271
forge script script/DeployMetaSwapIntentDelegationManager.s.sol \
  --rpc-url <rpc> --private-key $PRIVATE_KEY --broadcast
```

Wire EIP-7702 / DeleGator implementations to the deployed manager address.

## Verify

```bash
# set META_SWAP_INTENT_DELEGATION_MANAGER_ADDRESS and SIGNATURE_MODE in .env
cd script/verification
./verify-metaswap-intent-delegation-manager.sh
```

## Limits

- One root delegation, one self-caveat, batch/default only
- No chains, try-mode, pause, or `enableDelegation`
- Gasless expiry is off-chain
- Flexible routes trust MetaSwap + redeemer; min-out can be met by any balance increase
