# Cross-Chain Asset Consolidation via Delegated Automation

## Problem Statement

Automate periodic transfers of assets (e.g., USDC) from multisig smart accounts on multiple EVM chains to Ethereum mainnet using the existing bridge infrastructure ([va-mmcx-bridge-contracts](https://github.com/consensys-vertical-apps/va-mmcx-bridge-contracts)).

## Solution Architecture

Leverage our existing delegation framework ([internal multisig/delegation repo]) to enable secure, automated cross-chain bridging with on-chain policy enforcement and off-chain execution orchestration.

### On-Chain Components

**Multisig Deployment**: Deploy MultiSigDeleGator smart accounts on each source chain using deterministic deployment to achieve identical addresses across chains with consistent signer sets and thresholds.

**Delegation Creation**: Multisig creates off-chain delegations (EIP-712 signed) granting limited execution authority to an automation service. **Critically, a single delegation signature can be reused indefinitely**—the automation service redeems the same signed delegation object for every bridging operation without requiring multisig signers to regenerate signatures. Delegations are validated on-chain by DelegationManager at each redemption time. Each delegation combines caveat enforcers:

- **AllowedTargetsEnforcer**: Only bridge contract addresses
- **AllowedMethodsEnforcer**: Only bridge entrypoints (deposit/lock/mint)
- **AllowedCalldataEnforcer**: Fixed mainnet treasury destination address
- **ERC20TransferAmountEnforcer**: Per-delegation spending limits
- **ERC20PeriodTransferEnforcer**: Time-windowed cumulative limits
- **TimestampEnforcer**: Validity windows
- **RedeemerEnforcer**: Optional automation wallet restriction

Delegations can be disabled on-chain via `disableDelegation()` for immediate revocation.

**Execution Flow**: When the automation service redeems a delegation via `DelegationManager.redeemDelegations()`, the framework validates all caveats, then the multisig executes the bridge call (approve tokens if needed, call bridge deposit function, emit events). Funds arrive at the mainnet treasury multisig with complete on-chain audit trail.

### Off-Chain Components

**Automation Service**: Node.js/TypeScript service (or OpenZeppelin Defender) monitors multisig balances via RPC, evaluates thresholds and limits, constructs delegation redemption transactions with encoded bridge calls, and submits signed transactions using the automation wallet.

**Key Management**: Private key never stored in plaintext. The automation service retrieves the key at runtime from a secrets manager (HashiCorp Vault, AWS KMS, GCP KMS, Azure Key Vault, or HSM). The service authenticates to the secrets manager using IAM roles, service accounts, or certificates. Network access controls restrict which machines/IPs can access the secrets manager API, and the automation service runs in an isolated network segment (VPC/subnet) with egress-only access to blockchain RPC endpoints. The key material is only decrypted in memory during transaction signing and never persisted to disk. Even if the automation service is compromised, delegation caveats limit blast radius (strict allowlists, per-tx/per-period caps).

**Delegation Issuance**: Multisig signers compose delegations with caveat configuration and sign via EIP-712. DelegationManager validates signatures at redemption. Signer set changes invalidate existing delegations (expected behavior; re-issue as part of signer-change playbook).

## Operational Flow

1. Off-chain service queries multisig balances on source chains
2. Service evaluates thresholds, time windows, and cumulative limits
3. If conditions met, service builds `redeemDelegations()` call with signed delegation and encoded bridge execution
4. DelegationManager validates signatures, caveats, and delegation status
5. Multisig approves tokens (if needed) and calls bridge contract
6. Funds bridge to mainnet; events emitted for audit

**Key Separation**: Policy enforcement is on-chain (delegations + caveats); decision logic and scheduling are off-chain (automation script).

## Advantages

**Security**: Multisig control, narrowly scoped permissions, immediate revocation, limited blast radius even if automation key compromised.

**Efficiency**: No multisig sign-off required per bridging operation; enables frequent automated transfers. **A single delegation signature is reusable indefinitely**, eliminating the need to coordinate multisig signers for each transfer—sign once, use forever (subject to caveat limits and validity windows).

**Scalability**: Easy extension across chains using same delegation pattern and deterministic addresses.

**Auditability**: Complete on-chain event records plus off-chain automation logs.

**Reuse**: Builds on existing MultiSigDeleGator and DelegationManager infrastructure.

## Risks and Mitigations

**Bridge Risk**: Exploit or downtime affects funds in transit. _Mitigation_: Immediate revocation via `disableDelegation()`, chain-specific configs, bridge event monitoring.

**Key Compromise**: Attacker could redeem delegations. _Mitigation_: Strict limits, secure key storage, revocation capability. Caveats prevent exceeding limits or calling unauthorized contracts.

**Config Errors**: Misconfigured thresholds cause unintended behavior. _Mitigation_: Code review, staged rollouts, on-chain verifiability of delegation parameters.

**Signer Changes**: Invalidates existing delegation signatures. _Mitigation_: Re-issue delegations as part of signer-change playbook.

## References

- Delegation Framework: [internal multisig/delegation repo]
- Bridge Contracts: https://github.com/consensys-vertical-apps/va-mmcx-bridge-contracts
- Bridge API: https://github.com/consensys-vertical-apps/va-mmcx-bridge-api
