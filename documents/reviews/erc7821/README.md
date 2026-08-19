# ERC-7821 Implementation Review and Remediation Tracker

Date: 2026-08-12

Status: Open

## Scope

This review covers:

- `src/interfaces/IERC7821.sol`
- `src/EIP7702/EIP7702DeleGatorCore.sol`
- `src/EIP7702/EIP7702MultiManagerDeleGatorCore.sol`
- `src/EIP7702/EIP7702StatelessDeleGator.sol`
- `src/EIP7702/EIP7702MultiManagerDeleGator.sol`
- `src/EIP7702/EIP7702BatchDeleGator.sol`
- `src/interfaces/IEIP7702BatchDeleGator.sol`
- `lib/erc7579-implementation/src/core/ExecutionHelper.sol`
- `lib/erc7579-implementation/src/lib/ExecutionLib.sol`

The comparison baseline is OpenZeppelin's `draft-ERC7821.sol` and the current ERC-7821 draft.

## Executive Decision

Do not make the existing EIP-7702 cores inherit OpenZeppelin's `ERC7821` implementation directly.

OpenZeppelin's implementation is a good reference and a reasonable base for a dedicated, minimal ERC-7821 account. It is
not a drop-in replacement for the current cores because the current `execute(ModeCode,bytes)` function also serves broader
ERC-7579 and ERC-4337 behavior:

- single and batch calls;
- revert and try execution types;
- calls from the EntryPoint;
- delegation execution through `executeFromExecutor`.

OpenZeppelin's implementation intentionally supports only batch/default execution and always decodes the data as a batch.
Inheriting it without redesigning the execution surface would break the existing single and try UserOperation paths.

The recommended approach is to keep a local account-specific router, port the relevant OpenZeppelin safety checks and
utilities, and make the ERC-7821 and ERC-7579 responsibilities explicit. A separate minimal account variant may inherit
OpenZeppelin's implementation if only strict ERC-7821 behavior is needed.

## OpenZeppelin Dependency Constraint

The repository currently vendors OpenZeppelin Contracts `5.0.2`. That version does not contain
`contracts/account/extensions/draft-ERC7821.sol`.

Direct inheritance therefore requires one of:

1. upgrading the OpenZeppelin submodule to a release containing the draft implementation;
2. vendoring the draft implementation and its ERC-7579 utilities locally; or
3. waiting for a stable OpenZeppelin release.

Upgrading the complete OpenZeppelin dependency solely for this draft contract creates unnecessary migration and audit
scope. Copying only the required validation behavior into the local execution layer is currently the lower-risk option.

## ERC-7821 and ERC-7579 Compatibility

There is no ABI-level conflict. Both standards use:

```solidity
execute(bytes32 mode, bytes executionData)
```

`ModeCode` is a user-defined wrapper around `bytes32`, so it has the same ABI selector.

There is a semantic conflict in the current design:

- ERC-7821 defines standardized batch/default modes and standardized discovery through `supportsExecutionMode`.
- The local implementation uses the same functions to expose additional ERC-7579 single and try modes.
- OpenZeppelin's base always executes a batch with default revert behavior, even if a child were to report another mode as
  supported.

Overriding only OpenZeppelin's `supportsExecutionMode` is therefore unsafe. Its inherited `execute` would still decode every
accepted mode as a default batch. Supporting local single or try modes would require overriding `execute` as well, which
removes most of the benefit of inheriting the implementation.

## Recommended Architecture

Use one internal mode router shared by the externally exposed execution paths:

```text
execute(mode, data)
    -> authorize caller
    -> classify and validate the complete mode
    -> decode according to the classified mode
    -> execute

executeFromExecutor(mode, data)
    -> authorize DelegationManager
    -> classify and validate the complete mode
    -> decode according to the classified mode
    -> execute
```

Recommended separation:

1. `execute(bytes32,bytes)` implements the ERC-7821 modes the account publicly claims.
2. `executeFromExecutor` retains the broader ERC-7579 modes required by the DelegationManager.
3. If EntryPoint UserOperations still need single/try execution through the same `execute` selector, explicitly document
   this as an extension and add exact execution/discovery consistency tests.
4. Route signed `opData` and batch-of-batches through the standard `execute` selector on
   `EIP7702BatchDeleGator`; do not expose them only through `executeBatch`.

If strict ERC-7821 discovery is required, move non-ERC-7821 EntryPoint modes to a separate account-specific entrypoint.

## Findings

### F-01: Execution accepts modes reported as unsupported

Severity: Medium

Status: [ ] Open

Affected code:

