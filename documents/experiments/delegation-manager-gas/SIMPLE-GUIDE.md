# Gas experiments — simple guide

This document explains what we tested, in plain language. Numbers come from isolated Foundry benchmarks on branch `feat/limit-order-manager-gas-experiments` (Aug 2026).

## What we were trying to do

We want **limit orders on chain**: a user signs permission once, and later someone (a “solver”) can execute a swap when conditions are met — without the user paying gas each time.

The **DelegationManager** is the contract that:

1. Checks the signed permission is valid
2. Runs the user’s rules (enforcers)
3. Calls **`executeFromExecutor`** on the user’s smart account to do the swap

**Important:** we did **not** change `executeFromExecutor`. All ideas only change *how* we validate and route before that call.

**Gas** below is “execution gas” inside the manager path unless noted. **Est. tx gas** ≈ 21,000 + calldata cost + execution — closer to what a relayer cares about on L1.

---

## Reference points (start here)

| Name | What it is | Est. tx gas | Notes |
|------|------------|------------:|-------|
| **C0 — Current manager** | Today’s `DelegationManager` + one combined enforcer | **185,722** | Baseline for manager tweaks |
| **Two enforcers instead of one** | Same rules split into 2 contracts | **212,424** | **11.6% worse** — merge them |
| **SimpleDelegationManager** | Aggressive stripped-down manager (other branch) | **158,206** | **~15% cheaper** but **not safe** for production (skips checks) |
| **ERC-7821 signed batch** | Different standard, no delegation caveats | **123,410** | Lower floor, **different trust model** |

**Easy win #1:** ship the **combined enforcer** (exact execution + one-shot limit in one plugin) → saves **~24,600 gas (~11.6%)** with **no manager change**.

---

## Track C — Small fixes to the current manager

Same behavior as today. Each idea is isolated so we could see what actually helps.

| ID | Idea in one sentence | Savings vs C0 | Safe? | Verdict |
|----|----------------------|--------------:|:-----:|---------|
| **C0** | Do nothing (baseline) | — | Yes | Control |
| **C1** | Compute the signing domain hash once per transaction instead of per delegation | **−0.8%** | Yes | Too small alone |
| **C2** | Cache array lengths and use cheaper loop counters | **−1.2%** | Yes | OK to combine with C3 |
| **C3** | Fast path when the batch has exactly **one** redemption (typical limit order) | **−2.4%** | Yes | **Recommended** |
| **C4** | Merge two validation loops into one | **~0%** | Yes | Skip |
| **C5** | Emit smaller event logs (hash only, not full struct) | **−5.9%** | Yes* | Optional — breaks some indexers |
| **Profile enforcer** | Same combined enforcer + bind expiry + full execution mode in terms | **+12% cost** | Yes | Use when you need strict order profiles |

**What C3 actually does:** most limit orders send **one** signed permission per transaction. C3 skips extra loop work when there’s only one item in the batch. All four hook phases still run.

**Recommended combo:** combined enforcer + **C3** (+ maybe C2) → about **~2–3%** cheaper manager path, still fully compatible.

---

## Track O — One-shot limit orders (fill once, then done)

User signs: “run **exactly this** swap once before time X.” Good for fixed routes or a quote that’s already computed off chain.

| ID | Idea in one sentence | vs O-exact | Safe for production? |
|----|----------------------|----------:|:--------------------:|
| **O-exact** | Sign the exact swap calldata + expiry + one-shot replay protection | — | **Yes** — strongest binding |
| **O-attested-trust** | Off-chain service signs “this execution is OK”; chain checks signature + expiry | **+7.8% tx gas** | **No as default** — does not prove you received tokens |
| **O-attested-receipt** | Same as trust, **plus** check recipient’s token balance went up | **+11.1% tx gas** | **Yes** if you need live quotes from a service |
| **O-adapter** | Helper contract runs swap and enforces minimum output | (depends on path) | **Yes** with router allowlist |

**How attested orders work (simple):**

1. User delegation says: trusted quote signer, max sell, min buy, expiry window, allowed router.
2. Off-chain service signs: “run this exact calldata, these amounts, before this time.”
3. On chain we only **verify the signature and compare numbers** — no price oracle.
4. **Trust variant** stops there (cheaper, weaker).
5. **Receipt variant** also checks balances after (more gas, safer).

