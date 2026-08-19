# O-adapter — Bound-router swap adapter

## Purpose

`LimitOrderSwapAdapter`: ERC-7579-style `executeFromExecutor` entry for `DelegationManager`, plus `swap()` that pulls sell token, calls an allowlisted router, and enforces on-chain `minBuyAmount` on receiver balance delta. Execution target for O-attested-trust and O-attested-receipt benchmarks.

## Semantic delta

- **Retained:** Manager-only `executeFromExecutor`; single-call / default-exec mode decoding.
- **Changed vs raw router call in delegation:** Router allowlist, SafeERC20, explicit `minOut` revert (`InsufficientBuyDelivered`).
- **Not standalone redemption path:** Requires attested or manager-wrapped execution; adapter alone does not redeem delegations.

## Benchmark

```bash
forge test --isolate -vv --match-contract OneShotGasBenchmark
```

Adapter exec cost is embedded in `test_gas_O_attested_trust` / `test_gas_O_attested_receipt` (single-call target). Isolated adapter behavior:

```bash
forge test --isolate -vv --match-contract LimitOrderSwapAdapterTest
```

Environment: `foundry.toml` default (`solc 0.8.23`, `evm_version = london`, `optimizer = true`).

| Measurement | Exec gas | Calldata bytes | Calldata gas | Est. tx gas |
| --- | ---: | ---: | ---: | ---: |
| Attested trust path (incl. adapter swap) | 240,058 | 2,532 | 19,464 | 280,522 |
| Attested receipt path (incl. adapter swap) | 248,952 | 2,532 | 19,464 | 289,416 |
| O-exact baseline (no adapter) | 203,518 | 2,468 | 15,308 | 239,826 |

## Security findings

- `onlyDelegationManager` on `executeFromExecutor` — direct `swap()` callable by any approver (expected: tokens only move from `msg.sender`).
- **`setRouterAllowed` is unpermissioned in experiment** — production must gate router registry (owner / governance / enforcer terms).
- Router calldata is opaque `call` — allowlist limits target, not inner behavior (approval draining, malicious callbacks).
- `minOut` compares balance delta on receiver; fee-on-transfer buy tokens may mis-report delivered amount.

## Verdict

**Keep as shared execution primitive** for attested one-shot swaps with allowlisted routers. **Drop experiment deploy as-is** — add access control on router registry before any production use. Re-evaluate marginal gas vs inline router call after benchmark fill; likely **keep** if attested variants ship, **drop** if O-exact wins and no flexible router path is needed.
