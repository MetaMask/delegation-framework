# DelegationMetaSwapAdapter v2 Changelog

This document captures all changes made to `DelegationMetaSwapAdapter` (and its tests + deploy script) compared to v1. Use it as a reference when comparing against future versions or branches.

---

## High-level summary

v2 is a substantial rewrite. The contract:

- Uses a **single delegation** (no subVault redelegation) plus a **caller (operator) whitelist**.
- Replaces all per-token whitelists and per-token caps with a single **per-(tokenFrom, tokenTo) pair policy** (`pairLimits[tokenFrom][tokenTo]`) that combines an `enabled` allow-flag with `maxSlippage` and `maxPriceImpact` caps.
- Validates a **signed payload that now also includes `slippage` and `priceImpact`** alongside `apiData` and `expiration`.
- Resolves the swap recipient from a **Safe Module DeleGator** via `IDeleGatorModule.safe()`.
- Removes `ExecutionHelper`/`executeFromExecutor` and the self-call pattern.
- Removes aggregator-ID validation and `ArgsEqualityCheckEnforcer` integration entirely.
- Adds `ReentrancyGuard` and several gas/safety polish items.
- Strict input-side accounting: the swap reverts if the contract receives anything different from `amountFrom` of `tokenFrom` (no surplus-return path).

---

## Architecture changes

### Single delegation (no redelegation)

- **Before:** Two-hop chain `vault → subVault → adapter` with `subVault` redelegating to the adapter.
- **After:** A single delegation `vault → adapter`. `_delegations.length == 1` in normal flow.

### Removed `ExecutionHelper` / `executeFromExecutor`

- **Before:** Inherited `ExecutionHelper`. Exposed `executeFromExecutor(ModeCode, bytes)` gated by `onlyDelegationManager`. The swap flow issued **two** `redeemDelegations` calls — one to pull tokens, a second (with empty delegations) to call back into `swapTokens` via `executeFromExecutor`.
- **After:** No `ExecutionHelper` inheritance. No `executeFromExecutor`. The swap issues **one** `redeemDelegations` call, then calls private `_swapTokens` directly. The self-call pattern is gone.

### `swapTokens` → `_swapTokens` (private)

- **Before:** `swapTokens(...)` was `external` with `onlySelf`.
- **After:** `_swapTokens(...)` is `private`. Balance-before snapshot is taken in `swapByDelegation` before `redeemDelegations`; balance delta is verified inside `_swapTokens`.

### Strict input-side accounting (no surplus return)

- **Before:** `_swapTokens` reverted with `InsufficientTokens` only if the contract received less than `amountFrom`. If it received more (surplus), it returned the surplus to the recipient and continued with the swap.
- **After:** `_swapTokens` reverts with `UnexpectedTokenFromAmount(expected, obtained)` whenever the received amount differs from `amountFrom` in **either direction**. The surplus return-to-recipient branch is gone. Rationale: the redemption is built with exactly `amountFrom`, so any deviation indicates fee-on-transfer behavior or an upstream bug — not something to silently swap through.

### `_delegations` is `calldata`

- **Before:** `Delegation[] memory _delegations`.
- **After:** `Delegation[] calldata _delegations`. Saves gas; matches lint guidance.

### Reordered validation in `swapByDelegation`

The empty-delegations check now runs **before** signature validation and apiData decoding so bad input fails fast without wasted decoding.

### Identical-tokens check moved out of the swap path

- **Before:** `swapByDelegation` had an explicit `if (tokenFrom == tokenTo) revert InvalidIdenticalTokens();` after decoding apiData.
- **After:** `setPairLimits` rejects identical-token configurations at config time, so `pairLimits[X][X]` can only ever be the zero default (`enabled == false`). The pair-policy check in `swapByDelegation` therefore reverts with `PairDisabled(X, X)` for identical-token swap attempts. The redundant explicit check was removed.

---

## Access control

### New: `Ownable2Step` + `ReentrancyGuard`

- `ReentrancyGuard` is a **new** dependency (Ownable2Step was already in v1).
- `swapByDelegation` is `nonReentrant` (defense in depth: `metaSwap.swap` and the recipient native send are external calls).

### Removed modifiers

