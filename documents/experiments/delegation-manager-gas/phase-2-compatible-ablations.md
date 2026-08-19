# Phase 2 — compatible manager ablations (C1–C5)

| ID | Path | Change |
| --- | --- | --- |
| C1 | `manager/DelegationManagerC1.sol` | Hoist domain separator per batch |
| C2 | `manager/DelegationManagerC2.sol` | Cached lengths + unchecked loops |
| C3 | `manager/DelegationManagerC3.sol` | Single-redemption fast path |
| C4 | `manager/DelegationManagerC4.sol` | Fused validation loop |
| C5 | `manager/DelegationManagerC5.sol` | Lean redemption events |
| Enforcer | `enforcers/ExactExecutionBatchLimitedCallsProfileEnforcer.sol` | Mode + validity profile v1 |

Canonical controls unchanged: `src/DelegationManager.sol`, `executeFromExecutor`.

## Tests

```bash
forge test --isolate -vv --match-contract "CompatibleAblationDifferential|CompatibleAblationGasBenchmark|ExactExecutionBatchLimitedCallsProfileEnforcerTest|ExecuteFromExecutorForwardingSpy"
```

Docs: `documents/experiments/delegation-manager-gas/C1.md` … `C5.md`, `ProfileEnforcer.md`

## Hot-path summary (1-exec combined enforcer, vs C0)

| Variant | Exec Δ | Est. tx Δ | Verdict |
| --- | ---: | ---: | --- |
| C1 | −0.8% | −0.6% | Drop |
| C2 | −1.2% | −1.0% | Drop (compose candidate) |
| C3 | −2.4% | −2.0% | **Keep** |
| C4 | −0.04% | −0.03% | Drop |
| C5 | −5.9% | −4.9% | Optional (observable) |
