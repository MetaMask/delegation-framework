# LiFi Swap CLI

Staged CLI for **LiFiSwapEnforcer** delegations on Base mainnet: create a signed delegation, save it locally, then execute swaps repeatedly against the same grant to test periodic budgets.

## Prerequisites

- Node.js 20+ with `npm install`
- Copy [`.env.example`](./.env.example) to `.env` in this directory and set `PRIVATE_KEY` and `BASE_RPC_URL` (RPC must match the `--input-chain` you use on create)
- Base ETH for gas (via relayer fee token) and input ERC-20 balance (e.g. USDC)
- Deployed contracts on Base:
  - `DelegationManager`: `0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3`
  - `LiFiSwapEnforcer`: `0xD0e70cd777a527fB798e5EcA8800c5E3588041d4`
  - `ChainlinkPriceRuleEnforcer`: `0x4dAEbF9C5813EFF2606acD41BA25e57841e7cb75`

## Setup

```bash
cd scripts/lifi-swap
npm install
cp .env.example .env
# edit .env — set PRIVATE_KEY and BASE_RPC_URL (full URL with provider key)
```

## LiFi API discovery

Read-only helpers for exploring the [Li.FI Quote API](https://docs.li.fi/). No `PRIVATE_KEY` required. Optionally set `LIFI_API_KEY` in `.env` for higher rate limits.

```bash
# Supported chains
npm run lifi -- chains
npm run lifi -- chains --chain-types EVM,SVM,UTXO --json

# Tokens on a chain (resolves chain by name, key, or id)
npm run lifi -- tokens --chain Base
npm run lifi -- tokens --chain Base --symbol USDC
npm run lifi -- tokens --chain Base --tags stablecoin

# Bridges and exchanges
npm run lifi -- tools
npm run lifi -- tools --chains base,eth

# Possible routes between chains
npm run lifi -- connections --from-chain Base --to-chain Bitcoin --from-token USDC

# Arc mainnet quote (uses LIFI_QUOTE_*_CHAIN and PRIVATE_KEY from .env)
npm run quote:arc -- --amount 1000000

# Quote with human-readable chain/token names (amount in token atoms)
npm run lifi -- quote \
  --input-chain Arc \
  --input-token USDC \
  --output-chain Arc \
  --output-token EURC \
  --amount 1000000

npm run lifi -- quote \
  --input-chain Base \
  --input-token USDC \
  --input-address 0x4a0C5B7c1262d5D76B26235F7D96E86C24de3532 \
  --output-chain Bitcoin \
  --output-token BTC \
  --output-address bc1q9vpk73hpnvrv6mdsxrsc0as03ycywjr0qkja7h \
  --amount 10000000 \
  --allow-bridges near,layerswap \
  --calldata

npm run lifi -- quote \
  --input-chain Base \
  --input-token USDC \
  --input-address 0x9fEad8B19C044C2f404dac38B925Ea16ADaa2954 \
  --output-chain Ethereum \
  --output-token Eth \
  --output-address 0x9fEad8B19C044C2f404dac38B925Ea16ADaa2954 \
  --amount 10000000 

npm run lifi -- quote \
  --input-chain Base \
  --input-token USDC \
  --input-address 0x4a0C5B7c1262d5D76B26235F7D96E86C24de3532 \
  --output-chain Solana \
  --output-token Sol \
  --output-address HoJQwEF9VZVQREpwACNjMiQEkvZDwWYPHGuAdAHkX6dw \
  --amount 10000000
```

Add `--json` to any command for raw API output. Quote also supports `--slippage`, `--order FASTEST|CHEAPEST`, `--allow-bridges`, `--deny-bridges` (comma-separated bridge keys from `lifi tools`), `--calldata` (print full transaction hex), and `--verbose`.

When no route is available, quote errors print a concise summary (route, filters, top filtered/failed reasons) instead of raw LiFi JSON. Use `--raw-errors` to dump the full API error payload for debugging.

## Staged workflow

### Stage 1 — Create and save a delegation

Route flags use the same chain/token names as `npm run lifi -- quote` (no contract addresses in `.env`):

```bash
# Same-chain Base USDC → WETH
npm run delegation -- create \
  --id usdc-weth-2min \
  --input-chain Base \
  --input-token USDC \
  --output-chain Base \
  --output-token ETH \
  --period-amount 1000000 \
  --period-duration 120

# Cross-chain Base USDC → Ethereum ETH
npm run delegation -- create \
  --id usdc-eth-bridge-2min \
  --input-chain Base \
  --input-token USDC \
  --output-chain Ethereum \
  --output-token Eth \
  --output-address 0x9fEad8B19C044C2f404dac38B925Ea16ADaa2954 \
  --period-amount 1000000 \
  --period-duration 120

npm run delegation -- create \
  --id usdc-btc-bridge-2min \
  --input-chain Base \
  --input-token USDC \
  --output-chain Bitcoin \
  --output-token btc \
  --output-address bc1q9vpk73hpnvrv6mdsxrsc0as03ycywjr0qkja7h \
  --period-amount 10000000 \
  --period-duration 120

npm run delegation -- list
npm run delegation -- show usdc-weth-daily
npm run delegation -- delete usdc-weth-daily   # or: delete --all
```

Legacy: omit route flags and set `LIFI_FROM_TOKEN`, `LIFI_TO_TOKEN`, `LIFI_TO_CHAIN` in `.env`.

Saved files live in `delegations/` (gitignored).

### Setup — Approve LiFi diamond (once per delegation)

```bash
npm run approve -- usdc-weth-daily
```

### Stage 2 — Execute swaps

Use `delegation show` to inspect the on-chain budget before running swaps.

```bash
# First swap: 0.5 USDC (within 1 USDC / period budget)
npm run execute -- usdc-weth-daily --amount 500000

npm run delegation -- show usdc-weth-daily

# Over budget: CLI warns locally, then submits to relayer — expect
# relayer estimate or on-chain revert (LiFiSwapEnforcer:period-amount-exceeded)
npm run execute -- usdc-weth-daily --amount 600000

# Within remaining budget
npm run execute -- usdc-weth-daily --amount 500000
```

Dry-run (quote + relayer estimate, no send):

```bash
npm run execute -- usdc-weth-daily --amount 5000000 --dry-run
```

Before relayer submission, `execute` prints the **LiFi quote request** (API parameters) and a **high-level quote summary** (route, amounts, tool, steps) — same style as `lifi quote` — immediately after fetch, even if later validation (slippage, diamond, etc.) fails. Use `--verbose` for transaction-request details (`to`, value, calldata length).

Optional `--allow-bridges` / `--deny-bridges` (comma-separated bridge keys from `lifi tools`) limit which LiFi bridges are used at **execute time only** — not stored in delegation terms; no recreate needed when changing filters.

### Enforcer negative testing (spoof flags)

Optional flags override **only** the LiFi quote API parameters (`toChain`, `toToken`, `toAddress`). Signed quote metadata still comes from saved delegation **terms**, so calldata from the spoofed quote should fail `LiFiSwapEnforcer` on-chain verification. The CLI warns and still reaches the relayer (no local abort).

| Flag | Effect |
|------|--------|
| `--spoof-output-chain <name\|id>` | Wrong destination chain in LiFi quote fetch |
| `--spoof-output-address <addr>` | Wrong recipient in LiFi quote fetch |
| `--spoof-output-token <symbol\|addr>` | Wrong output token (required when chain spoof changes token address unless `metadata.outputSymbol` is saved) |

**Wrong recipient (same-chain delegation):**

```bash
npm run execute -- usdc-weth-2min --dry-run \
  --spoof-output-address 0x0000000000000000000000000000000000000001
```

Expected enforcer error: `LiFiSwapEnforcer:calldata-recipient-mismatch`

**Wrong destination chain:**

```bash
npm run execute -- usdc-weth-2min --dry-run \
  --spoof-output-chain Ethereum --spoof-output-token Eth
```

Expected: `LiFiSwapEnforcer:route-dest-chain-mismatch` and/or `LiFiSwapEnforcer:calldata-dest-chain-mismatch`

## How it works

1. **`delegation create`** resolves `--input-chain` / `--output-chain` / tokens via the Li.FI chains and tokens API (no live quote), pins `lifiDiamond` from the source chain's `diamondAddress` (or `--lifi-diamond` / `LIFI_DIAMOND`), calls `relayer_getCapabilities` on the source chain, builds 284-byte enforcer terms, signs delegations to the relayer **`targetAddress`**, and saves `chainId` + `relayerTargetAddress` in the local file.
2. **`approve` / `execute`** re-fetch capabilities and **fail fast** if `targetAddress` changed since create (recreate with `--force`). They use **`relayer_estimate7710Transaction`** (with `authorizationList` when needed) and **`relayer_getFeeData`** for the fee floor before send.
3. **`execute`** loads the saved delegation, fetches a fresh LiFi quote, signs an EIP-191 quote with the same `PRIVATE_KEY` (`terms.quoteSigner`), patches caveat args, and submits via `relayer_send7710Transaction` with the estimate `context` price lock.
4. **Periodic budget** is tracked on-chain per `delegationHash`; reuse the same saved file across executions.

### Relayer targetAddress

The redemption wallet address comes from the 1Shot relayer at create time. If the relayer rotates it, `approve` and `execute` will error with instructions to recreate:

```bash
npm run delegation -- create --id usdc-weth-daily --force
```

`RELAYER_URL` in `.env` is only the JSON-RPC endpoint override, not the delegate address.

### Fee estimation

`approve` and `execute` use estimate-first submission: mock fee ≥ `minFee` from `relayer_getFeeData`, simulate via `relayer_estimate7710Transaction`, adjust fee from `requiredPaymentAmount` if needed, then send with signed `context`. Use `--dry-run` to see `gasUsed` and `requiredPaymentAmount` without submitting.

## Gas estimate PoC (RPC state override vs relayer)

Experimental command to test **pre-grant gas estimation**: simulate `DelegationManager.redeemDelegations` on your RPC with **bogus delegation signatures** and a **DelegatorEstimateShim** injected at the user delegator via [Geth state overrides](https://geth.ethereum.org/docs/interacting-with-geth/rpc/objects#state-override-set), then compare `eth_estimateGas` to **`relayer_estimate7710Transaction`** (valid signatures, same fee+swap bundle).

```bash
npm run estimate-gas -- usdc-eth-bridge-2min --amount 1000000
```

Requires `PRIVATE_KEY`, `BASE_RPC_URL` (must support `stateOverride` on `eth_call` / `eth_estimateGas`), and `RELAYER_URL`. Uses the same LiFi quote + quote-signer flow as `execute`. Overrides are passed as viem’s **`StateOverride` array** (`{ address, code?, stateDiff: [{ slot, value }] }`), not a raw Geth JSON map.

**What it prints**

- **Path A:** relayer `gasUsed` and `requiredPaymentAmount` (valid swap + fee delegations).
- **Control:** `eth_call` with bogus sig and ERC-20 overrides only → expected signature revert.
- **Path B:** `eth_call` + `eth_estimateGas` with delegator shim + bogus sig → should succeed.
- **Comparison:** relayer gas vs RPC gas and delta (%).

Flags: `--skip-control`, `--skip-relayer`, `--skip-rpc`, `--skip-rpc-debug`, `--fee-atoms`, plus the same bridge/chainlink flags as `execute`.

When the full PoC `eth_call` fails, the CLI runs **fee-only** and **swap-only** batch simulations (unless `--skip-rpc-debug`) and decodes revert data (`Error(string)`, `Panic`, delegation-manager / shim custom errors) to pinpoint which leg failed.

**Shim bytecode:** [`src/poc/DelegatorEstimateShim.sol`](../../src/poc/DelegatorEstimateShim.sol). After editing, run `forge build` and `node scripts/lifi-swap/scripts/export-shim-bytecode.mjs` to refresh [`src/poc/delegatorEstimateShimBytecode.ts`](./src/poc/delegatorEstimateShimBytecode.ts). The export script patches the `delegationManager` immutable via Foundry `immutableReferences` (do not global-replace zero addresses in bytecode).

**Caveats:** RPC gas simulates direct `redeemDelegations`; the relayer includes its own submission/wrapper path. The shim’s `executeFromExecutor` is minimal—not byte-identical to `EIP7702StatelessDeleGator`. Use this to measure correlation, not as a production fee API.

## Chainlink price-gated swaps

Stack [`ChainlinkPriceRuleEnforcer`](../../src/enforcers/ChainlinkPriceRuleEnforcer.sol) with LiFi for buy-the-dip, take-profit, and absolute price triggers. Use a **separate create command** — plain `delegation create` stays LiFi-only.

Deployed on Base mainnet: `0x4dAEbF9C5813EFF2606acD41BA25e57841e7cb75`

### Env (feed + staleness only)

Set in `.env` (see [`.env.example`](./.env.example)):

- `CHAINLINK_PRICE_FEED` — default Base ETH/USD
- `CHAINLINK_MAX_STALE_SECONDS` — default 120
- `CHAINLINK_MIN_GAP_SECONDS` — default 300

Rule kind, window, threshold, and trigger price are **CLI flags**, not env vars.

### Create price-gated delegation

```bash
# DIP — buy the dip (10% drop vs 24h high)
npm run delegation -- create-chainlink \
  --id dip-usdc-weth \
  --rule-kind dip \
  --window-seconds 86400 \
  --threshold-bps 1000 \
  --trigger-price 0 \
  --period-amount 1000000 \
  --period-duration 86400

# RISE — take profit (10% rise vs 12h low)
npm run delegation -- create-chainlink \
  --id rise-weth-usdc-1000bps-12h \
  --rule-kind rise \
  --window-seconds 12400 \
  --threshold-bps 1000 \
  --trigger-price 0 \
  --period-amount 1000000

# ABSOLUTE_GTE — sell when ETH/USD >= $4000 (8-decimal feed: 4000e8)
npm run delegation -- create-chainlink \
  --id tp-gte \
  --rule-kind absolute_gte \
  --window-seconds 0 \
  --threshold-bps 0 \
  --trigger-price 400000000000

# ABSOLUTE_LTE — buy when ETH/USD <= $3000
npm run delegation -- create-chainlink \
  --id buy-lte \
  --rule-kind absolute_lte \
  --window-seconds 0 \
  --threshold-bps 0 \
  --trigger-price 300000000000
```

### Check price gate (no swap)

```bash
npm run chainlink -- check dip-usdc-weth
npm run chainlink -- check dip-usdc-weth --reference-round-id 12345
```

Output includes round ids: **Current** (latest feed round), **Window newest/oldest** (relative rules — bounds of the valid reference time window), and **Reference** (auto-picked dip/rise round encoded in args).

### Execute

Same as LiFi-only execute; Chainlink args are resolved and patched automatically. **By default, execute always reaches the relayer** — failed Chainlink pre-checks warn locally but still submit so on-chain enforcers are the source of truth.

```bash
npm run approve -- dip-usdc-weth
npm run execute -- dip-usdc-weth --amount 500000 --dry-run
npm run execute -- dip-usdc-weth --amount 500000
```

Execute flags for Chainlink delegations:

- `--reference-round-id <id>` — override reference round (relative rules)
- `--require-chainlink` — abort locally if Chainlink pre-check fails (strict mode)
- `--skip-chainlink` — skip Chainlink resolve/patch (args stay empty; enforcer will revert)

### CLI design principle

This CLI validates **on-chain enforcer behavior** via the relayer. Do not add client-side aborts in `execute` that duplicate enforcer checks (Chainlink, LiFi budget, etc.) — warn and proceed. Use optional `--require-*` flags for strict local gates. `chainlink check` is informational only.

### Testing tips

- Loosen `--threshold-bps` or widen `--window-seconds` for smoke tests
- Use `chainlink check` before first execute to see current vs reference price
- For absolute rules, set `--trigger-price` relative to current feed price at create time

See also: [ChainlinkPriceRuleEnforcer-Wallet-Integration.md](../../ChainlinkPriceRuleEnforcer-Wallet-Integration.md), [ChainlinkPriceRuleEnforcer-App-Integration.md](../../ChainlinkPriceRuleEnforcer-App-Integration.md)

## Cross-chain

### EVM → EVM (e.g. Base USDC → Ethereum ETH)

Use a normal `0x` `--output-address` on the destination chain. Terms encode the recipient as a **padded EVM address** (`bytes32`), matching the enforcer’s `EvmBridge` path.

```bash
npm run delegation -- create \
  --id usdc-eth-bridge-2min \
  --input-chain Base \
  --input-token USDC \
  --output-chain Ethereum \
  --output-token Eth \
  --output-address 0x9fEad8B19C044C2f404dac38B925Ea16ADaa2954 \
  --period-amount 1000000 \
  --period-duration 120

npm run approve -- usdc-eth-bridge-2min
npm run execute -- usdc-eth-bridge-2min --amount 1000000 --dry-run
```

If you created an EVM bridge delegation before this encoding fix, **recreate with `--force`** so `terms.outputRecipient` is padded (not the non-EVM string hash).

### Non-EVM (Solana, Bitcoin)

Use route flags plus `--output-address` for the destination recipient (bech32, Solana pubkey, etc.).

**Bitcoin (bc1q P2WPKH):** bech32 addresses are encoded to LiFi’s binary `bytes32` (witness program as 5-bit words), **not** keccak256 of the ASCII string. If you created a BTC bridge delegation before this fix, **recreate with `--force`** (e.g. `usdc-btc-bridge-2min`).

```bash
npm run delegation -- create \
  --id usdc-btc-bridge-2min \
  --input-chain Base --input-token USDC \
  --output-chain Bitcoin --output-token BTC \
  --output-address bc1q9vpk73hpnvrv6mdsxrsc0as03ycywjr0qkja7h \
  --period-amount 10000000 --period-duration 120 --force
```

Expected in saved JSON: `terms.outputRecipient` = `0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f` for that bc1q address.

Example create + execute:

```bash
npm run delegation -- create \
  --id usdc-btc \
  --input-chain Base \
  --input-token USDC \
  --output-chain Bitcoin \
  --output-token BTC \
  --output-address bc1q... \
  --period-amount 1000000 \
  --period-duration 86400

npm run execute -- usdc-btc --amount 500000 --dry-run

# Limit to enforcer-supported BTC bridges (Near + LayerSwap; excludes Relay)
npm run execute -- usdc-btc --amount 10000000 \
  --allow-bridges near,layerswap --dry-run

# Test one bridge at a time
npm run execute -- usdc-btc --amount 10000000 --allow-bridges layerswap --dry-run
```

Optional overrides if auto-encoding differs from LiFi quote tooling: `LIFI_OUTPUT_ASSET_ID`, `LIFI_OUTPUT_RECIPIENT_BYTES32` in `.env`.

**Note:** Source-chain `afterHook` does not verify delivery on non-EVM destination chains — monitor bridge status via LiFi tooling.

## Native ETH support

The LiFiSwapEnforcer treats `address(0)` / `bytes32(0)` as a native ETH sentinel. Use token symbols `Eth` / native on the relevant chain via route flags:

```bash
# USDC → native ETH (same-chain Base)
npm run delegation -- create \
  --input-chain Base --input-token USDC \
  --output-chain Base --output-token Eth \
  --period-amount 1000000 --period-duration 1200
```

Native ETH input skips the approve delegation (no ERC-20 approval). Execution must carry `value == inputAmount` when input is native.

## References

- [LiFiSwapEnforcer-App-Integration.md](../../LiFiSwapEnforcer-App-Integration.md)
- [LiFiSwapEnforcer-Wallet-Integration.md](../../LiFiSwapEnforcer-Wallet-Integration.md)
- [public-relayer skill](../../.agents/skills/public-relayer/SKILL.md)
