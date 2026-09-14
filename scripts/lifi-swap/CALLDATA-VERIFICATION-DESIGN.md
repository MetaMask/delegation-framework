# LiFiSwapEnforcer: Calldata Verification Design

Summary of design work for upgrading `LiFiSwapEnforcer` to verify **destination chain** and **recipient** against LiFi diamond calldata (via `CalldataVerificationFacet` and/or custom offset decoders).

---

## Goal

Today the enforcer binds quotes via `calldataHash` and checks quote metadata against user-signed **terms**, but does **not** decode LiFi calldata. A malicious or buggy quote signer could theoretically sign metadata that does not match the routing encoded in calldata.

**Target:** In `beforeHook`, verify on-chain that execution calldata delivers to the **terms-pinned destination chain** and **recipient**, using LiFi's `BridgeData` layout and bridge-specific fields where needed.

**Deployment model:** `LiFiSwapEnforcer` will be deployed on **multiple EVM chains** (same CREATE2 address where possible). Hook logic must be **chain-agnostic** — driven entirely by user-signed **terms** and calldata, never by hardcoded chain IDs, token addresses, or diamond addresses baked into the enforcer bytecode.

---

## Multi-Chain Design Rules (required)

The enforcer MUST NOT contain logic of the form “if Base …”, “if chainId == 8453 …”, or any other source-chain-specific branch in `beforeHook` / `afterHook`.

| Do | Don't |
|---|---|
| Compare `terms.destinationChainId` to **`block.chainid`** for same-chain vs cross-chain routing | Hardcode `8453`, `137`, `1`, etc. in the enforcer |
| Read `terms.lifiDiamond`, `terms.inputToken`, `terms.outputAssetId` from signed terms | Assume USDC-on-Base or a fixed LiFi diamond in hook logic |
| Use `block.chainid` in quote signature binding (already in `hashQuote`) | Assume execution always happens on one known network |
| Deploy one enforcer instance per chain; terms pin the **destination** chain | Encode “this enforcer only works on Base” in Solidity |

**Same-chain `afterHook`:** `shouldVerifyOutputOnChain` already returns true when `terms.destinationChainId == block.chainid`. That means a Polygon same-chain swap redeems on **Polygon** (enforcer + delegation on 137) and a Base same-chain swap redeems on **Base** (8453) — no special cases.

**Cross-chain:** Source-chain enforcer verifies calldata **before** bridge execution; destination delivery cannot be proven on the source chain (existing silent `afterHook` no-op is intentional).

---

## Current Trust Model (baseline)

| Layer | What it binds |
|---|---|
| **Terms** (user-signed) | `outputAssetId`, `outputRecipient`, `destinationChainId`, `inputToken`, budget, slippage, `quoteSigner` |
| **SignedLiFiQuote** (quote signer) | Amounts, expiration, `calldataHash`, same metadata fields as terms |
| **Enforcer today** | Quote ↔ terms equality, signature, slippage, budget; **no calldata decode** |
| **afterHook** | Same-chain EVM output balance only (`shouldVerifyOutputOnChain`) |

---

## Route Classes & Verification Strategy

Branch on **terms shape** first; use **function selector** for bridge-specific non-EVM decoders.

| Route class | Condition | Recipient in calldata | Decode approach |
|---|---|---|---|
| **Same-chain EVM** | `terms.destinationChainId == block.chainid` | GenericSwap `_receiver` @ `+0x60`; no `BridgeData` | `extractGenericSwapParameters` or fixed-offset read; **`afterHook` balance check** |
| **Cross-chain EVM** | `destinationChainId != block.chainid` && clean EVM `outputRecipient` | **`BridgeData.receiver`** @ fixed offset | Read `bridgeData` blob + `+0xA0` (receiver), `+0xE0` (dest chain) |
| **Cross-chain non-EVM** | non-clean `outputRecipient` (e.g. BTC) | Bridge-specific `nonEVMReceiver` | Selector-specific offset or byte-scan |

### `BridgeData` fixed offsets (swap + bridge layout)