- `EIP7702DeleGatorCore.execute`
- `EIP7702DeleGatorCore.executeFromExecutor`
- `EIP7702MultiManagerDeleGatorCore.execute`
- `EIP7702MultiManagerDeleGatorCore.executeFromExecutor`

The execution functions decode only `callType` and `execType`. They discard `modeSelector` and `modePayload`.
`supportsExecutionMode` checks those fields, but it is never enforced by execution.

Consequences:

- a mode may return `false` from `supportsExecutionMode` and still execute;
- an ERC-7821 `opData` selector may be interpreted as an ordinary batch;
- future selectors can silently receive the wrong execution semantics.

Suggested fix:

- add one internal mode-classification function;
- reject unknown classifications before decoding execution data;
- use the same classification logic for execution and discovery;
- do not duplicate mode checks between the two EIP-7702 cores.

Verification:

- [ ] A mode with an unsupported selector reverts before any target call.
- [ ] A mode with an unsupported call or execution type reverts.
- [ ] Every mode returning `true` from discovery executes with the documented decoder and failure behavior.
- [ ] Every mode returning `false` is rejected by the corresponding public execution surface.

### F-02: The local `IERC7821` describes ERC-7579 extensions as ERC-7821 modes

Severity: Medium

Status: [ ] Open

`src/interfaces/IERC7821.sol` documents single/default, single/try, batch/default, and batch/try. ERC-7821 standardizes
batch/default modes, with optional `opData` and batch-of-batches selectors.

Suggested fix:

- replace the local interface with the upstream-compatible IERC7821 signature and documentation;
- document additional ERC-7579 modes on an account-specific or ERC-7579 interface;
- decide whether strict ERC-7821 discovery or extended account discovery is required;
- make that decision explicit in tests and public documentation.

Verification:

- [ ] The interface documents `abi.encode(Execution[])`.
- [ ] Optional `opData` encoding is documented only where implemented.
- [ ] Single and try modes are not described as standardized ERC-7821 modes.
- [ ] Interface ABI compatibility with `execute(bytes32,bytes)` is preserved.

### F-03: `EIP7702BatchDeleGator` exposes ERC-7821 relay modes under custom selectors

Severity: Medium

Status: [ ] Open

Implementation brief / priority decision: [relay-execute-surface.md](./relay-execute-surface.md)

The signed relay implementation uses:

- `executeBatch(bytes32,bytes)`;
- `supportsBatchExecutionMode(bytes32)`.

Standard clients use:

- `execute(bytes32,bytes)`;
- `supportsExecutionMode(bytes32)`.

The account therefore cannot expose or discover its signed `opData` and batch-of-batches functionality through the
standard ERC-7821 surface.

Suggested fix:

- make the core execution functions overridable;
- override the standard `execute` and `supportsExecutionMode` functions in `EIP7702BatchDeleGator`;
- route simple batch, signed `opData`, and batch-of-batches modes through those functions;
- retain `executeBatch` only as a deprecated compatibility alias if an existing integration requires it.

Verification:

- [ ] A generic IERC7821 caller can discover the implemented relay modes.
- [ ] A generic IERC7821 caller can submit signed `opData`.
- [ ] Batch-of-batches is available through `execute(bytes32,bytes)`.
- [ ] Empty `opData` uses self or explicitly authorized EntryPoint access.
- [ ] Non-empty `opData` validates the signature, nonce, deadline, and optional relayer.

### F-04: Try execution reverses the success flag

Severity: Medium

Status: [ ] Open

`ExecutionHelper._tryExecute` currently uses:

```solidity
success := iszero(call(...))
```

The EVM `call` opcode returns `1` on success and `0` on failure. Applying `iszero` reverses the meaning.

Consequences:

- successful calls emit `TryExecuteUnsuccessful`;
- failed calls do not emit the failure event;
- internal consumers receive the wrong success value.

Suggested fix:

```solidity
success := call(gas(), target, value, result, callData.length, codesize(), 0x00)
```

Verification:

- [ ] Successful single try execution does not emit `TryExecuteUnsuccessful`.
- [ ] Failed single try execution emits `TryExecuteUnsuccessful(0, revertData)`.
- [ ] Batch try execution emits only for failed indexes.
- [ ] Revert data is preserved.

### F-05: Batch decoding lacks explicit bytes-slice bounds checks

Severity: Low

Status: [ ] Open

`ExecutionLib.decodeBatch` trusts the embedded array offset and length. OpenZeppelin's current ERC-7579 utility checks:

- minimum input length;
- array offset bounds;
- array length bounds;
- element pointers;
- nested calldata bounds relative to the supplied bytes slice.

