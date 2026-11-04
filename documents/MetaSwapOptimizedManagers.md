# Optimized MetaSwap delegation managers

## Goal

PR 207's `MetaSwapOrderDelegationManager` handles two MetaSwap flows:

- **Exact batches** (gasless swaps). The user signs one exact `Execution[]` batch.
- **Limit orders**. The user signs the swap terms, and the relayer supplies the route.

This work builds cheaper managers for the same two flows and keeps the same user protections:

- an EIP-712 domain (name, version, chainId, verifyingContract) and off-chain signatures
- execution through `IDeleGatorCore.executeFromExecutor(SIMPLE_BATCH_MODE, abi.encode(Execution[]))`
- an atomic revert on any failure
- EIP-7702 EOA accounts only: fixed 65-byte ECDSA that must recover to the delegator (no ERC-1271)

Targets use the same baselines as the PR:

- Exact batch: an average saving of 50% or more against the `DelegationManager` self-call. The order manager saves ~38% today.
- Limit orders: an average saving above 57.8% against separate roots, which is what the order manager saves today.

## Keepers

| Manager               | Contract                                                         | Limit wire                                                                     |
| --------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **Order**             | `src/MetaSwapOrderDelegationManager.sol`                         | PR 207 baseline (`redeemDelegations` + caveat terms)                           |
| **Optimized (Final)** | `src/metaswap/final/MetaSwapManager.sol`            | Packed terms + full ABI `Execution[]` batch                                    |
| **DirectRoute**       | `src/metaswap/direct-route/MetaSwapManager.sol` | Same EIP-712 limit fields; trailing route bytes; manager rebuilds approve+swap |

Metric: estimated tx = `21_000 + calldata gas + execution` (`gasleft()` around the entry). Each row is its own cold-storage test. Shape order matches the PR: native→token, token→native, token→token, token→token+reset.

| Flow                                         | Order manager | Final, fresh nonce word | Final, warm nonce word | Target |
| -------------------------------------------- | ------------: | ----------------------: | ---------------------: | ------ |
| Exact batch vs `DelegationManager` self-call |         37.7% |                   43.2% |              **50.1%** | ≥50%   |
| Limit order vs separate roots                |         57.9% |               **65.9%** |              **69.6%** | >57.8% |

- Limit orders beat the target cold and warm.
- Exact batches hit 50% only once the nonce word is warm (second order in each 256-nonce block). A fresh word still costs ~22,100; no persistent one-shot avoids that.
- Split exact/limit managers were measured (~2.2k cheaper on exact by skipping a shared lock read) and **rejected**: `EIP7702StatelessDeleGator` trusts one manager, and a cross-contract nested-fill guard would not span both anyway.

DirectRoute vs Final (~6% warm estimated-tx on erc20→erc20): [`documents/MetaSwapGasFrontier.md`](MetaSwapGasFrontier.md).

## Baseline (Order manager vs PR harness)

Ported from `backup/metaswap-order-gas-comparisons` (`d41ff8a`) into `test/metaswap-optimized/baseline/` (`Intent.ExactBatch`). Re-measured Order manager in the optimized harness lands within ~40 gas (calldata zero-byte drift from addresses).

Exact batches:

| Shape                      | `DelegationManager` self-call | Order manager |
| -------------------------- | ----------------------------: | ------------: |
| Native ETH in, token out   |                       207,406 |       119,846 |
| Token in, native ETH out   |                       244,371 |       150,307 |
| Token in, token out        |                       267,138 |       172,834 |
| Token in, token out, reset |                       280,704 |       179,889 |

Limit orders:

| Shape                      | Separate roots | `DelegationManager` + flexible enforcer | Order manager |
| -------------------------- | -------------: | --------------------------------------: | ------------: |
| Native ETH in, token out   |        353,525 |                                 180,290 |       154,912 |
| Token in, native ETH out   |        478,354 |                                 230,784 |       185,311 |
| Token in, token out        |        484,415 |                                 235,375 |       209,792 |
| Token in, token out, reset |        509,838 |                                 244,105 |       218,471 |

## Final vs Order (measured)

### Exact batches vs `DelegationManager` self-call

