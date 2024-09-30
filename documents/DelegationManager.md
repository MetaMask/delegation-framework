# Delegation Manager

A Delegation Manager is responsible for validating delegations and triggering the action to be taken on behalf of the delegator.

This contract does not implement ERC7579 see [ERC-7579 Details](/documents/PartialERC7579.md).

## Rules

- A Delegation Manager MUST implement `redeemDelegation` interface as specified `function redeemDelegation(bytes[] calldata _permissionContexts, ModeCode[] _modes, bytes[] calldata _executionCallDatas) external;`.

## Delegations

Users can allow other contracts or EOAs to invoke an action directly from their DeleGator Smart Account through a delegation. Creating a delegation requires specifying a delegate and some optional data such caveats (more detail below) and an authority. Delegations are stored offchain and helper utilities that assist with the delegation lifecycle are provided in the SDK.

> NOTE: Delegations are validated at execution time, so the signature may become invalid if the conditions of a valid signature change.
>
> Example: Alice delegates to Bob the ability to spend her USDC with a 1 of 1 MultiSig DeleGator Account. She then updates her DeleGator Account to a 2 of 3 MultiSig. When Bob redeems the delegation from Alice, it will fail since the signed delegation is no longer valid.

# MetaMask's Delegation Manager

## Creating a Delegation

Users can create a `Delegation` and provide it to a delegate in the form of an offchain delegation.

### Offchain Delegations

Offchain Delegations are done through signing a `Delegation` and adding it to the `signature` field. Delegates can then redeem Delegations by providing this struct. To get this signature we use [EIP-712](https://eips.ethereum.org/EIPS/eip-712).

### Open Delegations

Open delegations are delegations that don't have a strict `delegate`. By setting the `delegate` to the special value `address(0xa11)` the enforcement of the `delegate` address is bypassed allowing users to create a single delegation that can be valid for a whole group of users rather than just one. Open delegations remove the restriction of needing to know the delegate's address at the time of delegation creation and rely entirely on Caveat Enforcers to restrict access to the delegation.

## Redeeming a Delegation

`redeemDelegation` method that can be used by delegation redeemers to execute some `Execution` which will be verified by the `DelegationManager` before ultimately calling `executeAsExecutor` on the root delegator.

Our `DelegationManager` implementation:

1. `redeemDelegation` consumes an array of bytes with the encoded delegation chains (`Delegation[]`) for executing each of the `Execution`.
   > NOTE: Delegations are ordered from leaf to root. The last delegation in the array must have the root authority.
2. Validates the `msg.sender` calling `redeemDelegation` is allowed to do so
3. Validates the signatures of offchain delegations.
4. Checks if any of the delegations being redeemed are disabled
5. Ensures each delegation has sufficient authority to execute, given by the previous delegation or by being a root delegation
6. Calls `beforeAllHook` for all delegations before processing any of the executions (from leaf to root delegation)
7. Calls `beforeHook` before each individual execution tied to a delegation (from leaf to root delegation)
8. Performs the `Execution` provided
9. Calls `afterHook` after each individual execution tied to a delegation (from root to leaf delegation)
10. Calls `afterAllHook` for all delegations before processing all the executions (from root to leaf delegation)

> NOTE: Ensure to double check that the delegation is valid before submitting a UserOp. A delegation can be revoked or a signature can be invalidated at any time.
> Validate a delegation redemption by either simulating the transaction or by reading the storage on our implementation `disabledDelegations(delegationHash)`.

## Re-delegating

Example: Alice delegates to Bob the ability to transfer USDC, giving Bob the ability to act on her behalf. Bob then "re-delegates" the ability to act on his behalf to Carol and includes the `authority`, a hash of the delegation, given to him from Alice. This enables Carol to act on behalf of Alice.

## Caveats

[Read about "Caveats Enforcers" ->](/documents/CaveatEnforcers.md)
