# Scripts

Short reference for Forge scripts in this repo. Set required env vars in `.env`; run with `--rpc-url <rpc>` and add `--broadcast` to send transactions.

## Deployment

| Script | Purpose |
|--------|---------|
| **DeployDelegationFramework.s.sol** | Deploys DelegationManager, MultiSigDeleGator impl, HybridDeleGator impl. Needs: `SALT`, `ENTRYPOINT_ADDRESS`. |
| **DeployCaveatEnforcers.s.sol** | Deploys the full set of caveat enforcers (AllowedCalldata, AllowedMethods, BlockNumber, etc.). Needs: `SALT`, `DELEGATION_MANAGER_ADDRESS`. |
| **DeployDelegationMetaSwapAdapter.s.sol** | Deploys DelegationMetaSwapAdapter (swap adapter for delegations + MetaSwap). Needs: `SALT`, `META_SWAP_ADAPTER_OWNER_ADDRESS`, `DELEGATION_MANAGER_ADDRESS`, `METASWAP_ADDRESS`, `SWAPS_API_SIGNER_ADDRESS`, `ARGS_EQUALITY_CHECK_ENFORCER_ADDRESS`. |
| **DeployMultiSigDeleGator.s.sol** | Deploys a MultiSigDeleGator proxy (threshold 1, owner = PRIVATE_KEY). Needs: `SALT`, `MULTISIG_DELEGATOR_IMPLEMENTATION_ADDRESS`. |
| **DeployEIP7702StatelessDeleGator.s.sol** | Deploys EIP7702StatelessDeleGator implementation. Needs: `SALT`, `ENTRYPOINT_ADDRESS`, `DELEGATION_MANAGER_ADDRESS`. |
| **DeploySimpleFactory.s.sol** | Deploys SimpleFactory. Needs: `SALT`. |
| **DeployBasicERC20.s.sol** | Deploys a BasicERC20 (USDT-like). Optional: `OWNER_ADDRESS`. |

## Signing (Safe / multisig)

| Script | Purpose |
|--------|---------|
| **SignDelegationWithSafe.s.sol** | Signs delegations using a Safe (multisig). Supports ERC20 transfer, swap, bridge. Run with `--sig "runERC20Transfer()"`, `runSwap()`, or `runBridge()`. Needs: `SAFE_ADDRESS`, `GATOR_SAFE_MODULE_ADDRESS`, `DELEGATION_MANAGER_ADDRESS`, `DELEGATE_ADDRESS`, `SIGNER1/2/3_PRIVATE_KEY`; optional `DELEGATION_METASWAP_ADAPTER_ADDRESS`, `AUTOMATION_PRIVATE_KEY`. |
| **SignPeriodDelegationsWithSafe.s.sol** | Signs two period delegations (ERC20 USDT + native ETH) with recipient restriction via Safe. Needs: Safe + Gator + DelegationManager + Delegate + signer keys + enforcer addresses (`ERC20_PERIOD_ENFORCER_ADDRESS`, `NATIVE_PERIOD_ENFORCER_ADDRESS`, `ALLOWED_TARGETS_ENFORCER_ADDRESS`, `ALLOWED_CALLDATA_ENFORCER_ADDRESS`). Optional: `PERIOD_START_DATE`. |

## Admin / utils

| Script | Purpose |
|--------|---------|
| **UpdateAllowedAggregatorIds.s.sol** | Whitelists aggregator IDs on DelegationMetaSwapAdapter (e.g. `openOceanFeeDynamic`). Needs: `DELEGATION_METASWAP_ADAPTER_ADDRESS`, `PRIVATE_KEY`. Use `--broadcast` to apply. |

## Helper

- **helpers/SafeDelegationSigner.sol** — Library/helper used by the Safe signing scripts to build and sign delegations with multiple Safe signers.
