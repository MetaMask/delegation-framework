# MetaSwap gas experiments — tried / don’t retry

Canonical log of ideas measured while building cheaper MetaSwap managers. **Do not re-isolate these without a new constraint** (new chain opcode, new product UX, etc.).

Metric everywhere: **estimated tx = `21_000 + calldata gas + execution`** (`gasleft()` around the entry). Unless noted, rows are **limit erc20→erc20**, often **warm** (manager lock / nonce word already touched). Cold first-limit (~170k) hides calldata wins — ignore it for product compare.

**Keepers (still in tree):**

| Manager           | Path                                                             | Role                                                               |
| ----------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------ |
| Order             | `src/MetaSwapOrderDelegationManager.sol`                         | PR 207 baseline                                                    |
| Optimized (Final) | `src/metaswap/final/MetaSwapManager.sol`            | Packed + batch-in-calldata; **separate** exact/limit nonce bitmaps |
| DirectRoute       | `src/metaswap/direct-route/MetaSwapManager.sol` | Same EIP-712 fields; route-byte wire; same dual bitmaps            |

Design / live gas tables: [`MetaSwapManager (final)s.md`](MetaSwapManager (final)s.md), [`MetaSwapGasFrontier.md`](MetaSwapGasFrontier.md).  
Re-measure keepers: `forge test --match-path 'test/metaswap-optimized/gas/*' -vv | rg 'GAS\||LEVER\|'`.

---

## 1. Ladder techniques → absorbed into Final

Isolated once, then folded into `MetaSwapManager (final)`. Intermediate contracts **deleted**.

| Idea                                                            |                                                        Approx. win (est. tx) | Verdict      | Why not retry alone                                             |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------: | ------------ | --------------------------------------------------------------- |
| **Nonce bitmap** (nonce = limit id)                             | ~**27k** / limit; ~**17k** / exact once word warm; **0** on exact fresh word | **In Final** | Fresh word still ~22.1k; same floor as any persistent one-shot  |
| **Packed calldata** entries                                     |                                 ~**11k** exact / ~**9k** limit (~940 B less) | **In Final** | Biggest ABI cut; already shipped                                |
| **Flow-specific EIP-712** (`ExactBatch` / `LimitOrder`)         |                 Large **with** packing; ~**3k** limit / ~**11k** exact alone | **In Final** | Alone still ships fat ABI heads                                 |
| **Assembly hot path** (`ecrecover`, scratch hash, account call) |                                              ~**0.8k** exact / ~**3k** limit | **In Final** | Diminishing returns                                             |
| **Slim events** (3-topic, no data)                              |                                                                     ~**630** | **In Final** | Don’t drop events entirely (~1–1.5k) — indexers need fills      |
| **Assembly `executeFromExecutor`** (reuse hashed batch)         |                                                                     ~**900** | **In Final** | Already in Final extras                                         |
| **Split exact / limit managers**                                |                                          ~**2.2k** exact (skip lock `SLOAD`) | **Rejected** | Nested-fill lock won’t span; 7702 account binds **one** manager |

Order → Final headline (cold storage per row; see OptimizedManagers for full shapes): exact avg **~38% → 43.2% fresh / 50.1% warm** vs DM self-call; limit avg **~58% → 65.9% fresh / 69.6% warm** vs separate roots.

---

## 2. Post-Final frontier (deleted experiments)

Same EIP-712 / `executeFromExecutor` constraints unless noted. Code removed after measurement.

### Kept as product

| Idea                                                                                                      |                                  Warm result (erc20→erc20) | vs Final warm ~**93k** / ~**91.5k** 1-redeemer | Verdict                                                                                                 |
| --------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------: | ---------------------------------------------: | ------------------------------------------------------------------------------------------------------- |
| **Route rebuild** (signed bounds; filler sends `aggLen\|agg\|dataLen\|data`; manager builds approve+swap) | DirectRoute warm 1-redeemer **85,996** vs Final **91,601** |                             **−5,605 (~6.1%)** | **Ship as DirectRoute** — same signed fields; wire change only                                          |
| **Shared exact+limit nonce bitmap**                                                                       |                             Same per-fill gas as dual maps |                                   **Replaced** | Independent namespaces: `exactBatchNonceBitmap` / `limitOrderNonceBitmap` (same cold ~22.1k / warm ~5k) |

### Measured and discarded