- `onlyDelegationManager` (unused after removing `executeFromExecutor`)
- `onlySelf` (unused after removing the self-call pattern)
- Errors: `NotDelegationManager`, `NotSelf`, `NotLeafDelegator`, `UnsupportedCallType`, `UnsupportedExecType`

### New: `onlyAllowedCaller` + `isCallerAllowed`

- `swapByDelegation` is gated by `onlyAllowedCaller`.
- Owner manages the whitelist via `updateAllowedCallers(address[], bool[])`.
- New mapping: `mapping(address caller => bool allowed) public isCallerAllowed`
- New event: `event ChangedCallerStatus(address indexed caller, bool indexed status)` (both fields indexed)
- New error: `error CallerNotAllowed()`

### Removed: `NotLeafDelegator` check

The old `_delegations[0].delegator == msg.sender` check is gone — caller whitelist replaces it (and is broader: any approved relayer, not specifically the leaf).

---

## Recipient resolution: Safe Module DeleGator

- **Before:** Output tokens were sent to `_delegations[delegationsLength_ - 1].delegator` (the root delegator address itself).
- **After:** Recipient is resolved via `IDeleGatorModule(rootDelegator).safe()`. If the call fails or returns `address(0)`, the swap reverts with `RecipientResolutionFailed(rootDelegator)` **before** any token movement.

**New file:** `src/helpers/interfaces/IDeleGatorModule.sol` (single function `safe() returns (address)`).

---

## Slippage and price impact (signed + per-pair caps)

This is a major v2 addition.

### `SignatureData` extended

```solidity
struct SignatureData {
    bytes apiData;
    uint256 expiration;
    uint256 slippage;     // NEW: API-reported slippage,    1e18 = 1%, max 100e18
    uint256 priceImpact;  // NEW: API-reported price impact, 1e18 = 1%, max 100e18
    bytes signature;
}
```

The signed digest is now `keccak256(abi.encode(apiData, expiration, slippage, priceImpact))`. Tampering with either field invalidates the signature.

### Per-pair policy

The contract uses **a single struct per (tokenFrom, tokenTo) pair** that combines the allow-flag with the slippage and price-impact caps:

```solidity
struct PairLimit {
    uint128 maxSlippage;     // 1e18 = 1%, max 100e18
    uint128 maxPriceImpact;  // 1e18 = 1%, max 100e18
    bool    enabled;         // false => pair is disabled / never configured
}

struct PairLimitInput {
    IERC20 tokenFrom;
    IERC20 tokenTo;
    PairLimit limit;         // composed, not flattened — single source of truth
}

mapping(IERC20 tokenFrom => mapping(IERC20 tokenTo => PairLimit)) public pairLimits;
```

`PairLimit` is packed into 2 storage slots (`uint128 + uint128 + bool`). `PairLimitInput` composes `PairLimit` so admin tooling and storage share the same value type.

### Admin batch setter

```solidity
function setPairLimits(PairLimitInput[] calldata _inputs) external onlyOwner;
```

Validates each entry: rejects identical tokens (`InvalidIdenticalTokens`), rejects caps above `MAX_PERCENT` (`InvalidPercent`). Emits `PairLimitSet` per entry.

### Validation in `swapByDelegation`

For the (tokenFrom, tokenTo) pair of the swap, the contract enforces:

- `pairLimits[tokenFrom][tokenTo].enabled` must be `true` — otherwise reverts `PairDisabled(tokenFrom, tokenTo)`. Since `enabled` defaults to `false`, an unconfigured pair is automatically disabled.
- `signedSlippage <= pairLimit.maxSlippage` — otherwise `SlippageExceedsCap(tokenFrom, tokenTo, signedSlippage, cap)`.
- `signedPriceImpact <= pairLimit.maxPriceImpact` — otherwise `PriceImpactExceedsCap(tokenFrom, tokenTo, signedPriceImpact, cap)`.

There is **no on-chain post-swap measurement** of slippage/priceImpact — the contract trusts the signed API claim and only enforces the admin caps.

### `enabled` doubles as the output-token allow-list

Pair policy replaces the v1 (post-refactor) `isTokenToAllowed` whitelist. If you want to allow A→B, you enable that specific pair. There is no separate global tokenTo whitelist anymore.

### New events / errors

