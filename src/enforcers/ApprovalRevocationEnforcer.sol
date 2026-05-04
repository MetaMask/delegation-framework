// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ApprovalRevocationEnforcer
 * @notice Allows a delegate to clear existing token approvals. The delegator controls which revocation
 * primitives the delegate may perform via a 1-byte bitmask in `terms`:
 *
 *   Bit 0 (`0x01`) — ERC-20 `approve(spender, 0)` (spender non-zero, amount zero)
 *   Bit 1 (`0x02`) — ERC-721 per-token `approve(address(0), tokenId)`
 *   Bit 2 (`0x04`) — ERC-721 / ERC-1155 `setApprovalForAll(operator, false)`
 *   Bit 3 (`0x08`) — Permit2 `approve(token, spender, 0, 0)` against the canonical Permit2 deployment
 *   Bit 4 (`0x10`) — Permit2 `lockdown((address,address)[])` against the canonical Permit2 deployment
 *   Bit 5 (`0x20`) — Permit2 `invalidateNonces(token, spender, newNonce)` against the canonical Permit2 deployment
 *   Bits 6-7       — Reserved; MUST be zero.
 *
 * Examples:
 *   `0x01` — delegate may only clear ERC-20 allowances.
 *   `0x04` — delegate may only revoke operator approvals.
 *   `0x08` — delegate may only revoke a single Permit2 allowance per call.
 *   `0x10` — delegate may only batch-revoke Permit2 allowances via `lockdown`.
 *   `0x20` — delegate may only invalidate Permit2 nonces (kill pending signed permits).
 *   `0x38` — delegate may use all three Permit2 primitives (`approve` + `lockdown` + `invalidateNonces`),
 *           which together fully sever a Permit2 (token, spender) exposure (on-chain allowance + pending
 *           signed permits).
 *   `0x3F` — delegate may use all six revocation primitives.
 *
 * Terms MUST be exactly 1 byte, MUST not be zero, and MUST NOT set any reserved bit.
 *
 * @dev ERC-721 and ERC-1155 intentionally share the `setApprovalForAll(address,bool)` selector; this enforcer
 * handles both via the `IERC721` interface (the selector and ABI are identical, so a typed `IERC1155` import is
 * unnecessary for the external call). ERC-20 and ERC-721 likewise share the `approve(address,uint256)` selector,
 * and are disambiguated by inspecting the first parameter (see branching rules below).
 *
 * @dev The execution must transfer zero native value and carry one of the supported approval calldatas. Branching
 * is determined as follows:
 * - selector `approve(address token, address spender, uint160 amount, uint48 expiration)` (Permit2):
 *   - `target` MUST equal the canonical Permit2 deployment (`_PERMIT2`), and
 *   - calldata length MUST be 132 bytes (4-byte selector + four 32-byte words), and
 *   - the third parameter (amount) MUST be zero, and
 *   - the fourth parameter (expiration) MUST be zero.
 * - selector `lockdown((address,address)[])` (Permit2):
 *   - `target` MUST equal the canonical Permit2 deployment (`_PERMIT2`).
 *   - The calldata is otherwise unconstrained: every entry of the array structurally forces the corresponding
 *     `(token, spender)` Permit2 allowance `amount` to zero (`expiration` and `nonce` are left untouched). There
 *     is no parameter the delegate could supply to grant new authority, so no further calldata validation is
 *     performed.
 * - selector `invalidateNonces(address,address,uint48)` (Permit2):
 *   - `target` MUST equal the canonical Permit2 deployment (`_PERMIT2`).
 *   - The calldata is otherwise unconstrained: Permit2's `invalidateNonces` strictly monotonically increases the
 *     stored nonce for the `(caller, token, spender)` triple (it reverts if `newNonce <= oldNonce` and caps the
 *     per-call delta at `type(uint16).max`). It cannot create or extend an allowance, so no further calldata
 *     validation is performed.
 * - calldata length 68 bytes (4-byte selector + two 32-byte words), shared by `approve(address,uint256)` and
 *   `setApprovalForAll(address,bool)`:
 *   - selector `setApprovalForAll(address operator, bool approved)`:
 *     - `approved` MUST be false, and
 *     - `isApprovedForAll(delegator, operator)` MUST currently be true on the target.
 *   - selector `approve(address, uint256)` (shared by ERC-20 and ERC-721):
 *     - if the first parameter is `address(0)` the call is treated as an ERC-721 per-token revocation:
 *       - `getApproved(tokenId)` on the target MUST currently return a non-zero address.
 *     - otherwise the call is treated as an ERC-20 revocation:
 *       - the second parameter (amount) MUST be zero, and
 *       - `allowance(delegator, spender)` on the target MUST currently return non-zero.
 *
 * @dev All six accepted calldatas structurally result in a net reduction of permissions on the target (amount
 * `0`, spender `address(0)`, `approved` `false`, per-pair Permit2 amount zeroing, or strictly monotonic Permit2
 * nonce bump). A delegate using this enforcer can therefore never be granted new authority over the delegator's
 * assets — only existing approvals can be cleared and pending Permit2 signatures invalidated.
 *
 * @dev Unlike the ERC-20 / ERC-721 / `setApprovalForAll` primitives, the three Permit2 branches perform no
 * on-chain liveness pre-check. The structural constraints (canonical Permit2 target, fixed selector, and — for
 * `approve` — zero amount and zero expiration) already guarantee the call can only reduce permissions; if no
 * Permit2 state exists for the targeted `(token, spender)` pair(s) the execution is either a harmless no-op or
 * (for `invalidateNonces`) reverts inside Permit2. Restrict which pairs the delegate may target by composing
 * this enforcer with `AllowedCalldataEnforcer` or `ExactCalldataEnforcer`. Note that for `lockdown` such pinning
 * also has to fix the array length and ABI head words, since the calldata is dynamic; `ExactCalldataEnforcer`
 * is usually the cleaner option there.
 *
 * @dev Permit2 revocation surface — what each primitive does and does not cover:
 *   - `approve(token, spender, 0, 0)` zeros `amount` and sets `expiration` to `block.timestamp` for the caller's
 *     `(token, spender)` allowance. Pending signed permits are NOT invalidated (their `nonce` is unaffected).
 *   - `lockdown` zeros `amount` only. `expiration` and `nonce` are unchanged. Pending signed permits are NOT
 *     invalidated.
 *   - `invalidateNonces` strictly monotonically increases the stored `nonce`, rendering all signed-but-unredeemed
 *     `permit` payloads with a now-stale nonce uncollectable. It does NOT zero on-chain `amount` or `expiration`.
 *   To fully sever Permit2 exposure to a spender, both an on-chain allowance revocation (bit 3 or 4) AND a
 *   nonce invalidation (bit 5) are typically required. Enabling only one leaves the other vector live.
 *
 * @dev DoS surface on bit 5 (`invalidateNonces`). A delegate granted bit 5 can advance the stored nonce for any
 * `(token, spender)` pair the caveat does not pin (Permit2 caps the per-call delta at `type(uint16).max`, but a
 * determined delegate can repeat until `nonce == type(uint48).max`, after which the root delegator can no longer
 * sign new permits for that pair). This is never an authority escalation — it can only invalidate, never create —
 * but it is a denial-of-service vector for the delegator's future signed-permit flow. When granting bit 5, pin the
 * `(token, spender)` pair via `AllowedCalldataEnforcer` / `ExactCalldataEnforcer` and/or rate-limit the delegation
 * with `LimitedCallsEnforcer`.
 *
 * @dev Trust assumption — canonical Permit2 deployment.
 *
 * The Permit2 branches assume the canonical Uniswap-deployed Permit2 contract is at `_PERMIT2` on the target
 * chain. On chains where Uniswap has deployed Permit2 (mainnet, Base, Arbitrum, Optimism, Polygon, BNB, Avalanche,
 * etc.) this is a safe deterministic address. On chains where canonical Permit2 is NOT deployed:
 *   - if the address is empty, the executor's call returns successfully with no effect (harmless no-op);
 *   - if a *different* contract happens to live at that address, the selector dispatches into whatever that
 *     contract does. The `approve(0, 0)` branch is partially self-protected by its structural calldata checks
 *     (any contract under that selector would have to interpret the layout identically to grant authority), but
 *     `lockdown` and `invalidateNonces` have no such structural moat.
 * Delegators on chains without canonical Permit2 should NOT enable bits 3, 4, or 5.
 *
 * @dev REDELEGATION WARNING — link-local pre-check vs. root-level execution.
 *
 * The `_delegator` argument passed to `beforeHook` is the delegator of the specific delegation that carries the
 * caveat, not the root of a redelegation chain. The DelegationManager always executes the downstream call against
 * the *root* delegator's account (the account at the end of the leaf-to-root chain). On a root-level delegation
 * (chain length 1) the two are the same and the pre-check queries the account whose storage will actually be
 * mutated — this is the intended usage.
 *
 * On an intermediate (redelegation) link the two differ. The implications are different per primitive group:
 *
 * (a) ERC-20 / ERC-721 / `setApprovalForAll` branches — pre-check is link-local.
 *
 * The pre-check queries the *intermediate* delegator's approval state, while the execution mutates the *root*
 * delegator's storage. A redelegator adding this caveat to constrain their delegate is very likely expecting the
 * pre-check to run against the root. That expectation is wrong — the check is link-local.
 *
 * Concrete example. Alice -> Bob -> Carol. Alice's link has no caveat (Bob has full authority over Alice).
 * Bob places this enforcer on his delegation to Carol, intending "Carol can only revoke an existing approval on
 * Alice's account". When Carol redeems, the hook fires with `_delegator = Bob`, not Alice, so:
 *   - if Bob has no allowance to the same spender on the target, the hook reverts even when Alice does have
 *     one (Carol cannot use the chain, even though the revocation would have been valid for Alice);
 *   - if Bob happens to have some allowance, the hook passes and the execution clears Alice's allowance —
 *     independently of whether Alice actually had an allowance to clear.
 *
 * (b) Permit2 branches — no pre-check at all.
 *
 * The Permit2 branches do not consult `_delegator` (no on-chain liveness check is performed). On an intermediate
 * link this means the link-local sanity guard that exists for the ERC-20/721/operator branches is simply absent:
 * the hook always passes (subject only to the per-flag and target checks), and the executed call zeros / bumps
 * the *root* delegator's Permit2 state for whatever `(token, spender)` pair the delegate supplies.
 *
 * Neither (a) nor (b) is an authority escalation (the structural constraints above still apply — the call can
 * only reduce permissions). But the sanity guard is misaligned with the executed effect, and for the Permit2
 * branches it is absent entirely. Composition with `AllowedCalldataEnforcer` / `ExactCalldataEnforcer` to pin the
 * `(token, spender)` pair is therefore load-bearing for any redelegated Permit2 caveat.
 *
 * If a redelegator needs a root-scoped guarantee (e.g. "Carol may only revoke one of Alice's specific
 * approvals") they should rely on structural caveats that compose cleanly across links, such as
 * `AllowedTargetsEnforcer` (restrict which token contract), `AllowedCalldataEnforcer` (pin the exact spender
 * or tokenId), or `ExactCalldataEnforcer`. Placing `ApprovalRevocationEnforcer` on an intermediate link in the
 * hope of validating the root's approval state does not achieve that.
 *
 * @dev The "pre-existing approval" check is a liveness/sanity guard ensuring the call is not a no-op at the time
 * the hook runs. It is not a race-free invariant: the delegator could independently clear the approval between
 * the hook and the execution. In that case the execution is still safe — it simply becomes a no-op.
 *
 * @dev Delegators who want to restrict revocation to specific tokens should compose this enforcer with
 * `AllowedTargetsEnforcer`.
 *
 * @dev This enforcer operates only in single call type and default execution mode.
 */
contract ApprovalRevocationEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Constants //////////////////////////////

    /**
     * @dev Permission flags packed into the single-byte terms bitmask.
     */
    uint8 internal constant _PERMISSION_ERC20_APPROVE = 0x01;
    uint8 internal constant _PERMISSION_ERC721_APPROVE = 0x02;
    uint8 internal constant _PERMISSION_SET_APPROVAL_FOR_ALL = 0x04;
    uint8 internal constant _PERMISSION_PERMIT2_APPROVE = 0x08;
    uint8 internal constant _PERMISSION_PERMIT2_LOCKDOWN = 0x10;
    uint8 internal constant _PERMISSION_PERMIT2_INVALIDATE_NONCES = 0x20;
    uint8 internal constant _PERMISSION_MASK = _PERMISSION_ERC20_APPROVE | _PERMISSION_ERC721_APPROVE
        | _PERMISSION_SET_APPROVAL_FOR_ALL | _PERMISSION_PERMIT2_APPROVE | _PERMISSION_PERMIT2_LOCKDOWN
        | _PERMISSION_PERMIT2_INVALIDATE_NONCES;

    /**
     * @dev Canonical Permit2 deployment address (deterministic across EVM chains where Uniswap has deployed it,
     * e.g. mainnet, Base, Arbitrum, Optimism, etc.). See the contract-level "Trust assumption" NatSpec for the
     * implications on chains where canonical Permit2 is not deployed.
     */
    address internal constant _PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /**
     * @dev `bytes4(keccak256("approve(address,address,uint160,uint48)"))` — Permit2's `approve` selector.
     */
    bytes4 internal constant _PERMIT2_APPROVE_SELECTOR = 0x87517c45;

    /**
     * @dev `bytes4(keccak256("lockdown((address,address)[])"))` — Permit2's batch revocation selector. Every entry
     * of the array unconditionally zeros `amount` for the corresponding `(token, spender)` pair on the caller;
     * `expiration` and `nonce` are left untouched. No parameter can be used to grant authority.
     */
    bytes4 internal constant _PERMIT2_LOCKDOWN_SELECTOR = 0xcc53287f;

    /**
     * @dev `bytes4(keccak256("invalidateNonces(address,address,uint48)"))` — Permit2's nonce-invalidation
     * selector. The new nonce is required by Permit2 to be strictly greater than the current nonce (with a
     * per-call delta capped at `type(uint16).max`); it can therefore only invalidate signed-but-unredeemed
     * `permit` payloads, never create or extend an allowance.
     */
    bytes4 internal constant _PERMIT2_INVALIDATE_NONCES_SELECTOR = 0x65d9723c;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Requires the execution to revoke an existing token approval owned by `_delegator`, and that the
     * revocation primitive used is permitted by `_terms`.
     * @param _terms 1-byte bitmask selecting which revocation primitives are allowed. See the contract NatSpec.
     * @param _mode Must be single call type and default execution mode.
     * @param _executionCallData Single execution targeting the token contract.
     * @param _delegator The delegator of the delegation carrying this caveat (link-local, not the chain root).
     * See the contract-level NatSpec for the implications in redelegation chains.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32,
        address _delegator,
        address
    )
        public
        view
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        // Validate terms and capture the raw flags byte (1 stack slot vs. 3 bools).
        uint8 flags_ = _parseFlags(_terms);

        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(value_ == 0, "ApprovalRevocationEnforcer:invalid-value");
        require(callData_.length >= 4, "ApprovalRevocationEnforcer:invalid-execution-length");

        bytes4 selector_ = bytes4(callData_[0:4]);

        // Permit2 `approve(address,address,uint160,uint48)`: 4 + 4*32 = 132 bytes. Dispatched first because it has
        // its own length and selector and never overlaps with the other primitives.
        if (selector_ == _PERMIT2_APPROVE_SELECTOR) {
            require(flags_ & _PERMISSION_PERMIT2_APPROVE != 0, "ApprovalRevocationEnforcer:permit2-approve-not-allowed");
            _validatePermit2Approve(target_, callData_);
            return;
        }

        // Permit2 `lockdown((address,address)[])`: dynamic calldata. Only the canonical Permit2 target is
        // enforced — every entry of the array structurally zeros a Permit2 allowance amount, so no
        // calldata-shape validation is needed (a malformed payload simply reverts inside Permit2 itself).
        if (selector_ == _PERMIT2_LOCKDOWN_SELECTOR) {
            require(flags_ & _PERMISSION_PERMIT2_LOCKDOWN != 0, "ApprovalRevocationEnforcer:permit2-lockdown-not-allowed");
            require(target_ == _PERMIT2, "ApprovalRevocationEnforcer:invalid-permit2-target");
            return;
        }

        // Permit2 `invalidateNonces(address,address,uint48)`: only the canonical Permit2 target is enforced.
        // Permit2 itself enforces strict nonce monotonicity (and a per-call uint16-bounded delta), so the call
        // can only invalidate signed-but-unredeemed permits, never create authority.
        if (selector_ == _PERMIT2_INVALIDATE_NONCES_SELECTOR) {
            require(
                flags_ & _PERMISSION_PERMIT2_INVALIDATE_NONCES != 0,
                "ApprovalRevocationEnforcer:permit2-invalidate-nonces-not-allowed"
            );
            require(target_ == _PERMIT2, "ApprovalRevocationEnforcer:invalid-permit2-target");
            return;
        }

        // 68 = 4-byte selector + two 32-byte words. Shared by `approve(address,uint256)` and
        // `setApprovalForAll(address,bool)`.
        require(callData_.length == 68, "ApprovalRevocationEnforcer:invalid-execution-length");

        if (selector_ == IERC721.setApprovalForAll.selector) {
            require(flags_ & _PERMISSION_SET_APPROVAL_FOR_ALL != 0, "ApprovalRevocationEnforcer:setApprovalForAll-not-allowed");
            _validateOperatorRevocation(target_, callData_, _delegator);
            return;
        }
        if (selector_ == IERC20.approve.selector) {
            // ERC-20 and ERC-721 share `approve(address,uint256)`. Disambiguate by the first parameter: ERC-721
            // revokes via `approve(address(0), tokenId)`, while ERC-20 revokes via `approve(spender, 0)` with a
            // non-zero spender.
            address firstParam_ = address(uint160(uint256(bytes32(callData_[4:36]))));
            if (firstParam_ == address(0)) {
                require(flags_ & _PERMISSION_ERC721_APPROVE != 0, "ApprovalRevocationEnforcer:erc721-approve-not-allowed");
                _validateErc721Revocation(target_, callData_);
            } else {
                require(flags_ & _PERMISSION_ERC20_APPROVE != 0, "ApprovalRevocationEnforcer:erc20-approve-not-allowed");
                _validateErc20Revocation(target_, callData_, _delegator, firstParam_);
            }
            return;
        }
        revert("ApprovalRevocationEnforcer:invalid-method");
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @dev Validates and returns the raw permission flags byte. Reverts on invalid terms.
     */
    function _parseFlags(bytes calldata _terms) private pure returns (uint8 flags_) {
        require(_terms.length == 1, "ApprovalRevocationEnforcer:invalid-terms-length");
        flags_ = uint8(_terms[0]);
        require(flags_ != 0, "ApprovalRevocationEnforcer:no-methods-allowed");
        require(flags_ & ~_PERMISSION_MASK == 0, "ApprovalRevocationEnforcer:invalid-terms");
    }

    /**
     * @dev Validates an ERC-20 `approve(spender, 0)` revocation. Requires `allowance(delegator, spender) > 0` on
     * the target.
     */
    function _validateErc20Revocation(
        address _target,
        bytes calldata _callData,
        address _delegator,
        address _spender
    )
        private
        view
    {
        require(uint256(bytes32(_callData[36:68])) == 0, "ApprovalRevocationEnforcer:non-zero-amount");

        require(IERC20(_target).allowance(_delegator, _spender) != 0, "ApprovalRevocationEnforcer:no-approval-to-revoke");
    }

    /**
     * @dev Validates an ERC-721 `approve(address(0), tokenId)` revocation. Requires `getApproved(tokenId)` on the
     * target to be non-zero (i.e. an approval is currently set).
     */
    function _validateErc721Revocation(address _target, bytes calldata _callData) private view {
        uint256 tokenId_ = uint256(bytes32(_callData[36:68]));

        require(IERC721(_target).getApproved(tokenId_) != address(0), "ApprovalRevocationEnforcer:no-approval-to-revoke");
    }

    /**
     * @dev Validates a `setApprovalForAll(operator, false)` revocation (ERC-721 and ERC-1155 share this selector).
     * Requires `isApprovedForAll(delegator, operator)` on the target to currently be true.
     */
    function _validateOperatorRevocation(address _target, bytes calldata _callData, address _delegator) private view {
        require(uint256(bytes32(_callData[36:68])) == 0, "ApprovalRevocationEnforcer:not-a-revocation");

        address operator_ = address(uint160(uint256(bytes32(_callData[4:36]))));
        require(IERC721(_target).isApprovedForAll(_delegator, operator_), "ApprovalRevocationEnforcer:no-approval-to-revoke");
    }

    /**
     * @dev Validates a Permit2 `approve(token, spender, 0, 0)` revocation. Requires the target to be the canonical
     * Permit2 deployment, the calldata to be exactly 132 bytes, and both `amount` (uint160) and `expiration`
     * (uint48) parameters to be zero. No on-chain liveness check is performed: Permit2 silently overwrites any
     * existing allowance, so calling against a (token, spender) pair with no live allowance is a harmless no-op.
     * The first two parameters (token, spender) are intentionally unconstrained here — compose with
     * `AllowedCalldataEnforcer` if a particular pair must be enforced.
     */
    function _validatePermit2Approve(address _target, bytes calldata _callData) private pure {
        require(_target == _PERMIT2, "ApprovalRevocationEnforcer:invalid-permit2-target");
        require(_callData.length == 132, "ApprovalRevocationEnforcer:permit2-invalid-execution-length");
        // amount (uint160) sits in the 3rd word; it is ABI-encoded with 12 bytes of left padding (right-aligned
        // in the word), so checking the full 32-byte word for zero is equivalent and cheaper.
        require(uint256(bytes32(_callData[68:100])) == 0, "ApprovalRevocationEnforcer:non-zero-amount");
        // expiration (uint48, in the 4th word) MUST be zero.
        require(uint256(bytes32(_callData[100:132])) == 0, "ApprovalRevocationEnforcer:non-zero-expiration");
    }
}
