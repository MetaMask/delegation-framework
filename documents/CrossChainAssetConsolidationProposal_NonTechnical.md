# Cross-Chain Asset Consolidation via Delegated Automation

## Non-Technical Overview

## Problem Statement

We need to automatically move assets (like USDC) from our multisig wallets on multiple blockchain networks back to Ethereum mainnet on a regular basis. Currently, this requires manual coordination of multiple signers for each transfer, which is inefficient and doesn't scale well.

## Solution Overview

We've designed a secure automated system that moves funds across chains without requiring multisig signers to approve each individual transfer. The key innovation is that we create a **one-time permission slip** (called a "delegation") that gives an automated service very limited powers—it can only do exactly what we want it to do, nothing more.

Think of it like giving someone a key to your house, but the key only works on one specific door, only during certain hours, and can only be used to move items to one specific location. Even if someone steals that key, they can't do anything harmful.

**Key Points**:

- Automation service only TRIGGERS the transaction (redeems permission slip)
- MULTISIG EXECUTES the action (calls bridge contract)
- Tokens flow directly from Multisig → Bridge → Treasury
- Automation service never holds or controls tokens

## How It Works (Simple Explanation)

### The Setup (One-Time Process)

1. **Multisig wallets hold the funds**: Our company's multisig wallets (requiring multiple signatures to control) hold assets on various blockchain networks.

2. **Create a permission slip**: The multisig signers come together **one time** to create a special permission slip. This permission slip says: "An automated service is allowed to move funds, BUT only if it follows these strict rules..."

3. **The rules are enforced by the blockchain**: These rules are written into smart contracts on the blockchain itself. The blockchain checks every single transaction to make sure the rules are followed—no exceptions. These rules are permanent and enforced by the blockchain. Once setup is complete, multisig keys can be stored in cold storage and never needed again for routine operations.

### The Rules (What the Automation Can and Cannot Do)

The permission slip includes strict rules that are checked by the blockchain before any transfer happens:

