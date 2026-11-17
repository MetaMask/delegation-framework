# MetaSwap Gas Frontier

Benchmark beyond `MetaSwapManager (final)`. Metric: estimated tx = `21_000 + calldata + execution`.

Hard constraints: off-chain EIP-712, one-use nonce, redeem entrypoints, `executeFromExecutor`. Redeemers + MetaSwap stay in **signed calldata** (not immutable, not admin storage). Exact and limit use **separate** nonce bitmaps (same as Final).

**Discarded after measurement** (numbers + rationale): [`MetaSwapGasExperiments.md`](MetaSwapGasExperiments.md). Ladder increments live inside Final; SlimLimit / TrustedSettle / Multi / etc. deleted.

## Measured keepers

| Variant                        | ERC20→ERC20 est. | Notes                                                |
| ------------------------------ | ---------------: | ---------------------------------------------------- |
| Final (1-redeemer, warm)       |       **91,601** | LeverProbe batch-in-calldata                         |
| DirectRoute (1-redeemer, warm) |       **85,996** | Same signed fields; route bytes → **−5,605 (~6.1%)** |

Lever probes: `test/metaswap-optimized/gas/LeverProbe.t.sol`.

## Code map

| Path                                                | Role                             |
| --------------------------------------------------- | -------------------------------- |
| `src/metaswap/final/MetaSwapManager.sol`            | Final combined manager           |
| `src/metaswap/direct-route/MetaSwapManager.sol`     | Route rebuild candidate          |
| `src/metaswap/direct-route/RouteRebuildLib.sol`     | `abi.encode(Execution[])` body   |
| `test/metaswap-optimized/gas/FrontierGas.t.sol`     | Cold matrix                      |
| `test/metaswap-optimized/gas/LeverProbe.t.sol`      | Rebuild / field-drop deltas      |
