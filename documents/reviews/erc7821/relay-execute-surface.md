# EIP7702BatchDeleGator Relay Surface: `executeBatch` vs Standard `execute`

Date: 2026-08-13

Status: Decision pending

Related: [README.md](./README.md) findings **F-01**, **F-02**, **F-03**

## Purpose

This document is implementation context for whether and how to move signed-relay batch execution from the custom
`executeBatch(bytes32,bytes)` selector onto the standard ERC-7821 `execute(bytes32,bytes)` surface.

Use it to decide priority, then as the brief for implementing the change if approved.

## Decision Question

Should we touch the inherited `execute` / `supportsExecutionMode` path so `EIP7702BatchDeleGator` exposes relay modes
through standard IERC7821 selectors?

| Option                                                                      | Summary                                                                                                                                                                      |
| --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A. Keep `executeBatch` (status quo)**                                     | Signed relay stays on a child-only selector. 4337/self/`executeFromExecutor` remain untouched. Not IERC7821-compatible for `opData` / batch-of-batches discovery.            |
| **B. Route relay through standard `execute` (recommended for conformance)** | Make core `execute` / `supportsExecutionMode` overridable; child classifies modes and applies mode-gated auth. Keep `executeBatch` only as an alias if integrations need it. |

This is an interoperability / architecture change, not a critical security hotfix. Prefer Option B when ERC-7821 client
compatibility matters; defer if current integrations only call `executeBatch` and higher-severity execution bugs are open.

## Priority Guidance

### Do this now if

- wallet / indexer / SDK clients are expected to call generic `IERC7821.execute` and discover modes via
  `supportsExecutionMode`;
- the account is being positioned as ERC-7821-conformant for signed `opData` and batch-of-batches;
- you are already opening `EIP7702DeleGatorCore` for F-01 (mode classification) and can fold F-03 into the same change.

### Defer if

- no external IERC7821 caller needs signed relay yet;
- F-04 (try-execution success polarity) and F-01 (unsupported modes still execute) are still open — fix those first;
- you want to avoid making core `execute` virtual until the shared mode router design is settled.

### Suggested order relative to the review tracker

1. **F-04** — independent correctness bug; do first.
2. **Architecture decision** — this document (Option A vs B).
3. **F-01 + F-02** — shared mode classifier + honest IERC7821 docs.
4. **F-03** — this relay-surface change (requires the classifier from F-01 if done cleanly).
5. F-05 / F-06 / F-07.

**Recommendation:** treat F-03 as medium priority and **do not** implement it in isolation. Bundle it with F-01 so auth,
decode, and discovery share one mode classifier. Leaving `executeBatch` forever is an accepted deviation only if
documented as intentional in the review README.

---

## Current Behavior (Why `executeBatch` Exists)

### Two execution surfaces today

```text
Inherited (EIP7702DeleGatorCore)
  execute(ModeCode, bytes)
    modifier: onlyEntryPointOrSelf
    decode: ERC-7579 packed single / abi.encode(Execution[]) batch
    modes: callType + execType only; modeSelector ignored at execution
    discovery: supportsExecutionMode -> MODE_DEFAULT + zero payload only

Child-only (EIP7702BatchDeleGator)
  executeBatch(bytes32, bytes)
    auth: empty opData => msg.sender == address(this)
          non-empty opData => EIP-712 sig + unordered nonce + deadline + optional relayer
    decode: abi.encode(Execution[]) | abi.encode(Execution[], bytes) | abi.encode(bytes[])
    modes: MODE_BATCH_SIMPLE / MODE_BATCH_WITH_OPDATA / MODE_BATCH_OF_BATCHES
    discovery: supportsBatchExecutionMode (custom; not IERC7821)
```

`executeFromExecutor` stays DelegationManager-only and is **out of scope** for relay. Do not wire signed `opData` through
it.

### Why a separate selector was required

1. **Auth conflict.** Parent `execute` is `onlyEntryPointOrSelf`. Relayers are arbitrary EOAs/contracts. They cannot pass
   that modifier. Relay auth is the opposite model: anyone may call if `opData` verifies.
2. **Decode conflict.** Parent uses ERC-7579 `ExecutionLib.decodeBatch()` (packed layout assumptions for single;
   `abi.encode(Execution[])` for batch). Relay `0x78210001` uses `abi.encode(Execution[], bytes)`. Feeding that through
   the parent decoder mis-interprets or silently mishandles `opData`.
3. **Discovery conflict.** Parent `supportsExecutionMode` only accepts `MODE_DEFAULT` and zero payload. Relay modes use
   selectors `0x78210001` and `0x78210002`, and are intentionally excluded from inherited discovery.