For `hasSourceSwaps == true`, param heads are at `+0x04`, `+0x24`, `+0x44`; `bridgeData` body typically at offset `0x60`:

| Field | Offset from `bridgeData` start |
|---|---|
| `sendingAssetId` | `+0x80` |
| **`receiver`** | **`+0xA0`** |
| `minAmount` | `+0xC0` |
| **`destinationChainId`** | **`+0xE0`** |

These apply across standard LiFi bridge facets because all use `ILiFi.BridgeData`.

---

## Bridge-by-Bridge Findings (example quotes)

Saved quotes in this directory: `NEAR.json`, `LAYERSWAP.JSON`, `RELAY.json`, `ETHSWAP.json`, `POLYGONSAMECHAIN.json`.

### Same-chain native (Polygon USDC → POL, `toChainId: 137`)

| Field | Example value (`POLYGONSAMECHAIN.json`) |
|---|---|
| Facet | `GenericSwapFacetV3` — `swapTokensMultipleV3ERC20ToNative` (`0x2c57e884`) |
| Route | fee collection → Fly DEX swap (no bridge step) |
| **`_receiver`** | `0x9fEad8B19C044C2f404dac38B925Ea16ADaa2954` @ calldata **`+0x64`** (4 + 0x60) |
| **`minAmountOut`** | `106251567536239116830` (= quote `toAmountMin`) |
| Output asset | native POL — last swap `receivingAssetId == address(0)`; terms use `outputAssetId = bytes32(0)` |
| `destinationChainId` | **Not in calldata** — assert `terms.destinationChainId == block.chainid` (137 on Polygon) |

- **No `BridgeData`**, no bridge string, no `extractMainParameters` / bridge offset decoders.
- Do **not** apply `BridgeData.receiver @ +0xA0` logic to this calldata shape.
- **`afterHook`** is the strongest check: native balance on recipient must increase by `quote.minAmountOut` when enforcer runs on the same chain as terms.
- Executes on **Polygon** (`transactionRequest.chainId: 137`); terms must set `destinationChainId: 137` and be redeemed via an enforcer instance on Polygon.

### Bitcoin (Base USDC → BTC, `toChainId: 20000000000001`)

| Bridge | Selector (swap+bridge) | Recipient verifiable? | Notes |
|---|---|---|---|
| **Near Intents** | `0x3110c7b9` | **Yes** | `NEARIntentsData.nonEVMReceiver` is **1st struct field**; `extractNonEVMAddress` works |
| **LayerSwap** | `0x4c279d6b` | **Yes (custom)** | `nonEVMReceiver` is **4th field** @ struct `+0x60`; `extractNonEVMAddress` reads wrong slot |
| **Relay** | `0xa3443faa` | **No** | `RelayDepositoryData` has only `orderId` + `depositorAddress`; BTC address not on-chain |

- Bech32 is never ASCII in calldata; encode with `encodeLiFiNonEvmBytes32()` (`scripts/lifi-swap/src/terms.ts`).
- Same `bc1q…` → same bytes32 (e.g. `0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f`) in both Near and LayerSwap quotes.
- Near: RFQ liquidity; small clips ($10) intermittent; use `allowBridges=near` in quote API.
- LayerSwap: more reliable at $10; better net output than Near on tested snapshots.
- **Do not use Relay for BTC** if recipient enforcement is required.

### Ethereum native ETH (Base USDC → ETH, `toChainId: 1`)

| Field | Example value (`ETHSWAP.json`) |
|---|---|
| Facet | `AcrossV4SwapFacet` (`0x1794958f`) |
| `BridgeData.receiver` | `0x9fEad8B19C044C2f404dac38B925Ea16ADaa2954` |
| `destinationChainId` | `1` |
| `outputAssetId` in terms | `bytes32(0)` (native ETH sentinel) |

