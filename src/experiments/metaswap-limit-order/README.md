# MetaSwap one-shot limit orders

This experiment implements the same ERC-20 limit-order settlement through two delegation paths:

1. The canonical `DelegationManager` plus `MetaSwapLimitOrderEnforcer`.
2. The specialized `MetaSwapLimitOrderManager`.

Both paths execute the same batch from the maker account:

```text
tokenIn.transfer(adapter, exactAmountIn)
adapter.swap(tokenIn, tokenOut, exactAmountIn, minAmountOut, liveApiQuote)
```

The backend chooses a fresh route only when the off-chain price condition is met. The maker's signed delegation
does not trust that decision: it independently binds the adapter, token pair, exact input, minimum actual output,
time window, executor, and one-shot replay policy.

## Why the adapter is the security boundary

`MetaSwapLimitOrderAdapter`:

- accepts no maker allowance and pulls nothing from the maker;
- can spend only the exact amount already transferred in the delegated batch;
- calls one immutable MetaSwap contract;
- requires an API signature bound to the chain, adapter, pair, exact input, minimum output, route, and expiry;
- requires MetaSwap to consume the exact input and leave no allowance;
- measures the actual `tokenOut` balance increase instead of trusting quote fields or return data;
- sends only that new output to `msg.sender`, which is the maker account executing the delegated batch;
- reverts the complete batch if any invariant fails.

API quotes are intentionally reusable. They grant no account authority and cannot move funds without a valid,
unused maker delegation. Avoiding a quote-replay storage write also saves gas.

The prototype supports standard ERC-20 tokens only. Fee-on-transfer, rebasing, callback, and malicious tokens are
outside its supported asset profile.

## Option comparison

### Canonical manager plus enforcer

Recommended default.

- Keeps the existing manager, EIP-712 domain, cancellation flow, delegation chains, and caveat composition.
- Adds one external enforcer call and stores one-shot state in the enforcer.
- Lowest integration and audit surface.

### Specialized manager

Use only when execution volume makes the measured savings worth a separate manager/account integration.

- Keeps the standard `redeemDelegations(bytes[],ModeCode[],bytes[])` entry point.
- Calls the maker's `executeFromExecutor`.
- Supports EOA and ERC-1271 delegators, cancellation, pausing, private executors, and `ANY_DELEGATE`.
- Accepts only one root delegation, one manager-profile caveat, and one transfer-plus-swap batch.
- Does not support delegation chains or arbitrary caveat composition.

### Rejected alternatives

- Direct maker approval to MetaSwap: cheaper topology, but it introduces allowance state at the maker and gives the
  routing contract direct pull authority. The transfer-to-adapter batch has a smaller failure surface.
- Adapter-internal delegation redemption: adds nested manager calls and delegation decoding without strengthening
  the signed bounds.
- Exact-calldata enforcer: good if the route is known when the maker signs, but it cannot support a route selected
  later when the backend observes the target price.
- On-chain oracle condition: unnecessary for this design. The minimum actual output is the enforceable price
  condition; the backend's price check is only execution timing.

## Gas result

Run:

```bash
forge test --isolate --match-contract MetaSwapLimitOrderComparisonTest -vv
```

Measured on August 24, 2026 with the same maker account implementation, adapter, mock MetaSwap settlement,
execution bytes, quote, and cold-state setup:

- Canonical manager + enforcer: `254,729` execution gas, `291,185` estimated transaction gas.
- Specialized manager: `237,682` execution gas, `274,162` estimated transaction gas.
- Specialized saving: `17,047` execution gas (`6.7%`) and `17,023` estimated transaction gas (`5.8%`).
- Both calls: `2,340` calldata bytes.

The specialized manager saves less than 6% of estimated transaction gas in this end-to-end path. Start with the
canonical manager plus enforcer unless that saving materially exceeds the operational cost of a second manager.

## Files

- `MetaSwapLimitOrderAdapter.sol`: route attestation and settlement invariants.
- `MetaSwapLimitOrderLib.sol`: shared signed-term and execution validation.
- `MetaSwapLimitOrderEnforcer.sol`: canonical manager integration.
- `MetaSwapLimitOrderManager.sol`: specialized manager experiment.
- `test/experiments/metaswap-limit-order/MetaSwapLimitOrderComparison.t.sol`: security and gas comparison.
