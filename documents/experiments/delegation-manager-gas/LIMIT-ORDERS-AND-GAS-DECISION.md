# Limit orders, cheaper manager, and how to choose

This is the decision-facing write-up. Numbers are isolated Foundry measurements on `feat/limit-order-manager-gas-experiments`.

We had **three jobs**:

1. Make the original `DelegationManager` cheaper **without losing features**.
2. Learn from `SimpleDelegationManager` and apply only the **safe** tricks.
3. Design **limit orders** with the existing framework, keep them organized, and compare gas.

---

## What a “limit order” means here

The framework already has this object (see `src/utils/Types.sol`):

```text
Delegation {
  delegate,      // who may redeem (solver, or ANY_DELEGATE = 0xa11)
  delegator,     // the user's account (maker)
  authority,     // ROOT_AUTHORITY for a root order
  caveats[],     // rules: each caveat is { enforcer, terms, args }
  salt,
  signature      // EIP-712, signed by the maker
}
```

- **`terms`** are signed. They cannot change later.
- **`args`** are **not** signed. The solver fills them at redemption time.

A solver later calls:

```text
redeemDelegations(permissionContexts, modes, executionCallDatas)
```

Same function name and argument types as [`DelegationManager.sol`](../../../src/DelegationManager.sol). That call:

1. Checks the signature and the chain of authority.
2. Runs **enforcers** (the `caveats`).
3. Calls `executeFromExecutor` on the **maker’s** account to move tokens / swap.

We **never changed** `executeFromExecutor`. The swap still runs as the user.

**Example:** Alice wants to sell 100 USDC for at least 95 DAI. She signs a `Delegation`. Bob (or any solver) later calls `redeemDelegations` when the market is good. Alice does not send a new transaction.

There was **no** dedicated limit-order product in the repo. We built it from existing pieces.

---

## How we thought about solving limit orders

We looked at real code, not a blank page.

| Existing piece | Path | What we stole from it |
| --- | --- | --- |
| Exact “do this tx once” | `ExactExecutionBatchLimitedCallsEnforcer` | Pin calldata + one-shot replay |
| Time window | `TimestampEnforcer` | Order expiry |
| Min output after a swap | `ERC20MultiOperationIncreaseBalanceEnforcer` / `ERC20BalanceChangeEnforcer` | Check balances **after** execution |
| Off-chain signed quote | `DelegationMetaSwapAdapter` + `ArgsEqualityCheckEnforcer` | API signature + expiry; adapter builds the swap |
| Amount budget | `ERC20TransferAmountEnforcer` | Cap how much you sell (does **not** set price by itself) |
| Cancel | `disableDelegation` / `NonceEnforcer` | Kill one order or a whole series |

**MetaSwap gap:** it decodes `amountTo` from the quote but **does not revert** if the user receives less. Limit orders need that check.

Three product shapes fell out:

```text
A. One-shot, route known now     → O-exact
B. One-shot, route chosen later  → O-attested (your “signed instruction” idea)
C. Fill in pieces at a fixed rate → P1 (plugins) or P2 (special manager)
```

---

## The limit-order options (organized)

### Option A — O-exact (reuse existing enforcers)

**User signs:** “Run **exactly these bytes**, once, before this time.”

**Caveats:**

1. `ExactExecutionBatchLimitedCallsEnforcer` — exact batch + `limit = 1`
2. `TimestampEnforcer` — `validAfter` / `validBefore`

**Code:** `src/experiments/oneshot/OneShotExactLimitOrderLib.sol`  
**Manager:** original `DelegationManager`  
**Entry:** `redeemDelegations`

**Example:** Alice signs `approve(router)` + `router.exactInputSingle(...)` with a fixed path. Bob can only submit that exact calldata.

**Good:** strongest on-chain binding, cheapest one-shot.  
**Bad:** if the pool/route changes, she must sign again.

### Option B — O-attested (off-chain quote service)

