# Unsigned gas estimates (`relayer_estimate7710Transaction`)

Draft for relayer / integrator documentation. Describes how clients can obtain **7710 gas and fee quotes without signing delegations**, using the same transaction shape they will submit later with real signatures.

**Reference implementation:** [`sepoliaEstimateUnsigned.ts`](./sepoliaEstimateUnsigned.ts) (Sepolia probe; run via `npm run poc:sepolia-estimate` from `scripts/lifi-swap`).

**Related specs:**

- Relayer JSON-RPC: `relayer_estimate7710Transaction` in [1shot-okx-relayer `openrpc.json`](https://github.com/1Shot-API/1shot-okx-relayer/blob/develop/openrpc.json) and `openapi.yaml`
- Shim contract and bytecode export: [`src/poc/DelegatorEstimateShim.sol`](../../../../src/poc/DelegatorEstimateShim.sol), [`Relayer-DelegatorEstimateShim.md`](../../../../Relayer-DelegatorEstimateShim.md)

---

## When to use this

Use **placeholder delegation signatures** on **`relayer_estimate7710Transaction`** (and multichain estimate) when:

- The user has already granted a delegation (caveats, delegate, amounts) and you only need a **fresh gas / fee quote** for new execution calldata (e.g. LiFi route changes).
- Re-signing the delegation on every quote is poor UX.

Do **not** use placeholders on **`relayer_send7710Transaction`**. Send requires valid signatures; the relayer rejects placeholder signatures on submit.

---

## Client contract (summary)

| Item | Signed estimate | Unsigned (placeholder) estimate |
|------|-----------------|----------------------------------|
| JSON-RPC method | `relayer_estimate7710Transaction` | Same |
| `params.transactions` | Same structure (permission context + executions) | Same |
| Delegation `signature` fields | Real 65-byte ECDSA (or kit equivalent) | Placeholder (see below) |
| `params.authorizationList` | When delegator has no 7702 code yet | Same rules as signed |
| `params.delegationSecret` | Omit on estimate | Omit on estimate |
| `params.context` | Optional on estimate | Optional on estimate |
| Persisted task / send | No | No |

Build the unsigned request by taking the **same** `params` you would use for a signed estimate and replacing **every** client-submitted delegation `signature` with a placeholder. All other fields (delegator, delegate, caveats, salt, executions, chainId) stay identical to the eventual send.

---

## Placeholder signatures

The relayer treats these as “unsigned estimate” signatures (see `DelegationSignatureUtils` in 1shot-okx-relayer):

| Form | Accepted | Notes |
|------|----------|--------|
| Empty string `""` | Yes | Legacy |
| `bytes32(0)` hex (32 bytes) | Yes | Legacy; **underestimates gas** vs signed path |
| **65-byte all-zero hex** | Yes (**recommended**) | Valid ECDSA length; matches gas profile of real ERC-1271 checks when combined with the delegator shim |

**Recommended constant (132 hex chars including `0x`):**

```text
0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
```

Same value as [`pocConstants.ts`](../pocConstants.ts) (`BOGUS_DELEGATION_SIGNATURE`).

---

## Validation rules (relayer)

1. **Per delegation chain:** Either **all** delegations in `permissionContext` use placeholders, or **all** use real signatures. Mixed chains are rejected.
2. **Per request:** All `transactions[]` entries must use the same mode (all placeholder or all signed). You cannot mix unsigned and signed estimates in one estimate call.
3. **Delegator must be a contract account** (EIP-7702 / smart account with code at the delegator address). Pure EOAs without code cannot use the shim path; sign delegations for those estimates or upgrade the account first.
4. **Chain support:** The relayer must have **`delegatorEstimateShimRuntimeHex`** configured for that chain (patched `DelegatorEstimateShim` runtime for the chain’s `DelegationManager`). Unsupported chains return a configuration error for unsigned estimates.
5. **On-chain balances:** The relayer does **not** fake ERC-20 balances or allowances in state overrides (estimate uses real balances). Simulation reverts if the delegator cannot fund the executions (same as production).

---

## What the relayer does internally (estimate only)

For requests where every client delegation signature is a placeholder:

1. Validates params (same as signed estimate, with placeholder rules above).
2. Redelegates to the pool / target wallet (same as send path).
3. Builds a **Geth-style `stateOverride`** for the 1Shot M2M contract-method estimate:
   - For each **contract** delegator that used a placeholder signature in the client payload, set `stateOverride[delegator].code` to the chain’s **DelegatorEstimateShim** runtime bytecode.
4. Calls 1Shot estimate (`redeemDelegations`) with that override so `DelegationManager` runs **real enforcer hooks** and **real execution calldata**, while ERC-1271 checks hit the shim instead of the live DeleGator.

The shim ([`DelegatorEstimateShim.sol`](../../../../src/poc/DelegatorEstimateShim.sol)) mirrors gas on the paths the manager uses: proxy-style `isValidSignature` (including `ecrecover` work for 65-byte placeholders) and single-default `executeFromExecutor` aligned with `ExecutionHelper`.

**Send path:** No state override; real delegator bytecode; real signatures required.

---

## JSON-RPC example (minimal)

Same envelope as a signed estimate; only `signature` on each delegation in `permissionContext` changes.

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "relayer_estimate7710Transaction",
  "params": {
    "chainId": "11155111",
    "transactions": [
      {
        "permissionContext": [
          {
            "delegate": "0x…",
            "delegator": "0x…",
            "authority": "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            "caveats": [],
            "salt": "0x…",
            "signature": "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
          }
        ],
        "executions": [
          {
            "target": "0x…",
            "value": "0",
            "data": "0x…"
          }
        ]
      }
    ]
  }
}
```

Successful responses match signed estimates: `success`, `gasUsed` per chain, `requiredPaymentAmount`, signed `context` / `contextByChainId` for locking on send.

---

## Accuracy vs signed estimate

Measured on **Base Sepolia** (dev relayer, USDC fee + two `transfer` executions, 7702 delegator, **65-byte** placeholders, realistic shim deployed):

| Metric | Signed | Placeholder | Gap |
|--------|--------|-------------|-----|
| `gasUsed` | ~307,800 | ~302,170 | **~1.8% lower** |

Using **32-byte** `bytes32(0)` placeholders without the realistic shim was **~5% lower**; prefer **65-byte** placeholders on relayers with the updated shim bytecode.

Residual gap is expected (invalid vs valid `ecrecover`, real DeleGator vs shim at the user address). For product policy, treat unsigned quotes as slightly conservative or apply a small inflation factor if parity with signed send estimates is required.

---

## Integrator checklist

- [ ] Use placeholders only on **`relayer_estimate7710Transaction`** / **`relayer_estimate7710TransactionMultichain`**, not send.
- [ ] Use **65-byte zero** placeholders on supported relayers.
- [ ] Keep delegation fields (caveats, delegate, salt, etc.) identical between quote and send; only swap signatures at submit time.
- [ ] Ensure delegator has **7702 code** and sufficient **token balance** for the simulated transfers.
- [ ] Handle estimate failures (reverts) as “cannot quote this calldata,” not as auth bypass on send.
- [ ] Pass **`params.context`** from estimate to send when locking fee quotes (unchanged from signed flow).

---

## Docs to update in 1shot-okx-relayer (when ready)

Suggested touchpoints:

- `openrpc.json` / `openapi.yaml` — describe recommended **65-byte** placeholder; note ~1–2% gas delta vs signed with current shim.
- `public-relayer/SKILL.md` and `public-relayer/references/schemas.md` — unsigned estimate subsection under estimate methods.
- `AGENTS.md` — one paragraph cross-linking placeholder rules and estimate-only state override.

This file can be copied or adapted into those locations.