| Idea                                                                            | Result                                                                          | Verdict          | Why not retry                                                                                                                                 |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| **SlimLimit** (traits packing + **single** redeemer + rebuild)                  | Warm **~85.4k** (−**~7.7k** / ~8.3% vs Final)                                   | **No**           | New EIP-712 type + single-redeemer UX; only ~**+2k** over DirectRoute                                                                         |
| **EIP-2098 compact sig** (64-byte)                                              | Exact **~154.5k** vs Final **~159k** (−**~4.5k**)                               | **No**           | Weak win; experiment lacked limit lock; EOAs already fixed 65 B                                                                               |
| **Multi-fill exact** (`redeemExactBatchMany`)                                   | ~**3k**/order amortized over 4 vs separate Finals                               | **No** (for now) | Different product metric; not single-order headline                                                                                           |
| **Immutable MetaSwap** (not in signed calldata)                                 | Calldata gas **≈ −320**                                                         | **No**           | Marginal; breaks “MetaSwap in signed terms”                                                                                                   |
| **Immutable / admin redeemers or MetaSwap (TrustedSpend B1)**                   | Small calldata; trust shift                                                     | **No**           | Product keeps redeemers + MetaSwap in **signed** calldata                                                                                     |
| **TrustedSettle (B2)** — drop balance / shape checks                            | Large exec cut possible                                                         | **No**           | Unsafe for user bounds                                                                                                                        |
| **Compact nonce/terms (C)** beyond Final packing                                | Overlap with Slim / traits                                                      | **No**           | Absorbed or rejected with Slim                                                                                                                |
| **Passthrough control** (manager-built batch, skip `validateExecutions`)        | **~89.5k** (−**~3.5k** vs Final warm)                                           | Insight only     | Shows ~3.5k is validation skip once batch is trusted; rebuild itself ~2k exec                                                                 |
| **Solidity `abi.encode` route rebuild** (pre-assembly)                          | Calldata −~4k but exec **+~80k**                                                | **No**           | Net loss until assembly `RouteRebuildLib`                                                                                                     |
| **1inch-style 80-bit allowedSender**                                            | —                                                                               | **No**           | Collision across addresses sharing low 10 bytes; require full `address`                                                                       |
| **Relayer `balanceBefore` witness**                                             | —                                                                               | **No**           | Lied witness understates required delta                                                                                                       |
| **Trim redeemer list** (1 vs 4 on Final)                                        | Calldata gas **−720**                                                           | Off-chain only   | Prefer short allowlists; no contract change                                                                                                   |
| **Force recipient = delegator**                                                 | ~**0.4k**                                                                       | **No**           | Tiny; kills payout-to-other UX                                                                                                                |
| **Drop `delegate` / `delegateMode` from wire**                                  | ~**0** meaningful                                                               | **No**           | Signed delegate still required for auth                                                                                                       |
| **Remove SkipApproval / ResetApprove modes**                                    | ≈ **0** gas                                                                     | **No**           | Needed for USDT-style approve(0) and pre-approved paths                                                                                       |
| **Permit2 / pull-via-witness instead of account batch**                         | —                                                                               | **No**           | 7702 path must stay `executeFromExecutor` + MetaSwap router                                                                                   |
| **Symbiosis-style offset patching of amounts**                                  | —                                                                               | **No**           | Terms already fix amounts                                                                                                                     |
| **Sequential nonces**                                                           | —                                                                               | **No**           | Blocks parallel orders                                                                                                                        |
| **EIP-7710 `redeemDelegations` entry** (packed auth in `permissionContexts[0]`) | Warm +**~4.1k** exact / +**~4.3k** limit vs Final; +**~4.4k** DirectRoute limit | **Open**         | ABI framing (~1.6k cdGas) + decode/dispatch (~2.5k exec). Code under `src/metaswap/eip7710-final/`, probe `test/.../gas/Eip7710Gas.t.sol` |
| **`TSTORE` lock / one-shot**                                                    | Would cut lock ~**2.2k → ~0.2k**                                                | **Blocked**      | Target EVM is **`london`** (no transient storage)                                                                                             |
| **Merkle-batched signatures**                                                   | —                                                                               | **No**           | Off-chain only; different trust model                                                                                                         |
| **Signature aggregation**                                                       | —                                                                               | **No**           | Not per-order ECDSA over 7702 EOAs                                                                                                            |
| **Drop events entirely**                                                        | ~**1–1.5k**                                                                     | **No**           | Indexers; Final already slimmed logs                                                                                                          |

---

## 3. Fairness notes (so “new” numbers aren’t false wins)

- Compare **warm** limit rows after the manager lock / code is hot. Suite pattern: exact-then-limit, or an explicit warm redeem.
- Order manager on this branch burns **id `0`** (aligned with Final). Slightly different from older PR207 tips that skipped id `0`.
- Calldata-pinned dual-root / Flexible enforcer baselines live under `test/metaswap-optimized/baseline/` — use for Order-vs-world, not for Final-vs-DirectRoute.
- Fixed floor on every design: account call, swap, transfers, fresh `tokenOut` balance slot (~22.1k when cold).

---

## 4. If you want to try something new

Ask first whether it violates a hard constraint:

1. Off-chain EIP-712 with readable settlement fields
2. One-use nonce (persistent)
3. `executeFromExecutor(SIMPLE_BATCH_MODE, …)` on the 7702 account
4. MetaSwap + redeemers in **signed** calldata (not immutables)
5. Limit lock (or equivalent) against nested fills

If it only reshuffles packing already in Final / DirectRoute, check this doc before writing another manager.