This is the idea: **don’t compute price on chain**. A service signs “this execution is OK until T.” On chain we **compare and allow or reject**.

**User signs (`MakerBounds` in `terms`):** trusted `quoteSigner`, token pair, max sell, min buy, max quote lifetime, adapter.

**At fill, solver puts a `ServiceInstruction` in `args`:** execution hash, amounts, expiry, nonce, plus the service signature (`src/experiments/oneshot/ServiceInstructionTypes.sol`).

**Two variants:**

| ID | What on-chain proves | Extra cost vs O-exact |
| --- | --- | --- |
| **O-attested-trust** | Signature + expiry + bounds. Relies on router `minOut` | **+7.8% est. tx** |
| **O-attested-receipt** | Same **plus** receiver balance went up (`afterHook`) | **+11.1% est. tx** |

**Code:** `SignedExecutionEnforcer.sol`, `SignedExecutionReceiptEnforcer.sol`, `LimitOrderSwapAdapter.sol`  
**Inspired by:** `DelegationMetaSwapAdapter.swapByDelegation` (API sig + expiry), with the missing min-out / receipt check added.

**Example:** Alice signs “any Uniswap-style swap USDC→DAI, at least 95 DAI, quotes from MetaMask signer, max 5 minutes old.” The service signs today’s route. Bob submits `redeemDelegations`. The enforcer checks the quote; the adapter runs `swap`.

Use **receipt**, not trust-only, if you care that Alice actually got tokens.

### Option B2 — restricted MetaSwap without a quote signer

New experiment:

- `RestrictedMetaSwapEnforcer.sol` signs and binds: adapter, exact `sellToken`, exact `buyToken`, exact
  `sellAmount`, receiver, minimum buy amount, and aggregator ID.
- `RestrictedMetaSwapAdapter.sol` can call only its immutable MetaSwap contract. It pulls the exact input,
  swaps, sends all output to the signed receiver, and requires:

  `actualBuyAmount >= minBuyAmount`

This is the right inequality for a limit order: **more output is always acceptable**.

Full `redeemDelegations` benchmark with mock MetaSwap:

`234,892 exec / 267,560 est. tx` (1,636 calldata bytes).

That is close to the O-exact benchmark (267,734 tx), while directly binding token-in, token-out, input,
receiver, aggregator, and minimum output. The mock paths are not identical, so treat this as a product-shape
estimate, not a strict 174-gas win over O-exact.

### Option C — Partial fill RFQ (sell X for at least Y, in pieces)

**User signs `OrderTerms`:** sell token, buy token, receiver, `totalSell`, `minTotalBuy`, `minFillSell`, time window, `epoch`, `allowPartial`.

Price is a **ratio**: each fill must pay

`ceil(fillSell * minTotalBuy / totalSell)` (maker-favoring).

**Example:** Sell 1000 SELL for at least 2000 BUY. A fill of 100 SELL must pay at least 200 BUY.

#### P1 — same original manager + new enforcer

- `PartialFillRfqEnforcer` on canonical `DelegationManager`
- Solver still calls **`redeemDelegations`**
- Execution: `sellToken.transfer(solver, fillAmount)`
- Enforcer pulls BUY from the solver in `beforeAllHook`, checks balances in `afterHook`

**Good:** composable with other caveats.  
**Cost:** extra external enforcer calls.

#### P2 — dedicated `LimitOrderDelegationManager`

- Same `redeemDelegations(bytes[], ModeCode[], bytes[])` signature
- Rules live **inside** the manager (no extra enforcer hop)
- Still calls `executeFromExecutor` on the maker
- Optional helper `fillOrder` exists; **gas for product choice should use `redeemDelegations`** (see below)

**Good:** cheapest partial fills.  
**Bad:** not a general-purpose manager; only this order profile.

---

## Why we did **not** use one execution + one enforcer for every gas number

They are **not the same product**. Forcing one execution would either break the design or lie about gas.