**Trade-off:** flexible quotes cost **~20–30k extra gas** vs O-exact but avoid signing every route change upfront.

---

## Track P — Partial-fill limit orders (order fills in pieces)

User signs: “sell up to X tokens at this rate; solver can fill part now, part later.”

| ID | Idea in one sentence | First partial fill | Later fills | Verdict |
|----|----------------------|-------------------:|------------:|---------|
| **P1** | Normal manager + enforcer + small adapter; solver calls `redeemDelegations` | **298,023 tx** | **286,374 tx** | Flexible, composable |
| **P2** | Dedicated `LimitOrderDelegationManager` with rules built in | **212,471 tx** | **156,671 tx** | **Much cheaper** |

**Savings:**

- First partial: P2 is **−31% execution gas** vs P1  
- Second partial: P2 is **−50% execution gas** vs P1  

**What P2 gives up:** you use a **special manager** for this order type instead of stacking generic enforcers on the canonical manager. Same economics and security intent; less composable.

**When to pick which:**

- Need arbitrary enforcer stacks → **P1**
- Dedicated limit-order product and want lowest fill cost → **P2**

---

## Track X — Experimental (try only if you accept trade-offs)

| ID | Idea in one sentence | Savings vs normal | Verdict |
|----|----------------------|------------------:|---------|
| **X1** | Shorter binary format instead of full `Delegation[]` ABI encoding | **−9.6% est. tx**, **−25% calldata bytes** | Optional on L2 relays; not general-purpose |
| **X2 transient** | Use EIP-1153 temp storage for balance checks (Cancun) | Not measured on default config | Wait for Cancun + newer compiler |
| **X2 persistent** | Same balance logic with normal storage | **−9.1% exec** | OK as portable control |
| **X3 warm cache** | Skip re-checking signature on 2nd fill | **−25.6% exec** on 2nd fill | **Reject** — unsafe if wallet policy changes |

**X3 in plain terms:** first fill validates signature normally; second fill trusts cache. Saves gas but a smart wallet could change signing rules and the cache would not notice → **do not ship**.

---

## Big picture: what should we actually use?

```text
Step 1 — Everyone
  └─ Combined enforcer (exact batch + one-shot)     ~11% cheaper, zero manager risk

Step 2 — Manager (optional)
  └─ C3 single-redemption fast path                 ~2% cheaper, same behavior

Step 3 — Pick order style
  ├─ One-shot, fixed route        → O-exact
  ├─ One-shot, live quote         → O-attested-receipt (NOT trust-only)
  └─ Partial fills                → P2 if dedicated manager OK, else P1

Step 4 — L2 / relayer only (optional)
  └─ X1 compact encoding          ~10% cheaper posting data
```

---

## What we did **not** recommend

| Thing | Why |
|-------|-----|
| **SimpleDelegationManager as replacement** | ~15–18% cheaper but skips safety checks |
| **O-attested-trust alone** | Quote freshness ≠ proof you got paid |
| **X3 signature cache** | Breaks if ERC-1271 wallet policy changes |
| **C4 fused loops** | No meaningful gas win |
| **Ungated O-adapter routers** | Experiment code — must allowlist routers in prod |

---

## Where to look in the repo

| Doc | Content |
|-----|---------|
| [FINAL-RANKED-COMPARISON.md](./FINAL-RANKED-COMPARISON.md) | Full technical ranking |
| [C1.md](./C1.md) … [X3.md](./X3.md) | Per-variant detail |
| [phase-1-baseline.md](./phase-1-baseline.md) | Original baseline numbers |

**Decision write-up (limit orders + all three jobs):** [LIMIT-ORDERS-AND-GAS-DECISION.md](./LIMIT-ORDERS-AND-GAS-DECISION.md)

**Visual summary:** open [gas-experiments-explained.canvas.tsx](/Users/hanzel/.cursor/projects/Users-hanzel-shared-delegation-framework/canvases/gas-experiments-explained.canvas.tsx) beside the chat.