- EVM cross-chain is **simpler than BTC**: real address in `BridgeData.receiver`, not `NON_EVM_ADDRESS` sentinel.
- **Caveat:** `AcrossV4SwapFacet` uses opaque SpokePool `callData`; Li.Fi docs note inner recipient may not be fully cross-checked against `BridgeData.receiver` on-chain. Outer `BridgeData.receiver` + `destinationChainId` are still the practical enforcer bar for a self-hosted quote signer.

### All fixtures at a glance

| Fixture | Route class | Selector | Recipient location | Dest chain in calldata? |
|---|---|---|---|---|
| `POLYGONSAMECHAIN.json` | Same-chain EVM | `0x2c57e884` (GenericSwap multi) | `_receiver` @ **+0x60** | No — use `terms.destinationChainId == block.chainid` |
| `ETHSWAP.json` | Cross-chain EVM | `0x1794958f` (AcrossV4Swap) | `BridgeData.receiver` @ **+0xA0** | Yes @ **+0xE0** |
| `NEAR.json` | Cross-chain non-EVM | `0x3110c7b9` | `nonEVMReceiver` (1st field) | Yes @ **+0xE0** |
| `LAYERSWAP.JSON` | Cross-chain non-EVM | `0x4c279d6b` | `nonEVMReceiver` @ struct **+0x60** | Yes @ **+0xE0** |
| `RELAY.json` | Cross-chain non-EVM | `0xa3443faa` | **Not verifiable** | Yes @ **+0xE0** only |

---

## CalldataVerificationFacet vs Custom Decoding

### Use `CalldataVerificationFacet` (staticcall LiFi diamond)

| Method | Use for |
|---|---|
| `extractMainParameters` | `bridge`, `destinationChainId`, `receiver`, `hasSourceSwaps` |
| `extractNonEVMAddress` | **Near, Mayan, AcrossV4** only (1st field = `bytes32` receiver) |
| `extractGenericSwapParameters` | Same-chain swaps |

**Limitations:**

- `extractNonEVMAddress` does **not** support LayerSwap (wrong struct layout), Chainflip, Relay, etc. (documented in facet `@dev`).
- `_extractBridgeData` uses `abi.decode(data[4:], BridgeData)` which assumes a single top-level tuple; real swap+bridge calldata uses offset heads — **prefer custom offset reads** or validate facet output against known quote samples.

### Custom inline decoders (recommended for enforcer)

Cheaper than staticcall; full control per selector:

```
readBridgeDataOffset(callData) → typically 0x60
receiver  = word at offset + 0xA0
destChain = word at offset + 0xE0

if non-EVM:
  if selector == NEAR:   nonEVM @ bridgeSpecificOffset + 0x24  (first field layout)
  if selector == LAYERSWAP: nonEVM @ bridgeSpecificOffset + 0x60
  if selector == RELAY: revert unsupported
```

Optional **byte-scan** for `terms.outputRecipient` as fallback (works for Near/LayerSwap; fails for Relay).

---

## Bridge Flag / Route Discriminator (design option → resolved)