4. **Override impossible today.** Parent `execute(ModeCode,bytes)` is **not** `virtual`, so the child cannot override it.
   `executeBatch` is the workaround.

Relevant code:

- `src/EIP7702/EIP7702DeleGatorCore.sol` — `execute`, `supportsExecutionMode`, `onlyEntryPointOrSelf`
- `src/EIP7702/EIP7702BatchDeleGator.sol` — `executeBatch`, `_routeBatchCalldata`, `_authorizeAndExecuteBatch`
- `src/interfaces/IEIP7702BatchDeleGator.sol` — documents the split explicitly

---

## How Other Smart Accounts Handle Relays

ERC-7821 expects **one** public entrypoint:

```solidity
function execute(bytes32 mode, bytes calldata executionData) external payable;
function supportsExecutionMode(bytes32 mode) external view returns (bool);
```

Authorization is **inside** `execute`, gated by mode / `opData`, not a second selector.

### ERC-7821 draft semantics

- Empty `opData`: SHOULD require `msg.sender == address(this)`.
- Non-empty `opData`: SHOULD use signature (or other auth) encoded in `opData`.
- Authorized EntryPoint: MAY call `execute`; MAY use `opData` for specialized logic.
- Zero target: MAY map `address(0)` → `address(this)`.

### OpenZeppelin `draft-ERC7821`

- Single public `execute(bytes32,bytes)`.
- No custom `executeBatch` for 7821 modes.
- Access via overridable `_erc7821AuthorizedExecutor` (default: self only; override to allow EntryPoint).
- Current OZ draft often supports only simple batch without `opData`; still uses the standard selector.
- Repo vendors OZ `5.0.2`, which does **not** include this draft — do not inherit OZ `ERC7821` into existing cores
  (see README executive decision). Use it as a reference for auth hooks and mode checks only.

### Solady / EIP sample pattern

Classify mode → decode accordingly → `_execute(calls, opData)` where empty `opData` requires self and non-empty runs
custom auth. Same selector for everything.

**Bottom line:** serious 7821 accounts do not expose signed relay on a parallel `executeBatch(bytes32,bytes)`. The local
split is a DeleGator-specific workaround, not industry practice.

---

## Target Design (Option B)

### Goals

1. Generic IERC7821 callers can discover and submit `78210001` / `78210002` through standard selectors.
2. Existing EntryPoint / self UserOp paths for 7579 single, try, and default batch keep working unchanged.
3. `executeFromExecutor` remains DelegationManager-only and unchanged in auth.
4. Mode classification is shared between execution and discovery (ties to F-01).
5. `executeBatch` becomes a thin alias (or is removed after a deprecation window).

### Mode routing (conceptual)

```text
execute(mode, data)
  id = classify(mode)

  if id in { opData batch, batch-of-batches }:
      // public relay surface
      auth via opData (or self for empty opData on allowed modes)
      decode abi.encode layouts for 7821
      execute calls
      return

  // legacy / 7579 account surface
  require msg.sender == entryPoint || msg.sender == address(this)
  decode 7579 layouts
  execute with existing callType/execType behavior
```

Do **not** remove `onlyEntryPointOrSelf` for 7579 modes. Only relay modes get the open-caller + `opData` model.

### Core changes (`EIP7702DeleGatorCore` and MultiManager twin if applicable)

1. Make `execute(ModeCode,bytes)` and `supportsExecutionMode(ModeCode)` `virtual`.
2. Extract the current 7579 body into an internal helper **without** the modifier, e.g. `_execute7579(ModeCode, bytes)`.
3. Keep the public parent `execute` as:

```solidity
function execute(ModeCode _mode, bytes calldata _executionCalldata)
    external
    payable
    virtual
    onlyEntryPointOrSelf
{
    _execute7579(_mode, _executionCalldata);
}
```

4. Prefer introducing the shared mode classifier from F-01 in the same PR so children do not re-implement mode parsing.

Also update `EIP7702MultiManagerDeleGatorCore` the same way if it shares the non-virtual `execute` pattern, even if the
batch child only inherits the single-manager core.

### Child override sketch (`EIP7702BatchDeleGator`)

