# Token Transformation System

## Overview

The Token Transformation System enables delegations to track and control token transformations through DeFi protocol interactions. This system allows AI agents and other automated systems to use delegated tokens in lending protocols (like Aave and Morpho) while maintaining granular control over the evolving token positions.

## Problem Statement

### The Challenge

Traditional delegation systems grant access to a fixed amount of a single token. However, when tokens are used in DeFi protocols, they often transform into different tokens:

- **Lending Protocols**: Depositing USDC into Aave yields aUSDC (a rebasing token that increases over time)
- **Yield Strategies**: Tokens may be transformed through multiple protocol interactions
- **Multi-Token Positions**: A single delegation may evolve to control multiple token types

**Example Scenario:**

1. User delegates 1000 USDC to an AI agent
2. Agent deposits 500 USDC → receives 500 aUSDC (Aave)
3. Agent uses 200 USDC to buy DAI via a swap
4. Final state: User should have control over 300 USDC + 500 aUSDC + 200 DAI

The challenge is maintaining permission over **all tokens derived from the original delegation** until the delegation expires or is revoked.

### Requirements

1. **Track Transformations**: Monitor what tokens are generated from protocol interactions
2. **Multi-Token Support**: Track multiple tokens per delegation simultaneously
3. **Granular Control**: Maintain access control over each token type and amount
4. **Protocol Agnostic**: Support multiple lending protocols (Aave, Morpho, etc.)
5. **Public Visibility**: Allow anyone to query available token amounts per delegation

## Solution Architecture

The solution consists of three main components:

### 1. TokenTransformationEnforcer

A caveat enforcer that tracks multiple tokens per delegation hash.

**Key Features:**

- Maps `delegationHash => token => availableAmount`
- Initializes from delegation terms on first use
- Validates token usage in `beforeHook`
- Updates state via `updateAssetState()` (only callable by AdapterManager)
- Public view function: `getAvailableAmount(delegationHash, token)`

**State Structure:**

```solidity
mapping(bytes32 delegationHash => mapping(address token => uint256 amount)) public availableAmounts;
mapping(bytes32 delegationHash => bool initialized) public isInitialized;
```

**Initialization:**

- Terms encode: `20 bytes token address + 32 bytes initial amount`
- On first use of initial token, amount is initialized from terms
- Subsequent uses deduct from available amount

### 2. AdapterManager

Central coordinator that routes protocol interactions to specific adapters and updates enforcer state.

**Key Responsibilities:**

- Routes protocol calls to appropriate adapters via `protocolAdapters` mapping
- Handles token approvals for protocol interactions
- Measures token balances before/after protocol actions
- Updates `TokenTransformationEnforcer` state after transformations
- Transfers all tokens to root delegator (never holds tokens)

**Flow:**

1. Receives delegation request with protocol address and action
2. Routes to appropriate adapter based on protocol address
3. Adapter executes protocol interaction and measures transformations
4. AdapterManager updates enforcer state: deducts `tokenFrom`, adds `tokenTo`
5. Transfers output tokens to root delegator

### 3. Protocol Adapters

Protocol-specific adapters that handle interactions with lending protocols.

**Current Adapters:**

- **AaveAdapter**: Handles Aave V3 deposits/withdrawals
- **MorphoAdapter**: Handles Morpho market interactions

**Adapter Interface:**

```solidity
interface ILendingAdapter {
    struct TransformationInfo {
        address tokenFrom;
        uint256 amountFrom;
        address tokenTo;
        uint256 amountTo;
    }

    function executeProtocolAction(
        address _protocolAddress,
        string calldata _action,
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        bytes calldata _actionData
    ) external returns (TransformationInfo memory);
}
```

**Adapter Responsibilities:**

- Measure token balances before protocol interaction
- Execute protocol function (deposit, withdraw, etc.)
- Measure token balances after interaction
- Return transformation information (tokenFrom, amountFrom, tokenTo, amountTo)

## How It Works

### Example Flow: Aave Deposit

1. **Initial Delegation**:

   ```
   User delegates 1000 USDC with TokenTransformationEnforcer
   Terms: [USDC address, 1000]
   ```

2. **Agent Initiates Deposit**:

   ```
   Agent calls AdapterManager.executeProtocolActionByDelegation(
       protocol: Aave Pool,
       action: "deposit",
       tokenFrom: USDC,
       amountFrom: 500,
       delegations: [...]
   )
   ```

3. **Delegation Redemption**:

   - DelegationManager validates delegations
   - TokenTransformationEnforcer.beforeHook() validates 500 USDC is available
   - Deducts 500 USDC from availableAmounts[delegationHash][USDC]
   - Transfers 500 USDC to AdapterManager

4. **Protocol Interaction**:

   - AdapterManager approves Aave Pool
   - AaveAdapter measures aUSDC balance before
   - AaveAdapter calls Aave Pool.supply(USDC, 500, AdapterManager, 0)
   - AaveAdapter wraps aUSDC → wrapped aUSDC (non-rebasing)
   - AaveAdapter measures wrapped aUSDC balance after
   - Returns: tokenFrom=USDC, amountFrom=500, tokenTo=wrapped aUSDC, amountTo=500