The local decoder is used by account execution and caveat enforcers. Access control and canonical ABI re-encoding mitigate
many current call paths, but malformed calldata should not be able to make the decoder read outside the supplied bytes
slice.

Suggested fix:

- port OpenZeppelin's current `decodeBatch` validation;
- use a custom decoding error;
- add fuzz tests for malformed offsets, lengths, element pointers, and trailing calldata;
- retain assembly only after the complete slice bounds are proven.

Verification:

- [ ] Empty and truncated data revert with the decoding error.
- [ ] Array offsets outside the bytes slice revert.
- [ ] Element calldata extending outside the bytes slice reverts.
- [ ] Appended calldata cannot be referenced through an out-of-slice pointer.
- [ ] Valid canonical batches continue to decode.

### F-06: Zero-address targets differ from OpenZeppelin behavior

Severity: Low

Status: [ ] Open

OpenZeppelin's execution utility maps a zero target to `address(this)`. The shared local `ExecutionHelper` calls
`address(0)` directly. `EIP7702BatchDeleGator` already performs the substitution in its custom batch path.

The current ERC-7821 draft permits, but does not require, this substitution. This is therefore an interoperability choice,
not a strict conformance failure.

Suggested fix:

- choose one behavior for every execution path;
- prefer `address(0) -> address(this)` for OpenZeppelin and wallet interoperability;
- document the behavior;
- apply it to both default and try execution.

Verification:

- [ ] Zero-target behavior is identical across inherited execute, manager execution, and signed batch execution.
- [ ] Self-calls with value and calldata are tested.

### F-07: ERC-7821 conformance coverage is missing

Severity: Medium

Status: [ ] Open

Existing tests validate the current ERC-7579 behavior. The signed batch implementation has benchmark happy paths but no
complete conformance and negative test suite.

Add tests for:

- [ ] exact simple-batch mode discovery;
- [ ] complete execution/discovery consistency;
- [ ] unsupported selectors and execution types;
- [ ] simple batch atomic rollback;
- [ ] standard `opData` encoding;
- [ ] valid and invalid signatures;
- [ ] expired authorization;
- [ ] relayer restriction;
- [ ] nonce replay and nonce invalidation;
- [ ] batch-of-batches;
- [ ] zero target behavior;
- [ ] malformed batch encoding;
- [ ] try execution event polarity;
- [ ] both EIP-7702 cores and every concrete child.

## Non-Issues

### `ModeCode` instead of `bytes32`

`ModeCode` wraps `bytes32` and is ABI-compatible. It does not change the function selector.

### EntryPoint authorization

ERC-7821 permits an authorized EntryPoint to call execution. `onlyEntryPointOrSelf` is not itself a defect.
`EIP7702MultiManagerDeleGatorCore` intentionally has no EntryPoint path.

### Payable execution

The public execution functions being payable is consistent with account execution. Inner call values come from the
account's balance and are not required to equal `msg.value`.

### Additional ERC-7579 functionality

Single and try execution can be useful extensions. The defect is not their existence; it is mixing their discovery and
execution semantics with ERC-7821 without an explicit, consistently enforced contract.

## Remediation Order

1. Fix F-04, because it is an independent execution correctness bug.
2. Decide the public ERC-7821 versus ERC-7579 execution architecture.
3. Fix F-01 and F-02 using one shared mode classifier.
4. Route `EIP7702BatchDeleGator` through the standard selectors for F-03.
5. Harden batch decoding for F-05.
6. Standardize zero-target behavior for F-06.
7. Complete the conformance suite in F-07.

## Completion Criteria

This review can be marked complete when:

- [ ] all findings are checked as fixed or explicitly accepted;
- [ ] every accepted deviation is documented as intentional;
- [ ] standard ERC-7821 clients can discover and execute every claimed ERC-7821 mode;
- [ ] execution rejects modes that are not supported by the relevant execution surface;
- [ ] signed relay behavior uses the standard ERC-7821 selectors;
- [ ] malformed execution data cannot escape its bytes slice;
- [ ] the complete relevant Foundry test suite passes;
- [ ] static analysis reports no new execution-path findings.

## References

- OpenZeppelin `draft-ERC7821.sol`:
  <https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/account/extensions/draft-ERC7821.sol>
- OpenZeppelin `draft-ERC7579Utils.sol`:
  <https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/account/utils/draft-ERC7579Utils.sol>
- ERC-7821:
  <https://eips.ethereum.org/EIPS/eip-7821>
- ERC-7579:
  <https://eips.ethereum.org/EIPS/eip-7579>
