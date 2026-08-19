# O-attested-receipt — Service attestation + balance receipt

## Purpose

Same trust model as O-attested-trust (`SignedExecutionEnforcer` + `ServiceInstruction`), extended with `SignedExecutionReceiptEnforcer` `afterHook` that verifies receiver buy-token balance increased by at least `minBuyAmount`.

## Semantic delta

- **Retained:** All O-attested-trust checks in `beforeHook` (quote TTL, bounds, execution hash, nonce, ECDSA recovery).
- **Added vs O-attested-trust:** Post-execution balance delta on `(buyToken, receiver)` — on-chain delivery proof independent of quote signer honesty at execution time.
- **Changed vs O-exact:** Flexible router calldata per fill (within signed bounds) instead of frozen batch bytes.
- **Lost:** Same as trust variant; extra `SLOAD`/balance math vs trust-only path.

## Benchmark

```bash
forge test --isolate -vv --match-contract OneShotGasBenchmark
```

Environment: `foundry.toml` default (`solc 0.8.23`, `evm_version = london`, `optimizer = true`).

Scenario: EIP-7702 EOA delegator, 1-exec single call via adapter, receipt enforcer with before/after balance snapshot.

| Variant | Exec gas | Calldata bytes | Calldata gas | Est. tx gas |
| --- | ---: | ---: | ---: | ---: |
| O-attested-receipt | 248,952 | 2,532 | 19,464 | 289,416 |
| O-attested-trust | 240,058 | 2,532 | 19,464 | 280,522 |
| O-exact baseline | 203,518 | 2,468 | 15,308 | 239,826 |
| **Delta (receipt − trust)** | +8,894 (+3.7%) | 0 | 0 | +8,894 (+3.2%) |

## Security findings

- Inherits quote-signer trust and bounds checks from parent enforcer.
- Receipt check closes “quote signed but execution under-delivered” gap that trust-only leaves to adapter `minOut`.
- Balance-delta pattern shares caveats with `ERC20BalanceChangeEnforcer`: fee-on-transfer tokens, direct transfers to receiver in same tx, reentrancy before `afterHook`.
- Transient `balanceBeforeCache` keyed by `(delegationHash, nonce, executionHash)` — safe for single redemption per key in experiment scope.

## Verdict

**Keep when quote service + on-chain settlement proof are both required.** Strongest Phase 3 attested variant for maker protection. **Drop** if gas overhead vs trust-only exceeds benefit and adapter `minOut` + allowlisted routers are sufficient. **Drop vs O-exact** when maker demands fully deterministic calldata with no off-chain quote dependency.