```solidity
function execute(ModeCode mode, bytes calldata data) external payable override {
    uint256 id = _batchExecutionModeId(bytes32(ModeCode.unwrap(mode)));

    // ERC-7821 relay modes: open caller; auth inside router
    if (id == 2 || id == 3) {
        _routeBatchCalldata(bytes32(ModeCode.unwrap(mode)), data);
        return;
    }

    // Optional: also accept id == 1 (simple batch) here with self/EP rules,
    // or leave simple batch on the 7579 path. Pick one and document it.
    // If id == 1 is accepted on the relay router with empty opData, require
    // msg.sender == address(this) (and EntryPoint only if intentionally allowed).

    if (msg.sender != address(entryPoint) && msg.sender != address(this)) {
        revert NotEntryPointOrSelf();
    }
    _execute7579(mode, data);
}

function supportsExecutionMode(ModeCode mode) external view override returns (bool) {
    uint256 id = _batchExecutionModeId(bytes32(ModeCode.unwrap(mode)));
    if (id == 2 || id == 3) return true;
    // plus existing 7579 MODE_DEFAULT checks (or super if extracted)
    ...
}

function executeBatch(bytes32 mode, bytes calldata executionData) external payable {
    // Compatibility alias — same semantics as execute
    this.execute(ModeCode.wrap(mode), executionData); // prefer internal call to avoid extra external frame
    // Better: _routeBatchCalldata / shared internal entry used by both
}
```

Prefer a shared internal entry used by both `execute` and the alias so aliasing does not add an external self-call or
re-enter auth incorrectly.

### Auth matrix (must hold after change)

| Mode                              | Caller                          | `opData`                                 | Allowed?                                                      |
| --------------------------------- | ------------------------------- | ---------------------------------------- | ------------------------------------------------------------- |
| 7579 single / try / default batch | EntryPoint                      | n/a (7579 encoding)                      | Yes                                                           |
| 7579 single / try / default batch | Self                            | n/a                                      | Yes                                                           |
| 7579 single / try / default batch | Arbitrary                       | n/a                                      | **No**                                                        |
| `78210001`                        | Arbitrary                       | Valid sig + nonce + deadline (+ relayer) | Yes                                                           |
| `78210001`                        | Arbitrary                       | Empty                                    | **No** (unless caller is self; EP only if explicitly allowed) |
| `78210001`                        | Self                            | Empty                                    | Yes                                                           |
| `78210002`                        | Same as nested batches          | Nested payloads                          | Yes after each nested auth                                    |
| Any mode                          | DelegationManager via `execute` | —                                        | **No** — DM uses `executeFromExecutor`                        |

### Discovery matrix

| Mode                    | `supportsExecutionMode`                | Notes                                          |
| ----------------------- | -------------------------------------- | ---------------------------------------------- |
| 7579 single/try/default | `true` if still claimed by the account | Document as 7579 extension if kept on IERC7821 |
| `78210001` / `78210002` | `true` on BatchDeleGator               | Must match what `execute` accepts              |
| Unknown selector        | `false`                                | And `execute` must revert (F-01)               |

---

## Risks to Self / EntryPoint Flows

### Safe if done correctly

Self-calls and UserOps that already call `execute(ModeCode,bytes)` with 7579 single / try / default-batch encodings never
enter the `78210001` / `78210002` branch. Behavior stays: EntryPoint-or-self gate → existing decoder → existing execute
helpers.

`executeFromExecutor` is separate and should not be overridden for relay.

### Failure modes that _would_ break or drain

1. **Opening all modes to any caller.** Dropping `onlyEntryPointOrSelf` without mode gating lets anyone send
   `CALLTYPE_SINGLE` steal executions.
2. **Using one decoder for all batches.** Treating every batch as `abi.encode(Execution[], bytes)` breaks existing
   UserOps that use 7579 layouts.
3. **Letting empty-`opData` simple batch be world-callable.** Same mode EP/self already use for batches. Empty `opData`
   must remain self (and EP only if intentional).
4. **Advertising relay modes in `supportsExecutionMode` but still requiring EntryPoint.** Clients discover support and
   always revert — worse UX than the current custom selector.
5. **Aliasing `executeBatch` → external `execute` carelessly.** Extra self-call can change `msg.sender` mid-flow; use a
   shared internal function.

### Non-risks

- Making `execute` `virtual` does not change parent behavior until a child overrides.
- Keeping `executeBatch` as an alias does not weaken auth if it calls the same internal router.
- EntryPoint calling `78210001` with valid `opData` is allowed by the EIP; decide policy explicitly (recommend: treat
  EntryPoint like any other caller for relay modes — still require valid `opData` unless empty and you intentionally
  special-case EP).

---

## What Not To Do

- Do **not** inherit OpenZeppelin `ERC7821` into `EIP7702DeleGatorCore` as a drop-in (breaks single/try; OZ version pin).
- Do **not** put signed relay auth on `executeFromExecutor`.
- Do **not** claim `78210001` / `78210002` on `supportsExecutionMode` without accepting them in `execute`.
- Do **not** implement F-03 without aligning discovery/execution (F-01).
- Do **not** change MultiManager / Stateless children unless they inherit the same virtual surface and need the same
  override.

---

## Files To Touch (Implementation Checklist)

### Required for Option B

