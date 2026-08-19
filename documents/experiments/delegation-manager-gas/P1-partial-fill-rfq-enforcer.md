# P1 — Partial-fill RFQ (canonical manager + enforcer + adapter)

## Purpose

Phase 4 control path: keep canonical `DelegationManager` and account `executeFromExecutor` unchanged. Compose a combined before/after enforcer with a minimal settlement adapter for direct bilateral partial-fill RFQ limit orders.

## Architecture

| Component | Role |
| --- | --- |
| `OrderTermsLib` | Shared signed `OrderTerms` + maker-favoring ceil pricing (`mulDiv` Ceil) |
| `PartialFillRfqEnforcer` | Tracks `filledSell[delegationHash]`, pulls buy token from solver in `beforeAllHook`, verifies balance deltas in `afterHook`, atomic rollback on failure |
| `PartialFillSettlementAdapter` | Validates delegation shape, encodes redemption calldata; solver calls `redeemDelegations` directly |

### OrderTerms (signed in caveat)

- `sellToken`, `buyToken`, `receiver`
- `totalSell`, `minTotalBuy`, `minFillSell`
- `validAfter`, `validUntil`, `epoch`, `allowPartial`
- `allowedSolver` (optional; `address(0)` = permissionless via `ANY_DELEGATE` leaf)

Caveat terms for P1: `abi.encode(OrderTerms, settlementAdapter)`.

Fill args: `abi.encode(fillSellAmount, solverAddress)`.

## Semantic delta vs one-shot (O-exact)

- **Retained:** EIP-712 root delegation, hook phases, canonical manager forwarding, disable/enable, epoch bump on enforcer.
- **Gained:** Multiple partial fills, maker-favoring ceil pricing, min-fill / no-dust rules, optional private solver.
- **Lost:** Pre-bound full execution batch; settlement is always `IERC20.transfer(solver, fillSell)`.

## Benchmark

```bash
forge test --evm-version cancun --isolate -vv --match-test test_benchmark_p1_first_partial_subsequent
```

Environment: `solc 0.8.23`, Cancun EVM (balance delta checks), `via_ir` on enforcer.

| Scenario | Exec gas | Calldata bytes | Calldata gas | Est. tx gas |
| --- | ---: | ---: | ---: | ---: |
| First partial fill (100 sell) | 293,059 | 1,572 | 10,704 | 324,763 |
| Subsequent partial fill (200 sell) | 225,014 | 1,572 | 10,704 | 256,718 |
| Final fill (remainder 700 sell) | 225,003 | 1,572 | 10,704 | 256,707 |

## Security notes

- Buy-side payment pulled before sell execution; failed sell reverts entire tx (filledSell rolled back via enforcer lock + revert).
- Fee-on-transfer sell tokens rejected via exact balance-delta checks.
- Native ETH rejected (ERC20 transfer-only profile).
- Dust remainders below `minFillSell` blocked at validation time.
- `epoch` on enforcer keyed by maker (`delegator`); `bumpEpoch()` invalidates open orders.

## Verdict

**Keep for gas/semantics comparison** against integrated manager (P2). Higher per-fill gas than P2 due to full manager + hook overhead, but preserves canonical composition and unchanged account execution path.