| Shape                      | DM self-call |   Order | Final fresh | Final warm |
| -------------------------- | -----------: | ------: | ----------: | ---------: |
| Native ETH in, token out   |      207,406 | 119,829 |     106,638 |     89,538 |
| Token in, native ETH out   |      244,371 | 150,304 |     136,507 |    119,407 |
| Token in, token out        |      267,138 | 172,831 |     159,034 |    141,934 |
| Token in, token out, reset |      280,704 | 179,899 |     165,485 |    148,385 |
| **Average saving**         |              |   37.7% |   **43.2%** |  **50.1%** |

Final exact calldata: 922 / 1,178 / 1,178 / 1,434 bytes (Order was 1,860 / 2,116 / 2,116 / 2,372).

### Limit orders vs separate roots

| Shape                      | Separate roots | DM + enforcer |   Order | Final fresh | Final warm |
| -------------------------- | -------------: | ------------: | ------: | ----------: | ---------: |
| Native ETH in, token out   |        353,525 |       180,290 | 154,924 |     119,278 |    102,178 |
| Token in, native ETH out   |        478,354 |       230,784 | 185,302 |     149,048 |    131,948 |
| Token in, token out        |        484,415 |       235,375 | 209,807 |     173,569 |    156,469 |
| Token in, token out, reset |        509,838 |       244,105 | 218,476 |     181,665 |    164,565 |
| **Average saving**         |                |         51.1% |   57.9% |   **65.9%** |  **69.6%** |

Final limit calldata: 1,180 / 1,436 / 1,436 / 1,692 bytes (Order was 2,116 / 2,372 / 2,372 / 2,628).

Re-measured after splitting exact/limit nonce bitmaps (per-fill gas unchanged vs shared map; namespaces independent).

## Techniques already tried (do not re-isolate)

Full measured log (ladder + frontier discards + lever probes): [`MetaSwapGasExperiments.md`](MetaSwapGasExperiments.md).

Short version: bitmap + packed calldata + typed ExactBatch/LimitOrder + assembly are **in Final**; route rebuild is **DirectRoute** (~6% warm); split managers / SlimLimit / compact sig / multi-fill / immutable MetaSwap+redeemers / TrustedSettle are **out**. Order manager cost drivers: dual one-shot on limits, fat ABI framing, `abi.decode` — swap/transfers/`tokenOut` slot are the fixed floor.

## Final design

- **Entries** (packed, after the 4-byte selector):
  - `redeemExactBatch()`: `delegator(20) | nonce(32) | sig(65) | batch`
  - `redeemLimitOrder()`: `delegator(20) | nonce(32) | metaSwap(20) | tokenIn(20) | tokenInAmount(32) | approvalMode(1) | tokenOut(20) | recipient(20) | tokenOutMin(32) | validAfter(16) | validUntil(16) | redeemerCount(1) | redeemers(20N) | sig(65) | batch`
- **Typed data:**
  - `ExactBatch(address delegator,uint256 nonce,bytes32 executionHash)`
  - `LimitOrder(address delegator,uint256 nonce,address metaSwap,address tokenIn,uint256 tokenInAmount,uint8 approvalMode,address tokenOut,address recipient,uint256 tokenOutMin,uint128 validAfter,uint128 validUntil,address[] redeemers)`
  - Domain name `MetaSwapManager (final)`, version `1`, plus chainId and verifyingContract.
  - Public `hashExactBatch` / `hashLimitOrder` for signers; tests sign with them and redeem on the assembly path.
- **Auth:** ExactBatch submission is open (any `msg.sender`). LimitOrder auth is the redeemer allowlist only — no signed `delegate` / `delegateMode` (MetaMask always uses listed redeemers; Exact open submission is intentional).
- **One-shot:** separate maps `exactBatchNonceBitmap` / `limitOrderNonceBitmap` — each `delegator => wordPos => bits`, bit `nonce & 0xff`. Same numeric nonce can be used once per flow. Cancel: `invalidateExactBatchNonce` / `invalidateLimitOrderNonce` (batch: `invalidateExactBatchNonces` / `invalidateLimitOrderNonces`). Views: `isExactBatchNonceUsed` / `isLimitOrderNonceUsed`.
- **Execution:** `executeFromExecutor(SIMPLE_BATCH_MODE, batch)` on the delegator; failure rolls back the nonce bit.
- **No nested-fill storage lock** — see Trust assumptions below.