- [ ] `src/EIP7702/EIP7702DeleGatorCore.sol` — `virtual` execute / supportsExecutionMode; extract `_execute7579`
- [ ] `src/EIP7702/EIP7702MultiManagerDeleGatorCore.sol` — same virtual/extract pattern for consistency
- [ ] `src/EIP7702/EIP7702BatchDeleGator.sol` — override execute + supportsExecutionMode; alias or deprecate executeBatch
- [ ] `src/interfaces/IEIP7702BatchDeleGator.sol` — document standard selectors; mark executeBatch as alias/deprecated
- [ ] `src/interfaces/IERC7821.sol` — align docs with F-02 if touched in same PR

### Tests

- [ ] Existing 4337 / self execute paths still pass (single, batch, try)
- [ ] Existing `executeFromExecutor` / delegation paths still pass
- [ ] Relayer can call `execute(MODE_BATCH_WITH_OPDATA, abi.encode(execs, opData))` without being EntryPoint
- [ ] Relayer **cannot** call 7579 single/batch modes on `execute`
- [ ] Empty `opData` on relay mode requires self (negative test for random caller)
- [ ] Invalid sig / expired deadline / bad relayer / reused nonce revert
- [ ] `supportsExecutionMode` true iff execute accepts for claimed modes
- [ ] If alias retained: `executeBatch` ≡ `execute` for relay modes
- [ ] Benchmarks in `test/Erc7821BaselineBenchmark.t.sol` updated to preferred selector

### Docs / review tracker

- [ ] Mark F-03 fixed or accepted in [README.md](./README.md)
- [ ] Update NatSpec on BatchDeleGator that currently says relay uses child-only `executeBatch`

---

## Acceptance Criteria

Option B is done when:

1. A generic IERC7821 client can discover `78210001` and `78210002` via `supportsExecutionMode`.
2. The same client can submit signed `opData` via `execute(bytes32,bytes)` (ABI-compatible with `ModeCode`).
3. EntryPoint/self 7579 UserOps behave as before (gas may differ slightly; semantics identical).
4. Arbitrary callers cannot execute 7579 modes through `execute`.
5. Signed relay still enforces signature, unordered nonce, deadline, and optional relayer.
6. `executeFromExecutor` auth and decoding are unchanged.
7. Any remaining `executeBatch` is documented as a compatibility alias with identical semantics, or removed.

Option A (accept deviation) is done when:

1. README F-03 is marked accepted with rationale: integrations use `executeBatch` only; IERC7821 discovery for relay is
   out of scope for now.
2. NatSpec clearly states relay is non-standard-selector.
3. No false claim that the account is fully ERC-7821 conformant for `opData`.

---

## Implementation Notes / Pitfalls

- `ModeCode` is a user-defined value type over `bytes32`; selector of `execute(ModeCode,bytes)` equals
  `execute(bytes32,bytes)`.
- Parent currently ignores `modeSelector` at execution (F-01). After override, BatchDeleGator **must** classify before
  decode or `78210001` calldata could be fed into `decodeBatch` if a caller hits the 7579 branch with that mode.
- Child `_executeExecutions` already maps `target == address(0)` → `address(this)`; inherited path may not (F-06). Do not
  silently unify in this PR unless intended.
- Unordered nonce storage is namespaced under the batch child; moving the entrypoint does not move storage if logic stays
  in the child.
- Gas: one extra mode-id check on the hot EP path is acceptable; avoid external self-calls for the alias.

---

## Open Product Decisions (Resolve Before Coding)

1. **Does EntryPoint get a free pass on empty-`opData` relay modes?** Recommend: no free pass; EP may call relay modes
   only with valid `opData`, or use 7579 modes for UserOps.
2. **Is `MODE_BATCH_SIMPLE` (`0x0100…00`) handled by the relay router or only by the 7579 path?** Overlap exists with
   existing batch UserOps. Prefer one owner for that mode and document it.
3. **Keep `executeBatch` alias?** Keep if any off-chain code already targets it (see benchmarks); otherwise remove to
   shrink surface.
4. **Strict IERC7821 discovery vs extended 7579 discovery on the same function?** Ties to F-02. Either document
   extensions explicitly or move single/try off `supportsExecutionMode`.

---

## References

- Review tracker: [README.md](./README.md)
- ERC-7821: <https://eips.ethereum.org/EIPS/eip-7821>
- ERC-7579: <https://eips.ethereum.org/EIPS/eip-7579>
- OpenZeppelin `draft-ERC7821.sol`:
  <https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/account/extensions/draft-ERC7821.sol>
- Local implementation:
  - `src/EIP7702/EIP7702BatchDeleGator.sol`
  - `src/interfaces/IEIP7702BatchDeleGator.sol`
  - `src/EIP7702/EIP7702DeleGatorCore.sol`
  - `src/interfaces/IERC7821.sol`
