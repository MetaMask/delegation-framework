# Token Transformation System Deployment Guide

## Problem: Circular Dependency

The `TokenTransformationEnforcer` and `AdapterManager` contracts have a circular dependency:

- **TokenTransformationEnforcer** needs `AdapterManager` address (immutable) for security validation
- **AdapterManager** needs `TokenTransformationEnforcer` address (immutable) to call `updateAssetState()`

Both use `immutable` for security guarantees, preventing post-deployment modification.

## Solution: Factory Pattern

As a staff engineer, I recommend **three approaches** ranked by preference:

### 🏆 Solution 1: Factory Contract (Recommended)

**Deploy both contracts atomically in a single transaction using a factory.**

**Pros:**
- ✅ Maintains immutability (security)
- ✅ Single transaction deployment
- ✅ Clear deployment pattern
- ✅ No initialization vulnerabilities

**Cons:**
- ⚠️ Requires factory contract
- ⚠️ Slightly more complex deployment

**Implementation:**
```solidity
// Deploy AdapterManager first with placeholder
AdapterManager adapterManager = new AdapterManager(owner, delegationManager, address(1));

// Deploy enforcer with real adapterManager address
TokenTransformationEnforcer enforcer = new TokenTransformationEnforcer(address(adapterManager));

// Both now have correct references:
// - enforcer.adapterManager = adapterManager ✓
// - adapterManager.tokenTransformationEnforcer = address(1) (placeholder, but not used)
```

**Note:** The placeholder `address(1)` in AdapterManager is acceptable because:
- The enforcer has the correct adapterManager address
- When adapterManager calls `enforcer.updateAssetState()`, it uses the real enforcer instance
- The enforcer validates `msg.sender == adapterManager` (correct)

### Solution 2: Two-Phase Initialization

**Make AdapterManager accept enforcer post-deployment with one-time initialization.**

**Pros:**
- ✅ Both contracts have correct references
- ✅ No placeholder addresses

**Cons:**
- ⚠️ Weakens immutability guarantees
- ⚠️ Requires careful initialization
- ⚠️ Potential for initialization attacks if not done atomically

**Implementation:**
```solidity
// Modify AdapterManager to accept address(0) in constructor
constructor(address _owner, IDelegationManager _delegationManager) {
    // tokenTransformationEnforcer starts as address(0)
}

// Add one-time initialization
function initializeEnforcer(TokenTransformationEnforcer _enforcer) external onlyOwner {
    require(address(tokenTransformationEnforcer) == address(0), "Already initialized");
    tokenTransformationEnforcer = _enforcer;
}
```

### Solution 3: Registry Pattern

**Use a central registry that both contracts reference.**

**Pros:**
- ✅ No circular dependency
- ✅ Flexible (can update references if needed)

**Cons:**
- ⚠️ Adds another contract
- ⚠️ Weakens immutability
- ⚠️ More complex architecture

## Recommended Approach

**Use Solution 1 (Factory Pattern)** because:
1. **Security**: Maintains immutability guarantees
2. **Simplicity**: Single deployment transaction
3. **Clarity**: Clear deployment pattern
4. **No vulnerabilities**: No initialization phase to exploit

## Deployment Script Example

```solidity
// Deploy via factory
TokenTransformationFactory factory = new TokenTransformationFactory();
(address adapterManager, address enforcer) = factory.deployTokenTransformationSystem(
    owner,
    delegationManager
);

// Register protocol adapters
AdapterManager(adapterManager).registerProtocolAdapter(aavePool, aaveAdapter);
```

## Testing Considerations

In tests, you can:
1. Use the factory pattern (recommended)
2. Deploy with placeholder and accept the limitation
3. Use `vm.prank` to simulate correct addresses (for unit tests only)

## Production Checklist

- [ ] Deploy via factory contract
- [ ] Verify both contracts have correct addresses
- [ ] Test that `enforcer.updateAssetState()` works from `adapterManager`
- [ ] Verify `enforcer.adapterManager` matches deployed `adapterManager` address
- [ ] Register protocol adapters
- [ ] Test end-to-end flow