- Event: `PairLimitSet(IERC20 indexed tokenFrom, IERC20 indexed tokenTo, uint128 maxSlippage, uint128 maxPriceImpact, bool enabled)`
- Errors: `PairDisabled(tokenFrom, tokenTo)`, `InvalidPercent(percent)`, `SlippageExceedsCap(tokenFrom, tokenTo, signed, cap)`, `PriceImpactExceedsCap(tokenFrom, tokenTo, signed, cap)`

---

## Token whitelists removed

- The `isTokenAllowed` / `isTokenToAllowed` mapping and its setter are **gone**.
- The `tokenFrom` whitelist (briefly present mid-refactor) is gone.
- The pair `enabled` flag is the only allow-list now — strictly more expressive (per-pair, directional).

Errors removed: `TokenFromIsNotAllowed`, `TokenToIsNotAllowed`. Events removed: `ChangedTokenStatus`, `ChangedTokenToStatus`. Setter removed: `updateAllowedTokens` / `updateAllowedTokensTo`.

---

## Native token handling

The contract uses **`address(0)`** as the sole sentinel for the chain's native token. The Swaps API and admin configuration must agree on this single sentinel.

---

## Removed features (relative to v1)

### ArgsEqualityCheckEnforcer integration

- Constructor no longer takes `_argsEqualityCheckEnforcer`.
- No `WHITELIST_ENFORCED` / `WHITELIST_NOT_ENFORCED` constants.
- No `MissingArgsEqualityCheckEnforcer` error, no `SetArgsEqualityCheckEnforcer` event.
- The `_useTokenWhitelist` flag on `swapByDelegation` is gone.

### Aggregator ID whitelist

- `isAggregatorAllowed` mapping removed.
- `updateAllowedAggregatorIds` removed.
- `ChangedAggregatorIdStatus` event removed.
- `AggregatorIdIsNotAllowed` error removed.
- Any aggregator ID is accepted; the contract trusts the signed payload + per-pair caps to constrain misuse.

### Per-token slippage / priceImpact (post-refactor intermediate)

- Mappings `maxSlippagePerToken` and `maxPriceImpactPerToken` removed.
- Setters `setMaxSlippagePerToken` and `setMaxPriceImpactPerToken` removed.
- Events `MaxSlippageSet` and `MaxPriceImpactSet` removed.
- Errors `MaxSlippageNotSet` and `MaxPriceImpactNotSet` removed (folded into `PairDisabled`).
- All replaced by the unified per-pair `PairLimit` model.

### Surplus return path in `_swapTokens`

- Removed: the conditional `_sendTokens(_tokenFrom, surplus, _recipient)` when the contract received more than `amountFrom`.
- The new strict-equality check (`UnexpectedTokenFromAmount`) makes any deviation a hard revert.

---

## Enforcer stack (delegation caveats)

### Old delegation caveats

- `ArgsEqualityCheckEnforcer`
- `AllowedTargetsEnforcer`
- `AllowedMethodsEnforcer`
- `AllowedCalldataEnforcer`
- `ValueLteEnforcer`

### New delegation caveats

- **`ERC20PeriodTransferEnforcer`** — rate-limits ERC20 transfers per time window (replaces the entire target/method/calldata/amount stack for ERC20 delegations).
- **`NativeTokenPeriodTransferEnforcer`** — rate-limits native transfers per time window (replaces `ValueLteEnforcer` for native delegations).
- **`RedeemerEnforcer`** — restricts who can redeem the delegation (unchanged from v1).

---

## ERC20 approval

- **Before:** `safeIncreaseAllowance(metaSwap, type(uint256).max)`.
- **After:** `forceApprove(metaSwap, type(uint256).max)` — safe for tokens (e.g. USDT) that require zeroing the allowance before setting a new non-zero value.

---

## Constructor

- **Before (v1, late):** 5 params — `_owner, _swapApiSigner, _delegationManager, _metaSwap, _argsEqualityCheckEnforcer`
- **After:** 4 params — `_owner, _swapApiSigner, _delegationManager, _metaSwap`

---

## Imports

### Added

- `ReentrancyGuard` (`@openzeppelin/contracts/utils/ReentrancyGuard.sol`)
- `IDeleGatorModule` (`./interfaces/IDeleGatorModule.sol`)

### Removed

- `ExecutionHelper` (`@erc7579/core/ExecutionHelper.sol`)
- `CallType, ExecType` (`../utils/Types.sol`)
- `CALLTYPE_SINGLE, EXECTYPE_DEFAULT` (`../utils/Constants.sol`)