| Track | Why the execution / enforcers differ |
| --- | --- |
| **C*** (cheaper original manager) | Same mock `transfer` + combined enforcer on **every** C0–C5. This **is** apples-to-apples. |
| **Simple vs original** | Same swap stand-in in `SimpleDelegationManagerComparison`. Fair. |
| **O-exact** | Must pin **exact** batch bytes (`approve` + settle). That’s the product. |
| **O-attested** | Solver submits **adapter.swap** + quote `args`. Exact-batch enforcer cannot allow a live route. |
| **P1 / P2** | Bilateral RFQ: pull BUY, push SELL. Not a DEX `swap`. Combined exact-batch enforcer has **no remaining-amount** logic (`LimitedCalls` counts **redemptions**, not volume). |

**Fair comparisons we did:**

- C0 vs C1–C5: **same** `redeemDelegations`, **same** enforcer, **same** `transfer`
- O-exact vs O-trust vs O-receipt: **same** manager, different caveats (attested pair is comparable; O-exact is a different swap shape)
- P1 vs P2: **same** economics (partial SELL/BUY). P2 was first timed on `fillOrder`; we **re-timed `redeemDelegations`** so the entry point matches the original manager.

**Unfair if you mix tracks:** “O-exact 268k vs C0 186k” — O-exact does a 2-step settle; C0 does a 1-token transfer. Use C* to judge **manager** savings; use O* / P* to judge **limit-order designs**.

---

## Job 1 — cheaper original manager, keep features

Isolated copies `DelegationManagerC1`…`C5`. Canonical `DelegationManager.sol` was not edited. Same four hook phases, pause, enable/disable, self-auth, ERC-1271 for contracts.

Hot path: one redemption, combined enforcer, mock ERC20 transfer. **C0 = 154,450 exec / 185,722 est. tx.**

| ID | Taken from Simple? | What it does | Est. tx vs C0 | Keep features? | Verdict |
| --- | --- | --- | ---: | --- | --- |
| **C1** | Yes (hoist domain) | `_domainSeparatorV4()` once | **−0.6%** (−1,203) | Yes | Too small alone |
| **C2** | Cheap loops | Cache lengths | **−1.0%** (−1,849) | Yes | Compose with C3 |
| **C3** | Single-item fast path | Skip 2D arrays when batch size is 1 | **−2.0%** (−3,671) | Yes | **Best safe manager win** |
| **C4** | Fused validation loop | One loop, **still all 4 hooks** | **~0%** | Yes | Skip |
| **C5** | Lean events | Log hash, not full `Delegation` | **−4.9%** (−9,113) | Yes* | Optional (indexers) |

\*C5 changes log layout. Behavior of transfers is the same.

**Combined enforcer** (already on the Simple branch, not a manager change): two plugins → one. **−11.6% est. tx** (212,424 → 187,835) on the same manager.

---

## Job 2 — what SimpleDelegationManager taught us

File: `src/SimpleDelegationManager.sol` on `feat/optimized-delegation-manager`.

Same `redeemDelegations` ABI. Same swap stand-in in `SimpleDelegationManagerComparison`.

| Simple trick | Gas effect (their comparison) | Applied to original? |
| --- | --- | --- |
| Combined exact+limit enforcer | ~10–12% | **Yes** — use it; don’t need a new manager |
| Hoist domain | small | **C1** |
| One validation+hook loop | part of ~15–22% Simple vs canonical | **C4** only while **keeping 4 hooks** (~0% extra) |
| `beforeHook` only | large | **No** — drops `afterHook` / `beforeAll` / `afterAll` (balance & payment enforcers fail open) |
| ECDSA before ERC-1271 | large on 7702 | **No** — can bypass a rejecting ERC-1271 policy |
| Drop pause / enable / empty context | small | **No** — feature loss |
| Lean events | medium | **C5** (optional) |