5. **State Update**:

   - AdapterManager calls TokenTransformationEnforcer.updateAssetState(
     delegationHash,
     wrapped aUSDC,
     500
     )
   - Enforcer state: availableAmounts[delegationHash][wrapped aUSDC] = 500

6. **Token Transfer**:
   - AdapterManager transfers wrapped aUSDC to root delegator
   - Final state:
     - availableAmounts[delegationHash][USDC] = 500
     - availableAmounts[delegationHash][wrapped aUSDC] = 500

### Example Flow: Multiple Transformations

**Initial**: 1000 USDC delegated

**Step 1**: Deposit 500 USDC → Aave

- Result: 500 USDC + 500 wrapped aUSDC tracked

**Step 2**: Use 200 USDC → Swap → DAI

- Result: 300 USDC + 500 wrapped aUSDC + 200 DAI tracked

**Step 3**: Use 100 wrapped aUSDC → Withdraw → USDC

- Result: 400 USDC + 400 wrapped aUSDC + 200 DAI tracked

All tokens remain under delegation control until expiration or revocation.

## Key Design Decisions

### 1. Adapter Pattern

**Why**: Different protocols have different interfaces and behaviors. Adapters encapsulate protocol-specific logic while maintaining a consistent interface.

**Benefits**:

- Easy to add new protocols (just implement ILendingAdapter)
- Protocol-specific logic isolated from core system
- Consistent transformation tracking across protocols

### 2. AdapterManager as State Updater

**Why**: Only AdapterManager can update enforcer state to prevent unauthorized state changes.

**Security**:

- Enforcer validates `msg.sender == adapterManager` in `updateAssetState()`
- Ensures state updates only occur after verified protocol interactions

### 3. Tokens Always Go to Root Delegator

**Why**: Maintains clear ownership - tokens never stay in adapters or enforcer contracts.

**Flow**:

- Tokens flow: Root Delegator → AdapterManager → Protocol → AdapterManager → Root Delegator
- Enforcer only tracks amounts, never holds tokens

### 4. Balance Measurement in Adapters

**Why**: Adapters know the expected output tokens and can measure accurately.

**Implementation**:

- Adapters measure balances before/after protocol interactions
- Return actual transformation amounts
- AdapterManager validates received amounts match reported amounts

### 5. Wrapped Tokens for Rebasing Assets

**Why**: Rebasing tokens (like aTokens) change balance over time, complicating tracking.

**Solution**:

- AaveAdapter wraps aTokens into non-rebasing wrapped tokens
- Wrapped tokens have fixed supply, easier to track
- TODO: Investigate using Aave's ATokenVault (ERC-4626) for direct wrapped token support

## Public API

### Query Available Amounts

Anyone can query available token amounts for a delegation:

```solidity
uint256 available = tokenTransformationEnforcer.getAvailableAmount(
    delegationHash,
    tokenAddress
);
```

### Check Protocol Adapters

```solidity
address adapter = adapterManager.protocolAdapters(protocolAddress);
```

## Security Considerations

1. **State Updates**: Only AdapterManager can update enforcer state
2. **Token Validation**: Enforcer validates all token transfers before execution
3. **Balance Verification**: AdapterManager verifies received tokens match adapter reports
4. **Ownership**: All tokens always belong to root delegator
5. **Initialization Protection**: Initial amount only set once per delegationHash

## Future Enhancements

1. **ATokenVault Support**: Use Aave's native ATokenVault for direct wrapped token deposits/withdrawals
2. **Additional Protocols**: Add adapters for more lending protocols
3. **Borrowing Support**: Extend adapters to handle borrowing and repayment
4. **Multi-Step Strategies**: Support complex multi-protocol strategies
5. **Gas Optimization**: Optimize state updates and balance measurements

## Files Structure

```
src/
├── enforcers/
│   └── TokenTransformationEnforcer.sol    # Tracks multi-token state per delegation
├── helpers/
│   ├── adapters/
│   │   ├── AdapterManager.sol             # Routes to adapters, updates state
│   │   ├── AaveAdapter.sol                 # Aave V3 interactions
│   │   └── MorphoAdapter.sol                # Morpho interactions
│   └── interfaces/
│       └── ILendingAdapter.sol             # Adapter interface
```

## Usage Example

```solidity
// 1. Create delegation with TokenTransformationEnforcer
Delegation memory delegation = Delegation({
    delegate: agentAddress,
    delegator: userAddress,
    authority: ROOT_AUTHORITY,
    caveats: [Caveat({
        enforcer: tokenTransformationEnforcer,
        terms: abi.encodePacked(usdcAddress, 1000e6), // 1000 USDC
        args: hex""
    })],
    salt: 0,
    signature: hex""
});

// 2. Agent uses delegation to deposit to Aave
adapterManager.executeProtocolActionByDelegation(
    aavePoolAddress,
    "deposit",
    usdcToken,
    500e6,
    abi.encode(adapterManagerAddress),
    delegations
);

// 3. Query available amounts
uint256 usdcAvailable = tokenTransformationEnforcer.getAvailableAmount(
    delegationHash,
    usdcAddress
); // Returns: 500e6

uint256 wrappedAUsdcAvailable = tokenTransformationEnforcer.getAvailableAmount(
    delegationHash,
    wrappedAUsdcAddress
); // Returns: 500e6
```
