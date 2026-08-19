# Delegation manager gas experiments

Variant manager contracts and enforcers for limit-order / gas ablation work live here (`C*`, `O*`, `P*`, `X*` IDs per experiment plan).

Canonical controls remain unchanged:

- `src/DelegationManager.sol`
- `src/DeleGatorCore.sol` and account `executeFromExecutor` implementations

## Phase 2 (C* compatible ablations)

| ID | Path | Change |
| --- | --- | --- |
| C1 | `manager/DelegationManagerC1.sol` | Hoist domain separator per batch |
| C2 | `manager/DelegationManagerC2.sol` | Cached lengths + unchecked loops |
| C3 | `manager/DelegationManagerC3.sol` | Single-redemption fast path |
| C4 | `manager/DelegationManagerC4.sol` | Fused validation loop |
| C5 | `manager/DelegationManagerC5.sol` | Lean redemption events |
| Enforcer | `enforcers/ExactExecutionBatchLimitedCallsProfileEnforcer.sol` | Mode + validity profile v1 |

Docs: `documents/experiments/delegation-manager-gas/C1.md` … `C5.md`, `ProfileEnforcer.md`, `phase-2-compatible-ablations.md`

```bash
forge test --isolate -vv --match-contract "CompatibleAblationDifferential|CompatibleAblationGasBenchmark|ExactExecutionBatchLimitedCallsProfileEnforcerTest|ExecuteFromExecutorForwardingSpy"
```

## Phase 3 (O* one-shot / attested)

| ID | Path | Status |
| --- | --- | --- |
| O-exact | `oneshot/OneShotExactLimitOrderLib.sol` + canonical enforcers | Implemented + benchmarked |
| O-attested-trust | `oneshot/SignedExecutionEnforcer.sol`, `ServiceInstruction*.sol` | Implemented + benchmarked |
| O-attested-receipt | `oneshot/SignedExecutionReceiptEnforcer.sol` | Implemented + benchmarked |
| O-adapter | `oneshot/LimitOrderSwapAdapter.sol` | Implemented + unit tested |

Docs: `documents/experiments/delegation-manager-gas/O.md`

```bash
forge test --isolate -vv --match-contract "OneShotExactLimitOrder|SignedExecutionEnforcer|LimitOrderSwapAdapter|OneShotGasBenchmark"
```

## Phase 4 (P* partial-fill RFQ)

| ID | Path | Status |
| --- | --- | --- |
| P1 | `partial-fill/PartialFillRfqEnforcer.sol`, `PartialFillSettlementAdapter.sol`, `OrderTermsLib.sol` | Implemented + benchmarked |
| P2 | `manager/LimitOrderDelegationManager.sol` | Implemented + benchmarked |

Docs: `documents/experiments/delegation-manager-gas/P1-partial-fill-rfq-enforcer.md`, `P2-limit-order-delegation-manager.md`

```bash
forge test --isolate -vv --match-contract "PartialFill|LimitOrderManager"
```

## Phase 5 (X* exploratory)

| ID | Path | Status |
| --- | --- | --- |
| X1 | `X1/CompactOrderCodec.sol`, `X1/X1CompactOrderDelegationManager.sol` | Implemented + benchmarked |
| X2 | `X2/PersistentERC20HookCoordinator.sol`, `X2/Transient*.sol` | Persistent benchmarked; transient skipped (Cancun/solc) |
| X3 | `X3/X3ActivationCacheDelegationManager.sol` | Implemented + benchmarked |

Docs: `documents/experiments/delegation-manager-gas/X1.md` … `X3.md`

```bash
forge test --isolate -vv --match-contract "X1CompactOrderBenchmark|X2PersistentHookBenchmark|X3ActivationCacheBenchmark"
```
