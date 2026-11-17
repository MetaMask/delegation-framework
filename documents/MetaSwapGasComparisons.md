# MetaSwap gas comparisons

The suite in `test/metaswap-optimized/gas-comparisons/` measures two products: a gasless swap and a limit order. Each product has a production baseline on `DelegationManager`, and the managers below are the versions measured against those baselines.

This doc includes `DirectRouteManager` and `Eip7710DirectRouteManager`. The same measurements without those two are in [MetaSwap gas comparisons, without direct route](./MetaSwapGasComparisonsNoDirectRoute.md).

`GasComparisonFixture.t.sol` and `PackedManagerGas.t.sol` are shared test harnesses, not extra versions.

## Baselines

These redeem through `DelegationManager` with the production caveats.

| Name                 | File                          | Product      | What it signs                                                                                                          |
| -------------------- | ----------------------------- | ------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `GaslessExecute`     | `GaslessExecuteGas.t.sol`     | Gasless swap | One root, single mode. `ExactExecution` of `user.execute(batch)`. The fee stays inside the swap.                       |
| `GaslessFeeTransfer` | `GaslessFeeTransferGas.t.sol` | Gasless swap | One root, batch mode. `ExactExecutionBatch` of `[user.execute(swap), feeToken.transfer]`. The fee is its own transfer. |
| `LimitOrderBaseline` | `LimitOrderBaselineGas.t.sol` | Limit order  | One root per leg. The approval is `ExactExecution` plus `LimitedCalls(1)`. The swap uses the bridge-api caveat set.    |

`GaslessExecute` is the gasless baseline. It is the signed MetaSwap gasless swap: one `user.execute` call, with the fee inside the swap. `GaslessFeeTransfer` is a real wallet path too, the generic relay that pays the gas station with its own transfer. It is kept so that path stays measured, and it is not the baseline the managers are compared with. On this run it costs 6.4% more than `GaslessExecute` on average.

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

### Cold and later

**Cold** is the first fill of that shape on that delegator. It is its own transaction. The nonce or id word is still zero, and the user's output-token balance is still zero. The router already holds the input token, and the fee wallet already holds both tokens. Creating a slot costs more than updating one.

**Later** is the second fill of the same shape, sent as the next transaction, with a new signature. The first fill has already landed, so the slots it created are updated instead of created. Reads are still cold, because every transaction starts cold.

What the first fill leaves behind:

- **Nonce.** `FinalManager`, `DirectRouteManager`, `Eip7710FinalManager`, and `Eip7710DirectRouteManager` keep a nonce bitmap per delegator, one word for gasless batches and one for limit orders. The cold fill uses nonce 1 and creates that word. The later fill uses nonce 2, so it only flips another bit in the word.
- **Order id.** `LimitOrderBaseline`, `OrderDelegationManager` limit orders, and `FlexibleSettlementEnforcer` burn an id in a bitmap instead of a nonce. The cold fill burns id 1. The later fill burns id 2 in that same word. The gasless `OrderDelegationManager` path has no nonce and no id. Its later fill is a new delegation, and the only saving is the token balances.
- **Token balances.** The router and the fee wallet already hold their tokens, so those writes cost the same on both fills. The user's output-token balance starts at zero. Every version leaves it nonzero, and updating it costs less than creating it. That is why a version with no nonce still costs less on a later fill. A native output has no output-token balance, so that saving is not there.

Some writes never get cheaper. `LimitedCallsEnforcer` keys its counter by delegation hash, and `OrderDelegationManager` disables each delegation hash after use. Every fill signs a new delegation, so those writes create a new slot on the later fill too.

### Gasless, against `GaslessExecute`

