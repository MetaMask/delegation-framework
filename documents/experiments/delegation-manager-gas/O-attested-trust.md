# O-attested-trust — Service-signed execution (trust quote)

## Purpose

Replace exact-batch + timestamp caveats with a single `SignedExecutionEnforcer`. Maker signs long-lived `MakerBounds` in caveat terms; a quote service signs per-fill `ServiceInstruction` in caveat args. Relayer redeems single-call execution through `LimitOrderSwapAdapter`.

## Semantic delta

- **Retained:** DelegationManager, EIP-712 delegation hash, hook `beforeHook`, disable/enable.
- **Changed vs O-exact:** 1 caveat instead of 2; single-call mode; execution hash + bounds checked against off-chain quote signature instead of on-chain exact batch encoding.
- **Changed vs canonical:** Introduces trusted `quoteSigner`; per-fill nonce replay protection; adapter target binding.
- **Lost:** On-chain execution-byte equality to signed batch; on-chain buy-token receipt verification (relies on quote + adapter `minOut`).

## Benchmark

```bash
forge test --isolate -vv --match-contract OneShotGasBenchmark
```

Environment: `foundry.toml` default (`solc 0.8.23`, `evm_version = london`, `optimizer = true`).

Scenario: EIP-7702 EOA delegator, 1-exec single call via adapter, service attestation in caveat args.

| Variant | Exec gas | Calldata bytes | Calldata gas | Est. tx gas |
| --- | ---: | ---: | ---: | ---: |
| O-attested-trust | 240,058 | 2,532 | 19,464 | 280,522 |
| O-exact baseline | 203,518 | 2,468 | 15,308 | 239,826 |
| **Delta (trust − exact)** | +36,540 (+18.0%) | +64 | +4,156 | +40,696 (+17.0%) |

## Security findings

- Quote signer compromise allows fills within maker bounds without maker per-fill approval.
- `executionHash` + `mode` binding prevents calldata substitution post-quote.
- Nonce map prevents quote replay per `(manager, delegationHash, nonce)`.
- No `afterHook` balance check — malicious router could satisfy adapter `minOut` via unrelated inbound transfer (fee-on-transfer / donation edge cases weaker than receipt variant).
- Experiment `LimitOrderSwapAdapter.setRouterAllowed` is unpermissioned — not production-safe.

## Verdict

**Keep for gas / UX comparison** when maker explicitly delegates fill authorization to a quote service. **Drop as default framework behavior** unless quote signer is first-class trust domain with monitoring and bounded `MakerBounds`. Prefer **O-attested-receipt** when on-chain delivery proof is required.
