# MetaSwap gas comparisons

The suite in `test/metaswap-optimized/gas-comparisons/` measures two products: a gasless swap and a limit order. Each product has a production baseline on `DelegationManager`, and the managers below are the versions measured against those baselines.

`GasComparisonFixture.t.sol` and `PackedManagerGas.t.sol` are shared test harnesses, not extra versions. `FeeTransferRouteRebuild` was a temporary benchmark and has been removed.

## Baselines

These redeem through `DelegationManager` with the production caveats.

| Name                 | File                          | Product      | What it signs                                                                                                          |
| -------------------- | ----------------------------- | ------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `GaslessExecute`     | `GaslessExecuteGas.t.sol`     | Gasless swap | One root, single mode. `ExactExecution` of `user.execute(batch)`. The fee stays inside the swap.                       |
| `GaslessFeeTransfer` | `GaslessFeeTransferGas.t.sol` | Gasless swap | One root, batch mode. `ExactExecutionBatch` of `[user.execute(swap), feeToken.transfer]`. The fee is its own transfer. |
| `LimitOrderBaseline` | `LimitOrderBaselineGas.t.sol` | Limit order  | One root per leg. The approval is `ExactExecution` plus `LimitedCalls(1)`. The swap uses the bridge-api caveat set.    |

`GaslessExecute` is the gasless baseline. It is the signed MetaSwap gasless swap: one `user.execute` call, with the fee inside the swap. `GaslessFeeTransfer` is a real wallet path too, the generic relay that pays the gas station with its own transfer. It is kept so that path stays measured, and it is not the baseline the managers are compared with. On this run it costs 6.7% more than `GaslessExecute` on average.

`LimitOrderBaseline` is the limit-order baseline.

## Solutions

Each of these runs the gasless rows and the limit rows.

| Name                        | Contract                                                | Gasless                                            | Limit                                               |
| --------------------------- | ------------------------------------------------------- | -------------------------------------------------- | --------------------------------------------------- |
| `FinalManager`              | `src/metaswap/final/MetaSwapManager.sol`                | `redeemExactBatch`, full batch in calldata         | Full approve + swap batch in calldata               |
| `Eip7710FinalManager`       | `src/metaswap/eip7710-final/MetaSwapManager.sol`        | `redeemDelegations`, batch in `executionCallDatas` | Same, full batch                                    |
| `OrderDelegationManager`    | `src/MetaSwapOrderDelegationManager.sol`                | `ExactBatch` intent                                | Flexible settlement terms                           |

`FinalManager` is the packed layout with the full batch in calldata. `Eip7710FinalManager` is the same layout redeemed through `redeemDelegations`.

## Limit only

| Name                         | File                                  | What it is                                                                                          |
| ---------------------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `FlexibleSettlementEnforcer` | `FlexibleSettlementEnforcerGas.t.sol` | One delegation on `DelegationManager`. `MetaSwapFlexibleSettlementEnforcer` checks the whole order. |

## Measured gas

Re-measured 14 Nov 2026 with `forge test --match-path test/metaswap-optimized/gas-comparisons/*.sol -vv`.

Estimated transaction gas is `21,000 + calldata gas + execution gas`. Cold is the first fill. Later is a second fill after the nonce or id word and the token slots from that shape have been written; the signed permission is new.

Each cell reads `estimated gas (saving vs baseline)`. A saving is `(baseline − version) / baseline`. The three average columns are unweighted means of the cells they cover:

- **Cold average**: the three cold cells (native, token→ETH, token→token).
- **Later average**: the three later cells.
- **Overall**: all six cells. It is the mean of cold and later.

The baseline row has no saving, because it is the reference.

### Gasless, against `GaslessExecute`

| Version | Native cold | Native later | Token→ETH cold | Token→ETH later | Token→token cold | Token→token later | Cold average | Later average | Overall |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `GaslessExecute` (baseline) | 288,063 | 248,266 | 325,055 | 283,258 | 347,991 | 286,296 | 320,370 | 272,607 | 296,488 |
| `FinalManager` | 138,927 (**51.8%**) | 77,229 (**68.9%**) | 169,286 (**47.9%**) | 105,588 (**62.7%**) | 191,926 (**44.8%**) | 108,329 (**62.2%**) | 166,713 (**48.2%**) | 97,049 (**64.6%**) | 131,881 (**56.4%**) |
| `Eip7710FinalManager` | 142,971 (**50.4%**) | 81,274 (**67.3%**) | 173,331 (**46.7%**) | 109,634 (**61.3%**) | 195,947 (**43.7%**) | 112,351 (**60.8%**) | 170,750 (**46.9%**) | 101,086 (**63.1%**) | 135,918 (**55.0%**) |
| `OrderDelegationManager` | 151,999 (**47.2%**) | 112,201 (**54.8%**) | 182,389 (**43.9%**) | 140,591 (**50.4%**) | 205,005 (**41.1%**) | 143,308 (**49.9%**) | 179,798 (**44.1%**) | 132,033 (**51.7%**) | 155,916 (**47.9%**) |

### Limit orders, against `LimitOrderBaseline`

| Version | Native cold | Native later | Token→ETH cold | Token→ETH later | Token→token cold | Token→token later | Cold average | Later average | Overall |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `LimitOrderBaseline` (baseline) | 379,893 | 355,497 | 623,087 | 576,795 | 626,787 | 580,497 | 543,256 | 504,263 | 523,759 |
| `FinalManager` | 119,666 (**68.5%**) | 77,867 (**78.1%**) | 149,870 (**75.9%**) | 106,073 (**81.6%**) | 174,464 (**72.2%**) | 110,767 (**80.9%**) | 148,000 (**72.2%**) | 98,236 (**80.2%**) | 123,118 (**76.2%**) |
| `Eip7710FinalManager` | 123,666 (**67.4%**) | 81,868 (**77.0%**) | 153,881 (**75.3%**) | 110,083 (**80.9%**) | 178,463 (**71.5%**) | 114,767 (**80.2%**) | 152,003 (**71.4%**) | 102,239 (**79.4%**) | 127,121 (**75.4%**) |
| `OrderDelegationManager` | 155,385 (**59.1%**) | 113,587 (**68.0%**) | 185,671 (**70.2%**) | 141,874 (**75.4%**) | 210,265 (**66.5%**) | 146,570 (**74.8%**) | 183,774 (**65.3%**) | 134,010 (**72.7%**) | 158,892 (**69.0%**) |
| `FlexibleSettlementEnforcer` | 180,775 (**52.4%**) | 156,379 (**56.0%**) | 231,157 (**62.9%**) | 184,860 (**68.0%**) | 235,861 (**62.4%**) | 189,565 (**67.3%**) | 215,931 (**59.2%**) | 176,935 (**63.8%**) | 196,433 (**61.5%**) |