Behavior vs PR 207 (after id-0 alignment on this branch):

- Order manager burns every FlexibleSettlement `id`, including `0`.
- Final: limit-order nonce is the id; no separate limit `id` field. Exact batches that share an **ExactBatch** nonce are mutually exclusive (PR 207 hash one-shot only blocked the identical batch). ExactBatch nonce N and LimitOrder nonce N do not collide.
- Cancel is `invalidateExactBatchNonce` / `invalidateLimitOrderNonce` (no `disableDelegation`).
- Events: `ExactBatchRedeemed` / `LimitOrderRedeemed` / `ExactBatchNoncesInvalidated` / `LimitOrderNoncesInvalidated`. Fill events are `(delegator, nonce)` topics, no redeemer in the log.
- Exact and limit no longer share a nonce namespace (unlike the first Final draft).

## Security

Parity suite: Order manager + Final (`test/metaswap-optimized/security/`). DirectRoute: `FrontierSecurity`. Final also runs packed-calldata bounds checks.

Checks: domain-bound sigs; bad `s`/`v`/signer/zero delegator; redeemer allowlist (Limit); Exact open submission; exact batch byte/target/value; limit approve/reset/skip/native shapes and bad swaps; free route bytes; exclusive timestamps (`0` = open); `tokenOutMin` at `recipient`; replay / cancel / sibling nonce; failed fill rolls back; nested exact-inside-limit documents the trust assumption (`hasLock = false`); packed header/redeemer bounds.

### Trust assumptions (limit orders)

Limit fills measure `tokenOutMin` as a balance delta across the route. A nested redeem of a _different_ ExactBatch or LimitOrder during that window could inflate the delta. Final and DirectRoute intentionally omit a reentrancy / nested-fill storage lock.

We rely on production limit routes being built by the MetaMask Swaps API and executed through the MetaMask Swap Router (`MetaSwap`) and its allowlisted aggregators. Those adapters are not expected to call back into this manager (or the broader Delegation Framework) mid-swap. Compromising that path would already imply a breach of MetaMask’s router or quote pipeline, which is outside what an on-chain lock on this manager can usefully defend.

Replay of the _same_ permission is still prevented: the limit-order nonce is burned before execution, so the signed ticket cannot be redeemed twice. The same applies to ExactBatch nonces on that flow.

Security tests under `test/metaswap-optimized/security/` record the nested-fill behavior when this trust does not hold.

### Findings and fixes

1. **Nested fills can double-count `tokenOutMin`.** Accepted under the trust assumptions above (no lock). Same class of gap exists for `DelegationManager` + balance-change enforcers across distinct delegation hashes, and for the Order manager.
2. **`delegator` in typed data** — blocks ERC-1271 digest replay across accounts that share an owner.
3. **Reject `delegator == address(0)`** before `ecrecover` (precompile returns zero on failure).
4. **EOA-only 65-byte ECDSA** on Final / DirectRoute (Order manager still had ERC-1271 paths in earlier designs).
5. **No signed delegate** — Exact is open; Limit uses redeemers only (MM product assumption).
6. **`AccountHasNoCode`** before the low-level account call (free: warms the address for `CALL`).
7. **Do not split** exact/limit managers — 7702 accounts bind one manager.

Final still passes the signed batch through unchanged (hash covers executed bytes). DirectRoute rebuilds the batch from signed terms + route (approvals cannot be tampered).

## Harness

- `test/metaswap-optimized/baseline/` — PR gas ports
- `utils/OptimizedHarness.t.sol` + `OptimizedAdapters.t.sol` — fixtures; Order + Final adapters
- `gas/` — `OptimizedGasSuite`, `FrontierGas`, `LeverProbe`
- `security/` — Order / Final / DirectRoute

Gas log line: `GAS|manager|flow|row|estimatedTx|calldataBytes|executionGas`. Collect with:

`forge test --match-path 'test/metaswap-optimized/gas/*' -vv | rg 'GAS\|'`