> **Resolved — see [Resolved Decisions](#resolved-decisions).** The discriminator is a `RouteKind` enum carried in the redeemer-supplied `_args` envelope (ahead of `SignedLiFiQuote`), **not** in terms and **not** signed. Terms stay 284 bytes (no `allowedBridgeMask`). Security relies on cross-checks (enum ↔ selector, enum ↔ terms shape, enum ↔ `block.chainid`), not on trusting the enum. The sketches below are retained for history.

### Idea

Add a discriminator to simplify branching and avoid trying multiple decoders:

- **No bridge / same-chain** → `destinationChainId == block.chainid`
- **Bridge present** → enum or bitmask selects decode path

### Where to put it

| Location | Pros | Cons |
|---|---|---|
| **Terms** (user-signed) | User policy: "BTC via near\|layerswap only" | Terms length change → redeploy enforcer |
| **SignedLiFiQuote** | Per-quote, no terms change | Weaker unless terms also whitelist |
| **Derive from `bytes4(callData[:4])`** | Free, cannot lie | User can't pin bridge at grant time without terms whitelist |

**Recommended:**

1. **`allowedBridgeMask` in terms** (user policy) for non-EVM and optional EVM bridge allowlists.
2. **At execution:** branch on `bytes4(callData[:4])` — no separate per-quote flag needed.
3. **Always cross-check** flag/selector against calldata; never trust flag alone.

```solidity
enum RouteKind { SameChainEvm, CrossChainEvm, CrossChainNonEvm }

// Derive RouteKind from terms only (never from block.chainid alone):
//   SameChainEvm:     terms.destinationChainId == block.chainid
//   CrossChainEvm:    terms.destinationChainId != block.chainid && clean EVM outputRecipient
//   CrossChainNonEvm: otherwise (e.g. BTC bytes32 recipient)

// CrossChainNonEvm: require allowedBridgeMask & selectorBit != 0
// decode recipient via selector-specific path
// require decodedRecipient == terms.outputRecipient
// require decodedDestChain == terms.destinationChainId  (cross-chain only; from BridgeData)
// SameChainEvm: require terms.destinationChainId == block.chainid; no BridgeData decode
```

**Gas:** Savings come from avoiding `CalldataVerificationFacet` staticcalls and byte-scans, not from flag vs selector (both ~negligible). Main win is **one decode path**, not fallback chains.

---

## Implemented `beforeHook` Verification

> Implemented in `src/enforcers/LiFiSwapEnforcer.sol` (`_verifyCalldataMatchesTerms` + per-branch `_verifySameChain` / `_verifyEvmBridge` / `_verifyNonEvmBtc`). Runs after quote/signature/`calldataHash`/slippage checks. The sketch below is the original plan; the implementation follows it with the refinements in [Resolved Decisions](#resolved-decisions).

After existing quote/signature/`calldataHash` checks:

1. **Route class** — from `terms.destinationChainId` vs `block.chainid` and `outputRecipient` shape (no hardcoded chain IDs).
2. **Destination chain:**
   - **Cross-chain:** decode from `BridgeData` @ `+0xE0`; require `== terms.destinationChainId`.
   - **Same-chain:** require `terms.destinationChainId == block.chainid` (nothing to read from calldata).
3. **Recipient:**
   - **Same-chain EVM:** GenericSwap `_receiver` @ `+0x60` == `toEvmAddress(terms.outputRecipient)`; optional last-swap `receivingAssetId` vs `terms.outputAssetId`.
   - **Cross-chain EVM:** `BridgeData.receiver` @ `+0xA0` == `toEvmAddress(terms.outputRecipient)`.
   - **Cross-chain non-EVM:** selector-specific `nonEVMReceiver` == `terms.outputRecipient`.
4. **Optional:** `BridgeData.bridge` string or selector vs `terms.allowedBridgeMask`.
5. **Reject** Relay for non-EVM; reject selectors not in allowlist.
6. **`afterHook`:** unchanged — `shouldVerifyOutputOnChain(terms.destinationChainId, …)` gates balance check; works on any chain where enforcer is deployed.

Redeploy enforcer after implementation (CREATE2 → new address).

---

## CLI / Quote Fetching Changes

| Change | File | Status |
|---|---|---|
| `RouteKind` enum mirror (TS) | `scripts/lifi-swap/src/types.ts` | Done |
| `encodeQuoteArgs(routeKind, quote, signature)` prepends enum | `scripts/lifi-swap/src/quote.ts` | Done |
| `deriveRouteKind(quote, executionChainId)` | `scripts/lifi-swap/src/quote.ts` | Done |
| Wire `deriveRouteKind` into `execute.ts` | `scripts/lifi-swap/src/commands/execute.ts` | Done |
| Encode non-EVM recipient | `scripts/lifi-swap/src/terms.ts` (`encodeLiFiNonEvmBytes32`) | Existing |
| Cross-chain ETH terms | `outputAssetId = bytes32(0)`, `destinationChainId = <dest chain>`, EVM `outputRecipient` | Existing |
| Same-chain native terms | `outputAssetId = bytes32(0)`, `destinationChainId = block.chainid`, EVM `outputRecipient` | Existing |
| Add `allowBridges` to quote requests | `scripts/lifi-swap/src/lifi.ts` | Not required (derive handles routing) |

**`deriveRouteKind` rules:** SameChain if `toChain == fromChain`; non-EVM if `toToken.address` doesn't start with `0x` or `toChainId >= 2_000_000_000_000_00` → NearBtc/LayerSwapBtc by `tool` (`near`/`layerswap`), throw for unsupported (e.g. Relay); else EvmBridge. Per repo rules, the CLI never adds client-side aborts that duplicate enforcer checks — `deriveRouteKind` only picks the encoding shape; the relayer still proceeds and the enforcer is the gate.

---

## Relevant Files

### delegation-framework

| File | Role |
|---|---|
| `src/enforcers/LiFiSwapEnforcer.sol` | Add `_verifyCalldataMatchesTerms` in `beforeHook` |
| `src/libraries/LiFiSwapQuoteLib.sol` | Terms/quote types; possible `allowedBridgeMask` extension |
| `test/enforcers/LiFiSwapEnforcer.t.sol` | Tests per route class + saved quote calldata |
| `scripts/lifi-swap/src/lifi.ts` | `allowBridges`, quote fetch |
| `scripts/lifi-swap/src/terms.ts` | `encodeLiFiNonEvmBytes32`, `addressToBytes32` |
| `scripts/lifi-swap/NEAR.json` | Near Intents BTC quote sample |
| `scripts/lifi-swap/LAYERSWAP.JSON` | LayerSwap BTC quote sample |
| `scripts/lifi-swap/RELAY.json` | Relay BTC quote (negative test) |
| `scripts/lifi-swap/ETHSWAP.json` | Base USDC → Ethereum ETH (AcrossV4Swap) |
| `scripts/lifi-swap/POLYGONSAMECHAIN.json` | Polygon USDC → native POL (GenericSwapV3, no bridge) |
| `documents/Deployments.md` | Enforcer address per chain after redeploy |

### lifinance/contracts

| File | Role |
|---|---|
| `src/Facets/GenericSwapFacetV3.sol` | Same-chain swaps (`swapTokensMultipleV3*` / `swapTokensSingleV3*`) |
| `src/Interfaces/ILiFi.sol` | `BridgeData` struct |
| `src/Facets/CalldataVerificationFacet.sol` | `extractMainParameters`, `extractNonEVMAddress` |
| `src/Facets/NEARIntentsFacet.sol` | `NEARIntentsData.nonEVMReceiver` (1st field) |
| `src/Facets/LayerSwapFacet.sol` | `LayerSwapData.nonEVMReceiver` (4th field); EIP-712 binds recipient |
| `src/Facets/RelayDepositoryFacet.sol` | No BTC recipient in calldata (explicit warning) |
| `src/Facets/AcrossFacetV4.sol` | Plain Across; EVM receiver == `AcrossV4Data.receiverAddress` |
| `src/Facets/AcrossV4SwapFacet.sol` | Swap API; opaque inner calldata for SpokePool paths |
| `src/Helpers/LiFiData.sol` | `NON_EVM_ADDRESS` sentinel, LiFi chain IDs |
| `test/solidity/Facets/CalldataVerificationFacet.t.sol` | Reference for supported extractors |

---

## Deployed Addresses (example: Base mainnet)

LiFiSwapEnforcer is intended to be deployed on **each supported EVM chain** at the same CREATE2 address where salt allows. Terms pin `lifiDiamond` and `destinationChainId` per delegation — the enforcer bytecode is identical everywhere.

| Contract | Base (8453) |
|---|---|
| LiFiSwapEnforcer | `0x64a9B2277dcDD134e78d30bEe11c3056e8E56ffE` |
| LiFi Diamond | `0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE` |

See `documents/Deployments.md` for other networks.

---

## Resolved Decisions

### Route discriminator: `RouteKind` enum in `_args` (not terms, not quote)

**Final:** A `RouteKind` enum is prepended to the redeemer-supplied `_args` envelope, ahead of `SignedLiFiQuote`:

```
_args = abi.encode(RouteKind, SignedLiFiQuote, signature)
```

- `enum RouteKind { SameChain, EvmBridge, NearBtc, LayerSwapBtc }` lives in `LiFiSwapQuoteLib`.
- **Terms are unchanged** (still 284 bytes; no `allowedBridgeMask`). No terms redeploy.
- **`RouteKind` is NOT part of the signed `hashQuote`** — it is untrusted redeemer-provided data. Security comes from cross-checks:
  - enum ↔ selector (`_isGenericSwapSelector`, Near/LayerSwap selector constants)
  - enum ↔ terms shape (SameChain ⇔ `dest == block.chainid` + clean recipient; EvmBridge ⇔ cross-chain + clean; NearBtc/LayerSwapBtc ⇔ non-clean recipient)
  - enum ↔ `destinationChainId` vs `block.chainid`
- A lying enum cannot pass: every branch re-derives the expected shape from signed terms/calldata and reverts on mismatch (`:route-selector-mismatch`, `:route-recipient-shape-mismatch`, `:route-dest-chain-mismatch`).

### EvmBridge: no selector allowlist; sentinel guard

**Final:** EvmBridge does **not** maintain a per-bridge selector allowlist. It decodes `ILiFi.BridgeData` selector-agnostically (any `startBridge*`/`swapAndStart*` facet using the standard `BridgeData` head layout) and asserts:

- `bridgeData.receiver == toEvmAddress(terms.outputRecipient)`
- `bridgeData.destinationChainId == terms.destinationChainId`
- **`bridgeData.receiver != NON_EVM_ADDRESS`** — closes the edge where a non-EVM sentinel (`0x11f1…11F1`) is a clean 160-bit address and would otherwise pass the EVM-recipient shape check. Revert string: `:non-evm-sentinel-receiver`.

### Relay / unsupported non-EVM: hard revert

**Final:** `beforeHook` hard-reverts with `:unsupported-route` for any `RouteKind` it does not recognize and for Relay (no on-chain BTC recipient). No silent fallthrough.

### Decode approach: inline custom offset reads

**Final:** No `CalldataVerificationFacet` staticcall. The enforcer reads offsets inline via `_readWord` (bounds-checked, subtraction-based guard to avoid overflow on attacker-controlled offsets). `bytes calldata` head slots are `0x24` (no source swaps) / `0x44` (with source swaps) — **not** the `0x44`/`0x64` of `bytes memory` (which has a 0x20 length prefix). Bridge-specific struct body = `0x04 + structOff`; Near `nonEVMReceiver` @ struct `+0x00`, LayerSwap @ struct `+0x60`.

### Verification ordering

`_verifyCalldataMatchesTerms` runs **after** `_validateQuoteMatchesTerms` and slippage, so metadata mismatches (e.g. `:invalid-destination-chain`) surface before calldata-decode mismatches.

---

## Open Items

- [x] Implement `_verifyCalldataMatchesTerms` in `LiFiSwapEnforcer.sol`
- [x] Decide: terms `allowedBridgeMask` vs selector-only allowlist → **neither; `RouteKind` enum in `_args`, no terms change**
- [x] Unit tests using hex calldata from JSON quote fixtures (SameChain, EvmBridge, NearBtc, LayerSwapBtc, Relay-revert, lying-enum cross-checks) — 34 enforcer tests pass
- [x] Audit enforcer for hardcoded chain/token/diamond constants in hooks; none present (chain-agnostic via `block.chainid` + signed terms)
- [ ] Add `allowBridges` to CLI quote path (not required for correctness; `deriveRouteKind` handles routing without it)
- [ ] Redeploy + update `Deployments.md`, `constants.ts`, integration docs — **bytecode changed → CREATE2 address will change; redeploy is a separate follow-up**
- [ ] Optional: `POST /v1/advanced/routes` for debugging Near quote failures