---

## Errors

### Added

- `CallerNotAllowed()`
- `InvalidPercent(uint256 percent)`
- `SlippageExceedsCap(IERC20 tokenFrom, IERC20 tokenTo, uint256 signedSlippage, uint256 cap)`
- `PriceImpactExceedsCap(IERC20 tokenFrom, IERC20 tokenTo, uint256 signedPriceImpact, uint256 cap)`
- `PairDisabled(IERC20 tokenFrom, IERC20 tokenTo)`
- `RecipientResolutionFailed(address rootDelegator)`
- `UnexpectedTokenFromAmount(uint256 expected, uint256 obtained)`

### Removed

- `NotDelegationManager()`
- `NotSelf()`
- `NotLeafDelegator()`
- `UnsupportedCallType(CallType)`
- `UnsupportedExecType(ExecType)`
- `AggregatorIdIsNotAllowed(string)`
- `MissingArgsEqualityCheckEnforcer()`
- `TokenFromIsNotAllowed(IERC20)`
- `TokenToIsNotAllowed(IERC20)`
- `MaxSlippageNotSet(IERC20)`
- `MaxPriceImpactNotSet(IERC20)`
- `InsufficientTokens()`

`InvalidIdenticalTokens()` is **kept** but only emitted by `setPairLimits` (no longer by `swapByDelegation` — the pair-policy check covers that path with `PairDisabled`).

---

## Events

### Added

- `ChangedCallerStatus(address indexed caller, bool indexed status)`
- `PairLimitSet(IERC20 indexed tokenFrom, IERC20 indexed tokenTo, uint128 maxSlippage, uint128 maxPriceImpact, bool enabled)`

### Removed

- `SetArgsEqualityCheckEnforcer(address indexed)`
- `ChangedAggregatorIdStatus(bytes32 indexed, string, bool)`
- `ChangedTokenStatus` / `ChangedTokenToStatus`
- `MaxSlippageSet(IERC20 indexed, uint256)`
- `MaxPriceImpactSet(IERC20 indexed, uint256)`

---

## Gas / style polish

- Loops use `for (uint256 i = 0; i < len;) { ...; unchecked { ++i; } }`.
- Events have additional `indexed` fields where it helps off-chain indexers.
- `_delegations` switched from `memory` to `calldata`.
- `PairLimit` packed into 2 storage slots; `setPairLimits` does a single struct copy `pairLimits[k1][k2] = in_.limit;`.

---

## Deploy script (`script/DeployDelegationMetaSwapAdapter.s.sol`)

The script was rewritten to be a one-shot deploy + initial-configuration tool.

### Behavior

- Deploys with `META_SWAP_ADAPTER_OWNER_ADDRESS` as the constructor owner so the **CREATE2 address stays deterministic across chains** (same `SALT` + same args → same address).
- **Auto-configures** in the same broadcast **only if** `deployer == metaSwapAdapterOwner`. When they differ, the script just deploys and prints the exact admin calls the owner must execute (e.g. from a Safe).
- All configuration arrays are **enumerated in the logs** in three places (pre-broadcast `_logConfig`, during-broadcast `_configure`, and the manual-instructions block when applicable).

### Configuration sources

- **From env (chain-specific):** `SALT`, `META_SWAP_ADAPTER_OWNER_ADDRESS`, `DELEGATION_MANAGER_ADDRESS`, `METASWAP_ADDRESS`, `SWAPS_API_SIGNER_ADDRESS`, `ALLOWED_CALLERS` (comma-separated, may be empty).
- **Hardcoded inside the script (operator edits before deploy):**
  - `_pairLimits()` — single function returning `PairLimitInput[]` with all pair policies.
- **Native sentinel is `address(0)` only** (the deploy-script comment block above `_pairLimits` notes this).

### Other script touches

- `_validateInputs()` fail-fast checks every required address for non-zero before broadcasting.

---

## `.env.example` changes

- Removed: `ARGS_EQUALITY_CHECK_ENFORCER_ADDRESS` and the intermediate per-token cap vars (`SLIPPAGE_*`, `PRICE_IMPACT_*`, `ALLOWED_TOKENS_TO`).
- Kept: `ALLOWED_CALLERS` only (everything else moved to the hardcoded `_pairLimits()` array in the script).