**Simple vs original** (same combined enforcer, gasless swap): ~**187,897 → 158,206 est. tx (−15.8%)**. That extra ~16% is **mostly unsafe or feature-deleting**. Safe takeaway for the original manager: **combined enforcer + C3 (~2%)**, optional C5.

---

## Job 3 — limit-order gas (choose a design)

All of these keep **`redeemDelegations(bytes[], ModeCode[], bytes[])`**.

### One-shot (DEX / adapter)

| Option | Est. tx | vs O-exact | What you buy |
| --- | ---: | ---: | --- |
| **O-exact** | **267,734** | — | Cheapest one-shot, fixed calldata |
| O-attested-trust | 288,590 | **+20,856 (+7.8%)** | Live route; **no** delivery proof |
| O-attested-receipt | 297,484 | **+29,750 (+11.1%)** | Live route **and** min received |

### Partial fill (P1 vs P2), **both via `redeemDelegations`**

Measured Aug 19, 2026 (`PartialFillGasBenchmark`).

| | P1 original manager + enforcer | P2 special manager `redeemDelegations` | You save with P2 |
| --- | ---: | ---: | --- |
| First partial (100 sell) | 291,742 exec / **322,950 tx** | 194,852 exec / **225,480 tx** | **−33% exec / −30% tx** (−97,470 tx) |
| Later partial (200 sell) | 223,693 exec / **254,901 tx** | 139,052 exec / **169,680 tx** | **−38% exec / −33% tx** (−85,221 tx) |

P2 `fillOrder` is a bit cheaper (first fill **212,471 tx**) because calldata is smaller. For “same function as original manager,” use the **`redeemDelegations` row**.

---

## What to pick (gas you can actually take)

```text
Still using original DelegationManager
  1. Combined enforcer                    ~−11.6% vs two separate enforcers
  2. C3 (optional C2)                     ~−2% on single redemptions
  3. C5 if indexers can change            ~−5% extra
  4. Limit orders:
       fixed route     → O-exact
       live quote      → O-attested-receipt  (pay ~+11% vs O-exact)
       partial fills   → P1                  (no new manager)

New manager allowed, same redeemDelegations ABI
  Partial fills → P2   ~−30% tx vs P1 on first fill, ~−33% on later fills
```

**Do not ship as a drop-in original manager:** SimpleDelegationManager, O-attested-trust alone, X3 signature cache.

---

## Did we do the three jobs?

| Ask | Done? | Gap we just fixed |
| --- | --- | --- |
| Cheaper original, keep features | **Yes** — C1–C5, differential tests | — |
| Learn from Simple, apply safely | **Yes** — documented; unsafe tricks not copied into C* | — |
| Limit orders from existing examples, several options, gas | **Yes** — O-exact, O-attested, P1, P2 | P2 gas was on `fillOrder`; **now also `redeemDelegations`** |
| Keep `redeemDelegations` signature on the special manager | **Yes** — `LimitOrderDelegationManager.redeemDelegations` | Benchmark now matches that ABI |
| Same execution for all gas charts | **No, on purpose** — products differ; C* / Simple **are** same-execution | Explained above |

---

## Where the code lives

| Piece | Path |
| --- | --- |
| Original manager | `src/DelegationManager.sol` |
| Simple prototype | `src/SimpleDelegationManager.sol` |
| C1–C5 | `src/experiments/manager/DelegationManagerC*.sol` |
| O-exact helpers | `src/experiments/oneshot/OneShotExactLimitOrderLib.sol` |
| Attested enforcers | `src/experiments/oneshot/SignedExecution*.sol` |
| Swap adapter | `src/experiments/oneshot/LimitOrderSwapAdapter.sol` |
| P1 | `src/experiments/partial-fill/PartialFillRfqEnforcer.sol` |
| P2 | `src/experiments/manager/LimitOrderDelegationManager.sol` |
| MetaSwap example | `src/helpers/DelegationMetaSwapAdapter.sol` |
