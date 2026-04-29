# API-signed slippage and price-impact caps (implementation rationale)

This document explains the on-chain protection model the adapter uses against a leaked / misbehaving `swapApiSigner` key. It describes the **implemented design**, not a proposal. See `src/helpers/DelegationMetaSwapAdapter.sol` for the actual code.

> Earlier revisions of this doc proposed an `expectedAmountOut` + post-swap floor model. That approach was **not** what shipped. The implemented model uses signed slippage + price-impact values bounded by per-pair admin caps. The rationale below reflects the live contract.

---

## Threat model

- The **swaps API** (MM Swaps / aggregator API) builds `apiData` and signs the payload with `swapApiSigner`.
- If `swapApiSigner` is compromised, an attacker can sign **any** `apiData` — including quotes with arbitrarily bad terms (e.g. `minAmountOut = 0`, 100% slippage, etc.).
- Without on-chain protection, the adapter would happily execute these swaps because the signature is valid.

We need **on-chain bounds** that hold even if the signer key leaks.

---

## Implemented model

Two complementary defenses:

### 1. Sign extra fields the contract can verify

`SignatureData` carries two extra `uint256` fields beyond `apiData` and `expiration`:

```solidity
struct SignatureData {
    bytes apiData;
    uint256 expiration;
    uint256 slippage;     // 1e18 = 1%, max 100e18
    uint256 priceImpact;  // 1e18 = 1%, max 100e18
    bytes signature;
}
```

Signed digest:

```
keccak256(abi.encode(apiData, expiration, slippage, priceImpact))
```

The API commits to **what slippage and price impact this quote was built for**. If the off-chain backend or end user tampers with either field, the recovered signer no longer matches `swapApiSigner` and the call reverts with `InvalidApiSignature`. So these values are trusted (from the API's perspective) once the signature verifies.

### 2. Admin-set per-pair caps that bound the signed values

Each (`tokenFrom`, `tokenTo`) pair has its own policy:

```solidity
struct PairLimit {
    uint128 maxSlippage;     // 1e18 = 1%, max 100e18
    uint128 maxPriceImpact;  // 1e18 = 1%, max 100e18
    bool    enabled;
}

mapping(IERC20 tokenFrom => mapping(IERC20 tokenTo => PairLimit)) public pairLimits;
```

The owner configures this via `setPairLimits(PairLimitInput[])`. At swap time, `_validatePairPolicy` enforces:

- `pairLimits[tokenFrom][tokenTo].enabled` must be `true` — otherwise `PairDisabled(tokenFrom, tokenTo)`. (Default-zeroed entries are disabled, so unconfigured pairs are blocked automatically.)
- `signedSlippage <= pairLimit.maxSlippage` — otherwise `SlippageExceedsCap`.
- `signedPriceImpact <= pairLimit.maxPriceImpact` — otherwise `PriceImpactExceedsCap`.

So even with a leaked signer key, the worst case for any allowed pair is bounded by the admin caps.

### Combined effect

| Attacker action                                          | Outcome                                             |
| -------------------------------------------------------- | --------------------------------------------------- |
| Sign a swap with `slippage = 100e18` (100%)              | Reverts `SlippageExceedsCap` if any pair cap < 100% |
| Sign a swap on an unconfigured pair                      | Reverts `PairDisabled`                              |
| Sign a swap with tampered `slippage` (e.g. forge `1e18`) | Reverts `InvalidApiSignature` (digest mismatch)     |
| Sign a normal swap within caps                           | Proceeds — same as honest flow                      |

---

## Why we did NOT implement `expectedAmountOut` / on-chain floor

An earlier proposal had the API sign `expectedAmountOut` and the contract compute `requiredMinAmountOut = expectedAmountOut * (1 - effectiveMaxSlippage)`. We rejected this for the following reasons:

1. **No on-chain `expectedAmountOut` source.** The contract would have to trust the value from the signer anyway. So we trust the slippage **outcome** the signer claims, not a derived intermediate.
2. **Math complexity / rounding.** Computing `requiredMinAmountOut` on-chain adds opportunities for off-by-one issues that need to match the API's formula exactly.
3. **Brittleness across aggregators.** Different aggregators encode `minAmountOut` in different positions inside `swapData`; the contract would have to know each format.
4. **Same security guarantee with less surface area.** Bounding the **signed slippage and price impact** against admin caps achieves the same "leaked-key worst case" property without any on-chain math.

The current model deliberately does **not** measure realized slippage post-swap (no `obtainedAmount >= expected * (1 - tol)` check). Realized slippage already gets enforced upstream by `minAmountOut` inside `swapData` (the aggregator itself enforces it). Re-checking on-chain would duplicate work and require parsing the swap data.

---

## Configuration semantics

### Per-pair `enabled` flag doubles as the allow-list

There is **no separate output-token whitelist**. `pairLimits[A][B].enabled` is the only allow check. If you want A→B at 1% caps and A→C disabled entirely, you configure those pairs accordingly.

### Native token sentinel

The contract uses **`address(0)`** for the chain's native token. The Swaps API and admin configuration must agree on this single sentinel.

### Cap units

`1e18 = 1%`, `100e18 = 100%`. `MAX_PERCENT = 100e18` is the upper bound on any cap. `setPairLimits` rejects values above `MAX_PERCENT` with `InvalidPercent(percent)`.

---

## Operational guidance

- **Set conservative caps per pair.** A 5% slippage cap and 5% price-impact cap is usually plenty for stable→stable; 2% for blue-chip pairs; tighter for stables-only. Don't leave caps at 100%.
- **Disable pairs you don't need.** Every enabled pair is an attack surface for a leaked key. Keep the enabled set minimal.
- **Rotate `swapApiSigner` if you suspect key compromise.** `setSwapApiSigner` exists for this.
- **Disable pairs immediately if you see suspicious activity.** `setPairLimits` with `enabled: false` flips a pair off in one tx.
- **Off-chain: clamp the API's slippage to your policy.** Even though the contract caps it, the API should also be configured to never sign higher than what your operator policy allows — this is defense in depth.

---

## Summary

| What                         | Where                                                                              |
| ---------------------------- | ---------------------------------------------------------------------------------- |
| **Sign**                     | `(apiData, expiration, slippage, priceImpact)` — `_validateSignature`              |
| **Cap signed values**        | `pairLimits[tokenFrom][tokenTo].max{Slippage,PriceImpact}` — `_validatePairPolicy` |
| **Allow-list**               | `pairLimits[tokenFrom][tokenTo].enabled` — same check                              |
| **Admin**                    | `setPairLimits(PairLimitInput[])`                                                  |
| **On-chain post-swap floor** | None (delegated to aggregator's `minAmountOut`)                                    |

The model gives contract-level bounds on what an API-signed swap can do, even if the API signer key is compromised, without trusting client-supplied values or duplicating aggregator math on-chain.
