# O-exact — One-shot exact batch limit order

## Purpose

Baseline Phase 3 path: canonical `DelegationManager` + `ExactExecutionBatchLimitedCallsEnforcer` (limit 1) + `TimestampEnforcer` for a gasless one-shot limit order. Two-exec batch: sell-token approve, then fixed `settleExact` callback.

## Semantic delta

- **Retained:** EIP-712 delegation, hook phases, manager forwarding, disable/enable semantics.
- **Changed vs open-ended delegation:** Execution bytes are hash-bound at sign time; replay blocked after first fill; validity window enforced on-chain.
- **Lost:** Per-fill quote flexibility; dynamic router calldata; partial fills; multi-exec batches beyond the signed pair.

## Benchmark

```bash
forge test --isolate -vv --match-contract OneShotGasBenchmark
```

Environment: `foundry.toml` default (`solc 0.8.23`, `evm_version = london`, `optimizer = true`).

Scenario: EIP-7702 EOA delegator, 2-exec batch (approve + settle), combined enforcer limit 1, timestamp window ±1 day.

| Variant | Exec gas | Calldata bytes | Calldata gas | Est. tx gas |
| --- | ---: | ---: | ---: | ---: |
| O-exact baseline | 203,518 | 2,468 | 15,308 | 239,826 |
| Canonical 1-exec combined (Phase 1 ref) | 156,563 | 10,272 | — | 187,835 |

## Security findings

- Strongest on-chain binding: wrong execution reverts in `ExactExecutionBatchLimitedCallsEnforcer`.
- One-shot limit prevents delegation replay; timestamp bounds limit temporal griefing.
- Settlement logic lives in relayer-controlled callback target — maker must trust encoded `settleExact` path at sign time.
- No on-chain minOut on swap path (direct transfer in test harness); production would need balance enforcer or receipt check.

## Verdict

**Keep as Phase 3 control.** Pure enforcer composition, no new manager surface. **Drop for production limit orders** unless maker accepts fully pre-signed execution calldata and relayer-chosen settlement contract. Best when trust model is “exactly this tx, once, in this window.”
