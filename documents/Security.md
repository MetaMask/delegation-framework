# Security Guidelines

This document outlines important security considerations when working with the Delegation Framework.

## Batch Execution Security

> ⚠️ **Important Security Notice**
>
> When using batch execution functionality, developers and users should be aware of potential risks related to calldata structure manipulation that can lead to information leakage and/or enhanced MEV extraction between executions.

### Overview

The `decodeBatch` function uses assembly optimization for gas efficiency, which requires careful handling of execution calldata. Malformed execution arrays can cause unintended data exposure between batch operations.

### How Batch Decoding Works

```solidity
struct Execution {
    address target;
    uint256 value;
    bytes callData;  // ⚠️ Variable length field
}
```

The batch decoder processes an array of `Execution` structs where each execution contains variable-length calldata. The assembly implementation trusts the length fields in the calldata structure for gas optimization.

### Potential Risk Scenario

```solidity
// Batch with two executions
Execution[0] = { target: contractA, value: 0, callData: someFunction() }
Execution[1] = { target: contractB, value: 0, callData: sensitiveFunction(data) }

// If Execution[0] has malformed callData length, it might read into Execution[1]'s data
```

### Security Implications

1. **Information leakage**

   - **Risk**: `Execution[0]` may read calldata intended for `Execution[1]`
   - **Impact**: Sensitive transaction details could be exposed to earlier executions

2. **Enhanced MEV extraction**

   - **Risk**: Malicious actors could preview upcoming operations in the same batch
   - **Impact**: Increased MEV extraction, unfavorable execution order

3. **Front-running within batch**
   - **Risk**: Earlier executions could act on information from later executions
   - **Impact**: Sandwich attacks, price manipulation within the batch

### ✅ User Guidelines

- **Use MetaMask UI**: Transactions through MetaMask's interface are safe
- **Verify transaction details**: Always review what operations will be executed
- **Trust reputable dApps**: Only use well-audited applications for batch operations
- **Single execution**: Prefer single-execution operations for sensitive transactions

### Developer Guidelines

Developers should exercise extreme caution when manually creating execution calldata. The assembly-optimized `decodeBatch` function trusts the length fields in the calldata structure without bounds checking.

Improperly constructed calldata can lead to:

- Cross-execution data leakage
- Unintended information exposure
- Enhanced MEV extraction opportunities

### ✅ Safe Development Practices

- **Use established libraries** for batch construction rather than manual calldata creation
- **Validate all execution arrays** before processing
- **Implement length checks** if building custom batch constructors
- **Test thoroughly** with malformed inputs to ensure proper bounds checking
- **Never trust user-provided execution arrays** without validation
- **Separate sensitive operations** into individual transactions when possible

---
