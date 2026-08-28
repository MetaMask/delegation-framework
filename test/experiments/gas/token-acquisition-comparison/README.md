# Token Acquisition Gas Comparison

This benchmark isolates two ways for an adapter to acquire ERC-20 input before executing the same swap:

1. **External batch:** the caller redeems a batch containing `token.transfer(adapter, amount)` followed by
   `adapter.swapPrefunded(...)`.
2. **Internal redemption:** the caller invokes `adapter.swapByDelegation(...)`; the adapter redeems a single
   `token.transfer(adapter, amount)` execution and then runs the same internal swap function.

## Controlled variables

Both paths use:

- the same `DelegationManager`;
- the same MultiSig delegator account and signature type;
- exactly one root delegation;
- zero caveats;
- the same adapter contract;
- the same input and output tokens;
- the same deterministic mock swap protocol;
- the same exact input balance check and `forceApprove`;
- the same protocol pull, output payment, recipient and event.

Caveats are deliberately omitted. Different production policies would measure enforcer design in addition to token
acquisition topology.

## Results

Command:

```bash
forge test --isolate --match-contract TokenAcquisitionGasComparisonTest -vv
```

Results under the repository's current Foundry configuration:

| Metric                     | External batch | Internal redemption | Internal saving |
| -------------------------- | -------------: | ------------------: | --------------: |
| Execution gas              |        195,154 |             193,037 |   2,117 (1.08%) |
| Transaction calldata bytes |          1,412 |                 548 |    864 (61.19%) |
| EIP-2028 calldata gas      |          9,140 |               4,508 |  4,632 (50.68%) |
| Estimated transaction gas  |        225,294 |             218,545 |   6,749 (3.00%) |

Estimated transaction gas is:

```text
21,000 intrinsic gas + EIP-2028 calldata gas + measured execution gas
```

The internal path pays for constructing three one-element arrays and making a nested adapter-to-manager call. The
external path nevertheless costs slightly more execution gas because it asks the manager and delegator account to
decode and execute a two-action batch. Its much larger externally encoded manager calldata makes the total difference
more significant.

## Scope

These results compare acquisition topology, not the current production implementations. They do not include:

- `MetaSwapTransferSwapEnforcer` validation or one-shot storage;
- MetaSwap quote decoding and signature verification;
- Veda's two-delegation chain or P-256 signatures;
- underlying protocol-specific gas;
- L2-specific calldata compression or data-availability pricing.

The benchmark indicates that a well-designed `swapByDelegation` can be approximately 3% cheaper for this one-transfer,
one-swap shape. Production caveats, signature schemes and delegation-chain length can easily outweigh that difference.
