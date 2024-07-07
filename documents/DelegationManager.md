# Delegation Manager

A Delegation Manager is responsible for validating delegations and triggering the action to be taken on behalf of the delegator.

## Rules

- A Delegation Manager MUST implement `redeemDelegation` interface as specified `function redeemDelegation(bytes calldata _data, Action calldata _action) external;`.

## Delegations

Users can allow other contracts or EOAs to invoke an Action directly from their DeleGator Smart Account through a Delegation. There are 2 flows for delegating: onchain and offchain. Both flows require creating a Delegation and sharing some additional data offchain to the delegate for them to be able to redeem the Delegation.

> NOTE: onchain Delegations are validated at the time of creation, not at the time of execution. This means if anything regarding a DeleGator’s control scheme is changed, the onchain Delegation is not impacted. Contrast this with an offchain Delegation, which is validated at the time of execution.
>
> Example: Alice delegates to Bob the ability to spend her USDC with a 1 of 1 MultiSig DeleGator Account. She then updates her DeleGator Account to a 2 of 3 MultiSig.
>
> - If she delegated onchain, Bob is still able to spend her USDC.
> - If she delegated offchain, the signature will no longer be valid and Bob is not able to spend her USDC.

# MetaMask's Delegation Manager

## Creating a Delegation

Users can create a `Delegation` and provide it to a delegate in the form of an onchain delegation or an offchain delegation.

### Onchain Delegations

Onchain Delegations are done through calling the `delegate` method on a DeleGator or DelegationManager. This validates the delegation at this time and the redeemer only needs the `Delegation` to redeem it (no signature needed).

### Offchain Delegations

Offchain Delegations are done through signing a `Delegation` and adding it to the `signature` field. Delegates can then redeem Delegations by providing this struct. To get this signature we use [EIP-712](https://eips.ethereum.org/EIPS/eip-712).

### Open Delegations

Open delegations are delegations that don't have a strict `delegate`. By setting the `delegate` to the special value `address(0xa11)` the enforcement of the `delegate` address is bypassed allowing users to create a single delegation that can be valid for a whole group of users rather than just one. Open delegations remove the restriction of needing to know the delegate's address at the time of delegation creation and rely entirely on Caveat Enforcers to restrict access to the delegation.

## Redeeming a Delegation

`redeemDelegation` method that can be used by delegation redeemers to execute some `Action` which will be verified by the `DelegationManager` before ultimately calling `executeAction` on the root delegator.

Our `DelegationManager` implementation:

1. `redeemDelegation` consumes a list of delegations (`Delegation[]`) and an `Action` to be executed
   > NOTE: Delegations are ordered from leaf to root. The last delegation in the array must have the root authority.
2. Validates the `msg.sender` calling `redeemDelegation` is allowed to do so
3. Validates the signatures of offchain delegations and that onchain delegations have already been verified
4. Checks if any of the delegations being redeemed are disabled
5. Ensures each delegation has sufficient authority to execute, given by the previous delegation or by being a root delegation
6. Calls `beforeHook` for all delegations (from leaf to root delegation)
7. Executes the `Action` provided
8. Calls `afterHook` for all delegations (from root to leaf delegation)

> NOTE: Ensure to double check that the delegation is valid before submitting a UserOp. A delegation can be revoked or a signature can be invalidated at any time.
> Validate a delegation redemption by either simulating the transaction or by reading the storage on our implementation `disabledDelegations(delegationHash)`.

## Re-delegating

Example: Alice delegates to Bob the ability to transfer USDC, giving Bob the ability to act on her behalf. Bob then "re-delegates" the ability to act on his behalf to Carol and includes the `authority`, a hash of the delegation, given to him from Alice. This enables Carol to act on behalf of Alice.

## Caveats

`CaveatEnforcer` contracts are used to place restrictions on Delegations. This allows dapps to craft very granular delegations that only allow actions to take place under specific circumstances.

> NOTE: each `CaveatEnforcer` is called by the `DelegationManager` contract. This is important when storing data in the `CaveatEnforcer`, as `msg.sender` will always be the address of the `DelegationManager`.

> NOTE: there is no guarantee that the action is executed. Keep this in mind when designing Caveat Enforcers. If you are relying on the action then be sure to use the `afterHook` method to validate any expected state updates.
