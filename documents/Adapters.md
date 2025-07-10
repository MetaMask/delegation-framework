# Delegation Adapters

Delegation adapters are specialized contracts that simplify integration between the delegation framework and external protocols that don't natively support delegations. Many DeFi protocols require users to perform multi-step operations—typically providing ERC-20 approvals followed by specific function calls—which adapters combine into single, atomic, delegatable executions. This enables users to delegate complex protocol interactions while ensuring outputs are delivered to the root delegator or their specified recipients. Adapters are particularly valuable for enabling non-DeleGator accounts to redeem delegations and meet delegator-specified requirements. Since most existing protocols haven't yet implemented native delegation support, adapters serve as an essential bridge layer that converts delegation-based permissions into protocol-compatible interactions while enforcing proper restrictions and safeguards during redemption.

## Current Adapters

### DelegationMetaSwapAdapter

Facilitates token swaps through DEX aggregators by leveraging ERC-20 delegations with enforced outcome validation. This adapter integrates with the MetaSwap aggregator to execute optimal token swaps while maintaining delegation-based access control. It enables users to delegate ERC-20 token permissions and add conditions for enforced outcomes by the end of redemption. The adapter creates a self-redemption mechanism that atomically executes both the ERC-20 transfer and swap during the execution phase, followed by outcome validation in the afterAllHooks phase. It supports configurable token whitelisting through caveat enforcers and includes signature validation with expiration timestamps for secure API integration.

### LiquidStakingAdapter

Manages stETH withdrawal operations through Lido's withdrawal queue using delegation-based permissions. This adapter specifically focuses on withdrawal functions that require ERC-20 approvals, while deposit operations are excluded since they only require ETH and do not need ERC-20 approval mechanisms. The adapter facilitates stETH withdrawal requests by using delegations to transfer stETH tokens and supports both delegation-based transfers and ERC-20 permit signatures for gasless approvals. It has been designed to enhance the delegation experience by allowing users to enforce stricter delegation restrictions related to the Lido protocol, ensuring that redeemers must send withdrawal request ownership and any resulting tokens directly to the root delegator.

### AaveAdapter

_(Coming soon)_ Lending and borrowing operations on Aave protocol
