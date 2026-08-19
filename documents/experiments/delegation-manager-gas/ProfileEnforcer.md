# Profile enforcer — ExactExecutionBatchLimitedCallsProfileEnforcer

## Purpose

Versioned external profile (`PROFILE_VERSION = 1`) extending `ExactExecutionBatchLimitedCallsEnforcer` with `validAfter`, `validUntil`, and full `ModeCode` binding for limit-order delegations.

## Terms layout

`abi.encodePacked(uint256 limit, uint128 validAfter, uint128 validUntil, bytes32 modeCode, ExecutionLib.encodeBatch(...))`

## Semantic delta vs combined enforcer

- **Added:** Validity window and mode pinning before exact-execution + limited-calls checks.
- **Lost:** None vs combined enforcer semantics; extra header bytes in `terms`.

## Benchmark

```bash
forge test --isolate -vv --match-contract CompatibleAblationGasBenchmark --match-test test_bench_profileEnforcer
```

| Variant | Exec gas | Calldata bytes | Est. tx gas | Δ vs combined |
| --- | ---: | ---: | ---: | ---: |
| Combined enforcer (baseline) | 137,412 | 1,668 | 168,684 | — |
| Profile enforcer | 157,196 | 1,732 | 188,964 | **+19,784 exec (+14.4%) / +20,280 tx (+12.0%)** |

Note: profile benchmark uses canonical manager; delta is enforcer-only on a warm repeat measurement path.

## Verdict

**Keep for limit-order track.** Extra gas buys explicit mode + validity binding required for signed order profiles; compare against dedicated single-call enforcer in later phases.