- ✅ **Can only call the bridge contract** (the approved service for moving funds between chains)
- ✅ **Can only use approved bridge functions** (specific methods we've approved)
- ✅ **Can only send to our mainnet treasury address** (funds always go to the correct destination)
- ✅ **Has spending limits** (can only move a certain amount per transaction and per time period)
- ✅ **Has time restrictions** (only valid during certain time windows)

Even if someone steals the automation service's key, they **cannot**:

- ❌ Send funds to any address other than our treasury
- ❌ Call any contracts other than the approved bridge
- ❌ Exceed the spending limits we've set
- ❌ Access the multisig funds directly
- ❌ Bypass any of these rules (they're enforced by the blockchain itself)

### Daily Operations

Once set up, an automated service monitors the multisig wallets. When it detects that funds should be moved (based on thresholds we configure), it uses the permission slip to execute the transfer. The blockchain automatically checks all the rules before allowing the transfer to proceed.

**Important Security Point**: The automation service only triggers the transaction by redeeming the permission slip. Once the delegation is redeemed and validated by the blockchain, **the multisig wallet itself executes the action**—it calls the bridge contract directly. The tokens flow directly from the multisig wallet to the bridge contract, and then to the mainnet treasury. The automation service never holds or controls the tokens, and it doesn't execute the action—the multisig does.

## Security Model (Why This Is Safe)

### The Most Important Security Feature

**Multisig keys are only needed once during setup.** After creating the permission slip, the multisig signers can store their keys in cold storage (offline, highly secure storage) and never touch them again for routine operations.

### Two Types of Keys, Two Levels of Risk

1. **Multisig Keys** (High Security Required)

   - Only used once to create the permission slip
   - Can be stored in cold storage after setup
   - These are the keys that actually control the funds

2. **Automation Service Key** (Lower Security Risk)
   - Used continuously by the automated service
   - Even if this key is stolen, the worst an attacker can do is:
     - Trigger a transfer early (but funds still go to the correct destination)
     - Spend some gas tokens (which can be mitigated with additional protections)
   - **Cannot access multisig funds directly**
   - **Cannot send funds anywhere except our treasury**
   - **Cannot exceed spending limits**

**Security Model Summary**: Multisig keys are used once during setup, then stored in cold storage. They create a permission slip (one-time delegation with strict rules) that grants limited access to the automation service key. The automation service key must use the permission slip, and the blockchain enforces the rules—these cannot be bypassed by anyone.

### Why the Automation Key Is Safe Even If Compromised

The blockchain itself enforces the rules. When the automation service tries to make a transfer, the blockchain checks:

- Is it calling an approved contract? (No → transaction rejected)
- Is it sending to the approved address? (No → transaction rejected)
- Is it within spending limits? (No → transaction rejected)
- Is it within the time window? (No → transaction rejected)

These checks happen automatically on the blockchain—they cannot be bypassed, even if someone has the automation key. If ANY check fails, the transaction is rejected. All checks must pass for the transaction to be allowed, at which point the multisig executes the transfer and funds move to the treasury.

### Emergency Controls

If something goes wrong, we can immediately:

- Stop the automated service
- Disable the permission slip on the blockchain (instant, no multisig coordination needed)
- All future attempts to use the permission slip will be rejected

## Operational Flow

1. Automated service checks how much money is in each multisig wallet
2. Service evaluates if conditions are met (enough funds, within time windows, under spending limits)
3. If conditions are met, automation service redeems the permission slip (triggers the transaction)
4. Blockchain validates the permission slip and checks all rules
5. If all checks pass, **the multisig wallet itself executes the bridge transfer** (multisig calls the bridge contract directly)
6. Tokens flow directly from multisig wallet to bridge contract (never through automation service)
7. Funds arrive at our mainnet treasury wallet
8. Everything is recorded on the blockchain for audit purposes

**Key Points**:

- Automation service only TRIGGERS (redeems permission slip)
- MULTISIG EXECUTES the action (calls bridge contract)
- Tokens flow directly: Multisig → Bridge → Treasury
- Automation service never holds or controls tokens

## Key Security Benefits

**Separation of Concerns**: The rules are enforced on the blockchain (can't be changed without multisig approval), while the decision-making logic runs off-chain (can be updated quickly if needed).

**Minimal Attack Surface**: Even if the automation service is compromised, the attacker can only do what we've explicitly allowed—move funds to our treasury within our limits.

**No Ongoing Multisig Coordination**: After initial setup, routine transfers happen automatically without requiring multiple signers to coordinate.

**Complete Audit Trail**: Every transfer is recorded on the blockchain, providing full transparency.

## Risks and How We Mitigate Them

**Bridge Risk**: If the bridge service has problems or is compromised, funds could be affected while in transit.

- _Mitigation_: We can immediately stop the automation and disable the permission slip. We can also configure different limits per chain to isolate risk.

**Automation Key Compromise**: If someone steals the automation service's key, they could try to use it.

- _Mitigation_: The blockchain rules prevent them from doing anything harmful. They can only trigger transfers that send funds to our treasury (the correct destination) within our spending limits. The worst case is they trigger transfers early or spend some gas tokens, which can be mitigated with additional protections.

**Configuration Errors**: If we misconfigure the thresholds or limits, transfers might happen at wrong times or amounts.

- _Mitigation_: We use code review processes, test changes in stages, and all configuration is visible on the blockchain for verification.

**Multisig Signer Changes**: If we need to change who can sign for the multisig, the old permission slip becomes invalid.

- _Mitigation_: This is expected behavior. We simply create a new permission slip as part of our standard process when signers change.

## Summary

This system allows us to automate cross-chain fund transfers securely by:

1. Creating a one-time permission slip with strict rules
2. Having the blockchain enforce those rules automatically
3. Requiring multisig keys only once during setup
4. Limiting what the automation can do, even if its key is compromised
5. Providing emergency controls to stop operations instantly

The security comes from the blockchain itself enforcing the rules—no one can bypass them, not even someone with the automation key.
