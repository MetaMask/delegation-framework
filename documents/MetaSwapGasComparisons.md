# MetaSwap gas comparisons

The suite in `test/metaswap-optimized/gas-comparisons/` measures two products: a gasless swap and a limit order. Each product has a production baseline on `DelegationManager`, and the managers below are the versions measured against those baselines.

This doc includes `DirectRouteManager` and `Eip7710DirectRouteManager`. The same measurements without those two are in [MetaSwap gas comparisons, without direct route](./MetaSwapGasComparisonsNoDirectRoute.md).

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

### Where the baselines come from

Each baseline copies the code path below. The links are pinned to the commit I read, so they won't drift when `main` changes.

- **`GaslessExecute`** and **`GaslessFeeTransfer`**: MetaMask mobile, [`delegation-7702-publish.ts`](https://github.com/MetaMask/metamask-mobile/blob/14dfef4a66d835933517f31b38844cc07278cc0d/app/util/transactions/hooks/delegation-7702-publish.ts#L338-L354). Line 339 returns the single execution that `GaslessExecute` uses. Line 354 returns the fee-transfer pair.
- **Caveats** for those delegations (`LimitedCalls`, `Timestamp`, `Redeemer`, `ExactExecution`): MetaMask mobile, [`caveats.ts`](https://github.com/MetaMask/metamask-mobile/blob/14dfef4a66d835933517f31b38844cc07278cc0d/app/util/transactions/caveats.ts#L67), with the exact-execution caveat at [line 109](https://github.com/MetaMask/metamask-mobile/blob/14dfef4a66d835933517f31b38844cc07278cc0d/app/util/transactions/caveats.ts#L109).
- **`LimitOrderBaseline`**: bridge-api, [`limit-order-delegation.policy.ts`](https://github.com/consensys-vertical-apps/va-mmcx-bridge-api/blob/685e036057c09484ef4bc0af9e64be91159a8df3/src/modules/orders/limit/delegation/limit-order-delegation.policy.ts#L170-L251). Lines 170–194 are the approval, and lines 196–251 are the swap.
- **Redeemer list** (sponsor signers): bridge-api, [`delegation-framework.constants.ts`](https://github.com/consensys-vertical-apps/va-mmcx-bridge-api/blob/685e036057c09484ef4bc0af9e64be91159a8df3/src/modules/delegation-framework/delegation-framework.constants.ts#L58).

The bridge-api repo is private, so those links need access to `consensys-vertical-apps/va-mmcx-bridge-api`.

## Solutions

Each of these runs the gasless rows and the limit rows.

| Name                        | Contract                                                | Gasless                                            | Limit                                               |
| --------------------------- | ------------------------------------------------------- | -------------------------------------------------- | --------------------------------------------------- |
| `FinalManager`              | `src/metaswap/final/MetaSwapManager.sol`                | `redeemExactBatch`, full batch in calldata         | Full approve + swap batch in calldata               |
| `DirectRouteManager`        | `src/metaswap/direct-route/MetaSwapManager.sol`         | Same exact batch                                   | Route bytes. The manager rebuilds approve and swap. |
| `Eip7710FinalManager`       | `src/metaswap/eip7710-final/MetaSwapManager.sol`        | `redeemDelegations`, batch in `executionCallDatas` | Same, full batch                                    |
| `Eip7710DirectRouteManager` | `src/metaswap/eip7710-direct-route/MetaSwapManager.sol` | Same EIP-7710 exact path                           | Route bytes, rebuilt on the manager                 |
| `OrderDelegationManager`    | `src/MetaSwapOrderDelegationManager.sol`                | `ExactBatch` intent                                | Flexible settlement terms                           |

Final and direct route are the two packed layouts. Each has a calldata version and an EIP-7710 version. On the gasless path both layouts send the full batch, so Final and direct route measure the same work. The route rebuild applies to limit orders.

## Limit only

| Name                         | File                                  | What it is                                                                                          |
| ---------------------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `FlexibleSettlementEnforcer` | `FlexibleSettlementEnforcerGas.t.sol` | One delegation on `DelegationManager`. `MetaSwapFlexibleSettlementEnforcer` checks the whole order. |

## Measured gas

Re-measured 14 Nov 2026 with `forge test --match-path test/metaswap-optimized/gas-comparisons/*.sol -vv`.

Estimated transaction gas is `21,000 + calldata gas + execution gas`.

### Cold and later

**Cold** is the first fill of that shape on that delegator. The nonce or id word is still zero, and the ERC-20 balance slots this fill writes are still zero. Creating a slot costs more than updating one.

**Later** is another fill of the same shape, in its own transaction, with a new signed permission. A previous fill on the same delegator has already written the storage this fill updates, so those stores cost less. Reads are still cold, because every transaction starts cold.

What that previous fill leaves behind:

- **Nonce.** `FinalManager`, `DirectRouteManager`, `Eip7710FinalManager`, and `Eip7710DirectRouteManager` keep a nonce bitmap per delegator, one word for gasless batches and one for limit orders. The first nonce in a word creates that word. A later nonce on the same delegator only flips another bit in the word, which is cheaper. The later rows measure nonce 1 after another bit in that word is already set.
- **Order id.** `LimitOrderBaseline`, `OrderDelegationManager` limit orders, and `FlexibleSettlementEnforcer` burn an id in a bitmap instead of a nonce. A later fill uses an id in a word that already has another id burned, so that write is cheaper too. The gasless `OrderDelegationManager` path has no nonce and no id, so it does not get this saving.
- **Token balances.** Every version, including the ones with no nonce, leaves the ERC-20 balances it touched nonzero: the input token, the output token, and on gasless fills the fee recipient. Updating a nonzero balance costs less than creating it. That is why a version with no nonce still costs less on a later fill.

### Gasless, against `GaslessExecute`

| Version                     |         Native cold |        Native later |      Token→ETH cold |     Token→ETH later |    Token→token cold |   Token→token later |        Cold average |       Later average |             Overall |
| --------------------------- | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: |
| `GaslessExecute` (baseline) |             288,063 |             248,266 |             325,055 |             283,258 |             347,991 |             286,296 |             320,370 |             272,607 |             296,488 |
| `FinalManager`              | 138,927 (**51.8%**) |  77,229 (**68.9%**) | 169,286 (**47.9%**) | 105,588 (**62.7%**) | 191,926 (**44.8%**) | 108,329 (**62.2%**) | 166,713 (**48.2%**) |  97,049 (**64.6%**) | 131,881 (**56.4%**) |
| `DirectRouteManager`        | 138,939 (**51.8%**) |  77,241 (**68.9%**) | 169,286 (**47.9%**) | 105,588 (**62.7%**) | 191,926 (**44.8%**) | 108,329 (**62.2%**) | 166,717 (**48.2%**) |  97,053 (**64.6%**) | 131,885 (**56.4%**) |
| `Eip7710FinalManager`       | 142,971 (**50.4%**) |  81,274 (**67.3%**) | 173,331 (**46.7%**) | 109,634 (**61.3%**) | 195,947 (**43.7%**) | 112,351 (**60.8%**) | 170,750 (**46.9%**) | 101,086 (**63.1%**) | 135,918 (**55.0%**) |
| `Eip7710DirectRouteManager` | 142,971 (**50.4%**) |  81,274 (**67.3%**) | 173,331 (**46.7%**) | 109,634 (**61.3%**) | 195,959 (**43.7%**) | 112,363 (**60.8%**) | 170,754 (**46.9%**) | 101,090 (**63.1%**) | 135,922 (**55.0%**) |
| `OrderDelegationManager`    | 151,999 (**47.2%**) | 112,201 (**54.8%**) | 182,389 (**43.9%**) | 140,591 (**50.4%**) | 205,005 (**41.1%**) | 143,308 (**49.9%**) | 179,798 (**44.1%**) | 132,033 (**51.7%**) | 155,916 (**47.9%**) |

### Limit orders, against `LimitOrderBaseline`

| Version                         |         Native cold |        Native later |      Token→ETH cold |     Token→ETH later |    Token→token cold |   Token→token later |        Cold average |       Later average |             Overall |
| ------------------------------- | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: |
| `LimitOrderBaseline` (baseline) |             379,893 |             355,497 |             623,087 |             576,795 |             626,787 |             580,497 |             543,256 |             504,263 |             523,759 |
| `DirectRouteManager`            | 115,699 (**69.5%**) |  73,900 (**79.2%**) | 142,078 (**77.2%**) |  98,279 (**83.0%**) | 166,671 (**73.4%**) | 102,972 (**82.3%**) | 141,483 (**73.4%**) |  91,717 (**81.5%**) | 116,600 (**77.4%**) |
| `Eip7710DirectRouteManager`     | 119,738 (**68.5%**) |  77,939 (**78.1%**) | 146,129 (**76.5%**) | 102,330 (**82.3%**) | 170,710 (**72.8%**) | 107,011 (**81.6%**) | 145,526 (**72.6%**) |  95,760 (**80.6%**) | 120,643 (**76.6%**) |
| `FinalManager`                  | 119,666 (**68.5%**) |  77,867 (**78.1%**) | 149,870 (**75.9%**) | 106,073 (**81.6%**) | 174,464 (**72.2%**) | 110,767 (**80.9%**) | 148,000 (**72.2%**) |  98,236 (**80.2%**) | 123,118 (**76.2%**) |
| `Eip7710FinalManager`           | 123,666 (**67.4%**) |  81,868 (**77.0%**) | 153,881 (**75.3%**) | 110,083 (**80.9%**) | 178,463 (**71.5%**) | 114,767 (**80.2%**) | 152,003 (**71.4%**) | 102,239 (**79.4%**) | 127,121 (**75.4%**) |
| `OrderDelegationManager`        | 155,385 (**59.1%**) | 113,587 (**68.0%**) | 185,671 (**70.2%**) | 141,874 (**75.4%**) | 210,265 (**66.5%**) | 146,570 (**74.8%**) | 183,774 (**65.3%**) | 134,010 (**72.7%**) | 158,892 (**69.0%**) |
| `FlexibleSettlementEnforcer`    | 180,775 (**52.4%**) | 156,379 (**56.0%**) | 231,157 (**62.9%**) | 184,860 (**68.0%**) | 235,861 (**62.4%**) | 189,565 (**67.3%**) | 215,931 (**59.2%**) | 176,935 (**63.8%**) | 196,433 (**61.5%**) |