| Version                     |         Native cold |        Native later |      Token→ETH cold |     Token→ETH later |    Token→token cold |   Token→token later |        Cold average |       Later average |             Overall |
| --------------------------- | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: |
| `GaslessExecute` (baseline) |             293,650 |             276,550 |             292,469 |             292,457 |             319,881 |             302,781 |             302,000 |             290,596 |             296,298 |
| `FinalManager`              | 136,140 (**53.6%**) | 101,940 (**63.1%**) | 128,928 (**55.9%**) | 111,828 (**61.8%**) | 156,056 (**51.2%**) | 121,856 (**59.8%**) | 140,375 (**53.6%**) | 111,875 (**61.6%**) | 126,125 (**57.6%**) |
| `DirectRouteManager`        | 136,140 (**53.6%**) | 101,940 (**63.1%**) | 128,916 (**55.9%**) | 111,816 (**61.8%**) | 156,056 (**51.2%**) | 121,856 (**59.8%**) | 140,371 (**53.6%**) | 111,871 (**61.6%**) | 126,121 (**57.6%**) |
| `Eip7710FinalManager`       | 139,316 (**52.6%**) | 105,116 (**62.0%**) | 132,104 (**54.8%**) | 114,992 (**60.7%**) | 159,232 (**50.2%**) | 125,008 (**58.7%**) | 143,551 (**52.5%**) | 115,039 (**60.5%**) | 129,295 (**56.5%**) |
| `Eip7710DirectRouteManager` | 139,316 (**52.6%**) | 105,080 (**62.0%**) | 132,104 (**54.8%**) | 114,992 (**60.7%**) | 159,220 (**50.2%**) | 125,032 (**58.7%**) | 143,547 (**52.5%**) | 115,035 (**60.5%**) | 129,291 (**56.5%**) |
| `OrderDelegationManager`    | 146,342 (**50.2%**) | 129,242 (**53.3%**) | 139,116 (**52.4%**) | 139,140 (**52.4%**) | 166,256 (**48.0%**) | 149,156 (**50.7%**) | 150,571 (**50.2%**) | 139,179 (**52.1%**) | 144,875 (**51.2%**) |

### Limit orders, against `LimitOrderBaseline`

| Version                         |         Native cold |        Native later |      Token→ETH cold |     Token→ETH later |    Token→token cold |   Token→token later |        Cold average |       Later average |             Overall |
| ------------------------------- | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: | ------------------: |
| `LimitOrderBaseline` (baseline) |             367,621 |             353,321 |             549,272 |             532,172 |             557,360 |             543,060 |             491,418 |             476,184 |             483,801 |
| `DirectRouteManager`            | 129,204 (**64.9%**) |  95,004 (**73.1%**) | 118,596 (**78.4%**) | 101,496 (**80.9%**) | 147,678 (**73.5%**) | 113,478 (**79.1%**) | 131,826 (**72.3%**) | 103,326 (**77.7%**) | 117,576 (**75.0%**) |
| `Eip7710DirectRouteManager`     | 132,393 (**64.0%**) |  98,181 (**72.2%**) | 121,785 (**77.8%**) | 104,685 (**80.3%**) | 150,855 (**72.9%**) | 116,655 (**78.5%**) | 135,011 (**71.6%**) | 106,507 (**77.0%**) | 120,759 (**74.3%**) |
| `FinalManager`                  | 132,142 (**64.1%**) |  97,942 (**72.3%**) | 124,785 (**77.3%**) | 107,685 (**79.8%**) | 153,867 (**72.4%**) | 119,643 (**78.0%**) | 136,931 (**71.2%**) | 108,423 (**76.7%**) | 122,677 (**74.0%**) |
| `Eip7710FinalManager`           | 135,287 (**63.2%**) | 101,087 (**71.4%**) | 127,930 (**76.7%**) | 110,830 (**79.2%**) | 157,000 (**71.8%**) | 122,812 (**77.4%**) | 140,072 (**70.6%**) | 111,576 (**76.0%**) | 125,824 (**73.3%**) |
| `OrderDelegationManager`        | 164,923 (**55.1%**) | 130,711 (**63.0%**) | 157,632 (**71.3%**) | 140,532 (**73.6%**) | 186,725 (**66.5%**) | 152,525 (**71.9%**) | 169,760 (**64.3%**) | 141,256 (**69.5%**) | 155,508 (**66.9%**) |
| `FlexibleSettlementEnforcer`    | 190,447 (**48.2%**) | 156,247 (**55.8%**) | 183,350 (**66.6%**) | 166,250 (**68.8%**) | 212,454 (**61.9%**) | 178,242 (**67.2%**) | 195,417 (**58.9%**) | 166,913 (**63.9%**) | 181,165 (**61.4%**) |
