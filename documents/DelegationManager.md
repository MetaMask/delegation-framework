# Delegation Manager

A Delegation Manager is responsible for validating delegations and triggering the action to be taken on behalf of the delegator.

This contract does not implement ERC7579 see [ERC-7579 Details](/documents/PartialERC7579.md).

## Rules

- A Delegation Manager MUST implement ERC-7710 `redeemDelegations` interface as specified `function redeemDelegations(bytes[] calldata _permissionContexts, ModeCode[] _modes, bytes[] calldata _executionCallDatas) external;`.

## Delegations

Users can allow other contracts or EOAs to invoke an action directly from their DeleGator Smart Account through a delegation. Creating a delegation requires specifying a delegate and some optional data such caveats (more detail below) and an authority. Delegations are stored offchain and helper utilities that assist with the delegation lifecycle are provided in the SDK.

> NOTE: Delegations are validated at execution time, so the signature may become invalid if the conditions of a valid signature change.
>
> Example: Alice delegates to Bob the ability to spend her USDC with a 1 of 1 MultiSig DeleGator Account. She then updates her DeleGator Account to a 2 of 3 MultiSig. When Bob redeems the delegation from Alice, it will fail since the signed delegation is no longer valid.

# MetaMask's Delegation Manager

## Creating a Delegation

Users can create a `Delegation` and provide it to a delegate in the form of an offchain delegation.

## Disabling a Delegation

Delegators can disable a delegation by calling the function `disableDelegation(delegation)` of the DelegationManager, this is an onchain operation that requires paying gas.

### Offchain Delegations

Offchain Delegations are done through signing a `Delegation` and adding it to the `signature` field. Delegates can then redeem Delegations by providing this struct. To get this signature we use [EIP-712](https://eips.ethereum.org/EIPS/eip-712).

### Open Delegations

Open delegations are delegations that don't have a strict `delegate`. By setting the `delegate` to the special value `address(0xa11)` the enforcement of the `delegate` address is bypassed allowing users to create a single delegation that can be valid for a whole group of users rather than just one. Open delegations remove the restriction of needing to know the delegate's address at the time of delegation creation and rely entirely on Caveat Enforcers to restrict access to the delegation.

## Redeeming a Delegation

`redeemDelegations` method that can be used by delegation redeemers to execute some `Execution` which will be verified by the `DelegationManager` before ultimately calling `executeFromExecutor` on the root delegator. The delegations have to be redeemed in the same delegation manager that was used to create the delegation signature otherwise they will revert. Delegator accounts must allow the delegation manager to call the function `executeFromExecutor`.

Our `DelegationManager` implementation:

1. `redeemDelegations` consumes an array of bytes with the encoded delegation chains (`Delegation[]`) for executing each of the `Execution`.
   > NOTE: Delegations are ordered from leaf to root. The last delegation in the array must have the root authority.
2. Validates the `msg.sender` calling `redeemDelegations` is allowed to do so
3. Validates the signatures of offchain delegations.
4. Checks if any of the delegations being redeemed are disabled
5. Ensures each delegation has sufficient authority to execute, given by the previous delegation or by being a root delegation
6. Calls `beforeAllHook` for all delegations before processing any of the executions (from leaf to root delegation)
7. Calls `beforeHook` before each individual execution tied to a delegation (from leaf to root delegation)
8. Performs the `Execution` provided by calling `ExecuteFromExecutor` on the root delegator.
9. Calls `afterHook` after each individual execution tied to a delegation (from root to leaf delegation)
10. Calls `afterAllHook` for all delegations after processing all the executions (from root to leaf delegation)

> NOTE: Some actions can invalidate a delegation, for example: A delegation can be revoked by the delegator, the delegator code might change, or the delegation signature can become invalid at any time.
> Validate a delegation redemption by either simulating the transaction or by reading the storage on our implementation `disabledDelegations(delegationHash)`.

## Token Payment Validation

When using delegations for token transfers, it's recommended to implement a CaveatEnforcer that validates the balance difference of the recipient before and after execution, as some token implementations may not revert on failed transfers and the DelegationManager doesn't validate execution outputs.

## Re-delegating

Example: Alice delegates to Bob the ability to transfer USDC, giving Bob the ability to act on her behalf. Bob then "re-delegates" the ability to act on his behalf to Carol and includes the `authority`, a hash of the delegation, given to him from Alice. This enables Carol to act on behalf of Alice. Bob can add extra restrictions when he re-delegates to Carol in addition to what the initial delegation had, to understand what the delegation can do, it is necessary to analyze all the enforcers being used in the entire delegation chain.

## Caveats

[Read about "Caveats Enforcers" ->](/documents/CaveatEnforcers.md)