---

## Tests (`test/helpers/DelegationMetaSwapAdapter.t.sol`)

### Setup helpers

- `_signSwapPayload(apiData, expiration, slippage, priceImpact)` — produces a signature for the new digest format.
- `_buildSigData` overloads:
  - `_buildSigData(apiData)` — uses default slippage / priceImpact / expiration.
  - `_buildSigData(apiData, slippage, priceImpact)`
  - `_buildSigData(apiData, expiration, slippage, priceImpact)`
- `_setPair(tokenFrom, tokenTo, maxSlippage, maxPriceImpact, enabled)` — admin convenience for a single pair.
- `_enableDefaultPairs(maxSlippage, maxPriceImpact)` — enables A↔B both directions for the bulk of mock tests.
- `_mockSafe(deleGator, safe)` — wraps `vm.mockCall(IDeleGatorModule.safe.selector)` so the `HybridDeleGator` test fixture can satisfy the new recipient-resolution path. The default mock returns the deleGator's own address so existing balance assertions on `vault.deleGator` continue to pass.
- Period-enforcer + `RedeemerEnforcer` caveats only (old enforcer instances removed).

### Pair-policy tests

- `test_revert_swapByDelegation_pairDisabled` — explicitly disabled pair reverts.
- `test_revert_swapByDelegation_pairNeverConfigured` — unconfigured pair reverts (default-zeroed `PairLimit`).
- `test_revert_swapByDelegation_identicalTokens` — identical-token swap reverts via `PairDisabled` (since `setPairLimits` rejects them and they can never be enabled).
- `test_pairLimits_directionalIndependence` — disabling B→A doesn't affect A→B.
- `test_revert_swapByDelegation_slippageExceedsCap` / `priceImpactExceedsCap` — error signatures include both tokens.
- `test_swapByDelegation_signedAtCapBoundary` — signed value exactly equal to cap is allowed.

### `setPairLimits` tests

- `test_setPairLimits_setsAndEmits`
- `test_revert_setPairLimits_ifNotOwner`
- `test_revert_setPairLimits_invalidPercent_slippage` / `priceImpact`
- `test_revert_setPairLimits_identicalTokens`
- `test_setPairLimits_emptyInputIsNoop`

### Other categories (unchanged or refreshed)

- Signature integrity (`tampered{Slippage,PriceImpact}_reverts`, expiration, invalid signer).
- Caller whitelist (5 tests + event).
- Period refill (`test_canSwapMultipleTimesWithPeriodRefill`).
- Recipient resolution (`outputRoutedToSafe`, `recipientResolutionFailed_noSafeImpl`, `recipientResolutionFailed_zeroAddress`).
- Allowance (`test_swapByDelegation_setsAllowanceToMax`).
- Constructor zero-address rejection.
- Withdraw (token + native + non-owner + failed transfer).

### Removed tests

`executeFromExecutor`, external `swapTokens`, aggregator-ID CRUD, `NotSelf`, `NotDelegationManager`, `NotLeafDelegator`, `MissingArgsEqualityCheckEnforcer`, token whitelist toggle, `_useTokenWhitelist`, all `vm.prank(address(subVault.deleGator))` patterns, `_whiteListAggregatorId` helper, all `setMaxSlippagePerToken_*` / `setMaxPriceImpactPerToken_*` tests, `test_canUpdateAllowedTokensTo*`, `test_event_ChangedTokenToStatus`, `test_swapByDelegation_anyTokenFromIsAccepted`, `test_revert_swapByDelegation_tokenToNotAllowed`, the per-token "not set" tests, and the surplus-return test (`test_swapTokens_extraTokenFromSent`).

### Other test changes

- Delegation arrays length 2 → length 1.
- Mock + fork setups now whitelist `address(this)` as caller, set the relevant pair limit, and mock `safe()` on `vault.deleGator`.
- `_whiteListAggregatorId` replaced with `_whiteListCaller`.
- All `setCaps`/`updateAllowedTokensTo` helper usages replaced with `_setPair`/`_enableDefaultPairs`.

---

## Files added in v2

- `src/helpers/interfaces/IDeleGatorModule.sol`

## Files removed in v2

- None (the contract removed features but no source files were deleted).
