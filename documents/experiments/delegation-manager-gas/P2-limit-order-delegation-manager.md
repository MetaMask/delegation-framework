# P2 — Integrated LimitOrderDelegationManager (partial-fill RFQ)

## Purpose

Phase 4 integrated experiment: single root delegation, direct bilateral settlement, built-in fill accounting and balance verification. Still invokes unchanged `executeFromExecutor` on the maker smart account.

## Architecture

| Surface | Role |
| --- | --- |
| `LimitOrderDelegationManager.fillOrder` | Primary solver entry; validates signature, terms, fill rules, pulls buy, executes sell via maker account |
| `LimitOrderDelegationManager.redeemDelegations` | Alternate entry accepting exactly one delegation + single ERC20 transfer execution (direct bilateral profile) |
| Built-in policy | Replaces external enforcer chain: `filledSell`, `makerEpoch`, disable/enable, timing, epoch, optional `allowedSolver` |

### OrderTerms (signed in caveat)

Same struct as P1 without adapter binding. Caveat terms: `abi.encode(OrderTerms)` only; enforcer address is the manager itself (no-op `ICaveatEnforcer` hooks).

Delegate: specific solver address or `ANY_DELEGATE` (`0xa11`) for permissionless fills.

## Semantic delta vs P1

- **Retained:** Same order terms, pricing, partial-fill rules, balance-delta verification, epoch/disable semantics, `executeFromExecutor` on maker.
- **Changed:** Validation and settlement inlined in manager; no external adapter or hook coordinator per fill.
- **Lost:** Composability with arbitrary canonical enforcer stacks; manager must be the root caveat enforcer.

## Benchmark

```bash
forge test --evm-version cancun --isolate -vv --match-test test_benchmark_p2_first_partial_subsequent
```

Environment: `solc 0.8.23`, Cancun EVM, `via_ir` on manager.

| Scenario | Exec gas | Calldata bytes | Calldata gas | Est. tx gas |
| --- | ---: | ---: | ---: | ---: |
| First partial fill (100 sell) | 129,906 | 964 | 7,000 | 157,906 |
| Subsequent partial fill (200 sell) | 55,406 | 964 | 7,000 | 83,406 |
| Final fill (remainder 700 sell) | 55,337 | 964 | 7,000 | 83,337 |

P2 first fill ~55% lower execution gas than P1; subsequent fills ~75% lower.

## Security notes

- Same economic guarantees as P1: ceil pricing, min-fill, no dust, fee-on-transfer rejection on sell leg.
- Signature verified against manager EIP-712 domain (delegator signs manager domain, not canonical manager).
- `allowedSolver` optional restriction in addition to leaf delegate check.
- Pausable + ownable owner surface (experiment only).

## Verdict

**Best gas profile in Phase 4** for direct bilateral partial-fill RFQs when maker accepts a dedicated manager domain and inlined policy. Trade-off: bespoke manager vs composable enforcer stack on canonical `DelegationManager`.
