# O* — One-shot and service-attested limit orders

## Purpose

Prototype one-shot limit orders on the **canonical** `DelegationManager` without modifying manager or account `executeFromExecutor` implementations.

| ID | Component | Role |
| --- | --- | --- |
| O-exact | `OneShotExactLimitOrderLib` + canonical enforcers | Pinned batch execution + timestamp window + call limit 1 |
| O-attested-trust | `SignedExecutionEnforcer` | EIP-712 `ServiceInstruction` beforeHook; trusts quote signer + router minOut |
| O-attested-receipt | `SignedExecutionReceiptEnforcer` | Trust variant + afterHook recipient balance delta check |
| O-adapter | `LimitOrderSwapAdapter` | Bound routers, SafeERC20, on-chain minOut enforcement |

## EIP-712 ServiceInstruction

Domain: `LimitOrderQuoteService` / version `1` / verifying contract = `quoteSigner` address.

Struct fields: `delegationHash`, `maker`, `chainId`, `manager`, `enforcer`, `mode`, `executionHash`, `sellToken`, `buyToken`, `sellAmount`, `minBuyAmount`, `receiver`, `nonce`, `issuedAt`, `expiresAt`.

Maker bounds (enforcer `terms`): `quoteSigner`, tokens, `receiver`, `adapter`, `maxSellAmount`, `minBuyAmount`, `maxQuoteLifetime`.

## Semantic delta

- **O-exact:** Full calldata pinned at signing; one redemption only. No off-chain quote service.
- **O-attested-trust:** Relaxes exact calldata pinning to service-attested executions within maker bounds. **Does not guarantee settlement** — only quote freshness + execution hash + router revert on minOut.
- **O-attested-receipt:** Adds on-chain buy-token balance increase verification for the receiver.
- **O-adapter:** Adapter-level minOut; separate from enforcer receipt check (defense in depth).

## Benchmark

```bash
forge test --isolate -vv --match-contract OneShotGasBenchmark
```

Environment: `foundry.toml` default (`solc 0.8.23`, `evm_version = london`, `optimizer = true`).

Scenario: single-call swap via `LimitOrderSwapAdapter`, EIP-7702 EOA delegator, one root delegation.

| Variant | Exec gas | Calldata bytes | Calldata gas | Est. tx gas |
| --- | ---: | ---: | ---: | ---: |
| O-exact (batch approve + settle) | 231,426 | 2,468 | 15,308 | 267,734 |
| O-attested-trust | 248,174 | 2,532 | 19,416 | 288,590 |
| O-attested-receipt | 257,068 | 2,532 | 19,416 | 297,484 |
| **Δ trust − exact** | **+16,748 (+7.2%)** | **+64 (+2.6%)** | **+4,108 (+26.8%)** | **+20,856 (+7.8%)** |
| **Δ receipt − exact** | **+25,642 (+11.1%)** | **+64 (+2.6%)** | **+4,108 (+26.8%)** | **+29,750 (+11.1%)** |

Attested paths carry larger calldata (service attestation in caveat args) and ECDSA recovery in beforeHook. Receipt variant adds two balance snapshots.

## Tests

```bash
forge test --isolate -vv --match-contract "OneShotExactLimitOrder|SignedExecutionEnforcer|LimitOrderSwapAdapter"
```

## Security findings

- **Quote signer trust:** Compromised `quoteSigner` can authorize bad routes within maker bounds. Rotate signer via new delegation terms.
- **Replay:** Per-(manager, delegationHash, nonce) mapping in `SignedExecutionEnforcer`; delegation one-shot still requires separate disable/replay policy for O-exact.
- **O-attested-trust settlement:** Malicious router can omit minOut revert; do not use without receipt enforcer or adapter minOut in production.
- **Fee-on-transfer / rebasing tokens:** Not supported; balance checks assume standard ERC-20 semantics.
- **Adapter router allowlist:** `setRouterAllowed` is unpermissioned in experiment code — production needs owner/manager-gated updates.
- **Execution hash binding:** Instruction commits to full `keccak256(executionCallData)`; substitution attacks rejected in tests.

## Verdict

**Keep O-exact** as the safest canonical baseline for fixed-route aggregator orders.

**Keep O-attested-receipt** (not trust-only) when off-chain quote services are required — receipt check closes the settlement gap at ~+29k tx gas over O-exact.

**Keep O-adapter** as reusable settlement plumbing; pair with attested enforcer for hardened paths.
