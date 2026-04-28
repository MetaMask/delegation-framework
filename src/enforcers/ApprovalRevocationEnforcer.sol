// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ApprovalRevocationEnforcer
 * @notice Allows a delegate to clear existing token approvals. The delegator controls which of the three
 * standard revocation primitives the delegate may perform via a 1-byte bitmask in `terms`:
 *
 *   Bit 0 (`0x01`) — ERC-20 `approve(spender, 0)` (spender non-zero, amount zero)
 *   Bit 1 (`0x02`) — ERC-721 per-token `approve(address(0), tokenId)`
 *   Bit 2 (`0x04`) — ERC-721 / ERC-1155 `setApprovalForAll(operator, false)`
 *   Bits 3-7       — Reserved; MUST be zero.
 *
 * Examples:
 *   `0x01` — delegate may only clear ERC-20 allowances.
 *   `0x04` — delegate may only revoke operator approvals.
 *   `0x07` — delegate may use all three revocation primitives.
 *
 * Terms MUST be exactly 1 byte, MUST not be zero, and MUST NOT set any reserved bit.
 *
 * @dev ERC-721 and ERC-1155 intentionally share the `setApprovalForAll(address,bool)` selector; this enforcer
 * handles both via the `IERC721` interface (the selector and ABI are identical, so a typed `IERC1155` import is
 * unnecessary for the external call). ERC-20 and ERC-721 likewise share the `approve(address,uint256)` selector,
 * and are disambiguated by inspecting the first parameter (see branching rules below).
 *
 * @dev The execution must transfer zero native value and carry one of the supported approval calldatas (length 68
 * bytes: 4-byte selector + two 32-byte words). Branching is determined as follows:
 * - selector `setApprovalForAll(address operator, bool approved)`:
 *   - `approved` MUST be false, and
 *   - `isApprovedForAll(delegator, operator)` MUST currently be true on the target.
 * - selector `approve(address, uint256)` (shared by ERC-20 and ERC-721):
 *   - if the first parameter is `address(0)` the call is treated as an ERC-721 per-token revocation:
 *     - `getApproved(tokenId)` on the target MUST currently return a non-zero address.
 *   - otherwise the call is treated as an ERC-20 revocation:
 *     - the second parameter (amount) MUST be zero, and
 *     - `allowance(delegator, spender)` on the target MUST currently return non-zero.
 *
 * @dev All three accepted calldatas structurally result in a net reduction of permissions on the target (amount
 * `0`, spender `address(0)`, or `approved` `false`). A delegate using this enforcer can therefore never be granted
 * new authority over the delegator's assets — only existing approvals can be cleared.
 *
 * @dev REDELEGATION WARNING — link-local pre-check vs. root-level execution.
 *
 * The `_delegator` argument passed to `beforeHook` is the delegator of the specific delegation that carries the
 * caveat, not the root of a redelegation chain. The DelegationManager always executes the downstream
 * `approve` / `setApprovalForAll` call against the *root* delegator's account (the account at the end of the
 * leaf-to-root chain). On a root-level delegation (chain length 1) the two are the same and the pre-check
 * queries the account whose storage will actually be mutated — this is the intended usage.
 *
 * On an intermediate (redelegation) link the two differ: the pre-check queries the *intermediate* delegator's
 * approval state, while the execution mutates the *root* delegator's storage. A redelegator adding this caveat
 * to constrain their delegate is very likely expecting the pre-check to run against the root (the account whose
 * approval will be cleared). That expectation is wrong — the check is link-local.
 *
 * Concrete example. Alice -> Bob -> Carol. Alice's link has no caveat (Bob has full authority over Alice).
 * Bob places this enforcer on his delegation to Carol, intending "Carol can only revoke an existing approval on
 * Alice's account". When Carol redeems, the hook fires with `_delegator = Bob`, not Alice, so:
 *   - if Bob has no allowance to the same spender on the target, the hook reverts even when Alice does have
 *     one (Carol cannot use the chain, even though the revocation would have been valid for Alice);
 *   - if Bob happens to have some allowance, the hook passes and the execution clears Alice's allowance —
 *     independently of whether Alice actually had an allowance to clear.
 *
 * This is never an authority escalation (the structural constraints above still apply — the call can only
 * reduce permissions), but the sanity guard is misaligned with the executed effect and will behave
 * unintuitively for anyone reading "the delegator's approval must exist" as a check on the root.
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

    /// @dev Permission flags packed into the single-byte terms bitmask.
    uint8 internal constant _PERMISSION_ERC20_APPROVE = 0x01;
    uint8 internal constant _PERMISSION_ERC721_APPROVE = 0x02;
    uint8 internal constant _PERMISSION_SET_APPROVAL_FOR_ALL = 0x04;
    uint8 internal constant _PERMISSION_MASK =
        _PERMISSION_ERC20_APPROVE | _PERMISSION_ERC721_APPROVE | _PERMISSION_SET_APPROVAL_FOR_ALL;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Requires the execution to revoke an existing token approval owned by `_delegator`, and that the
     * revocation primitive used is permitted by `_terms`.
     * @param _terms 1-byte bitmask selecting which revocation primitives are allowed. See `getTermsInfo`.
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
        // 68 = 4-byte selector + two 32-byte words. Shared by `approve(address,uint256)` and
        // `setApprovalForAll(address,bool)`.
        require(callData_.length == 68, "ApprovalRevocationEnforcer:invalid-execution-length");

        if (bytes4(callData_[0:4]) == IERC721.setApprovalForAll.selector) {
            require(flags_ & _PERMISSION_SET_APPROVAL_FOR_ALL != 0, "ApprovalRevocationEnforcer:setApprovalForAll-not-allowed");
            _validateOperatorRevocation(target_, callData_, _delegator);
            return;
        }
        if (bytes4(callData_[0:4]) == IERC20.approve.selector) {
            // ERC-20 and ERC-721 share `approve(address,uint256)`. Disambiguate by the first parameter: ERC-721
            // revokes via `approve(address(0), tokenId)`, while ERC-20 revokes via `approve(spender, 0)` with a
            // non-zero spender.
            if (address(uint160(uint256(bytes32(callData_[4:36])))) == address(0)) {
                require(flags_ & _PERMISSION_ERC721_APPROVE != 0, "ApprovalRevocationEnforcer:erc721-approve-not-allowed");
                _validateErc721Revocation(target_, callData_);
            } else {
                require(flags_ & _PERMISSION_ERC20_APPROVE != 0, "ApprovalRevocationEnforcer:erc20-approve-not-allowed");
                _validateErc20Revocation(target_, callData_, _delegator, address(uint160(uint256(bytes32(callData_[4:36])))));
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

        require(
            IERC20(_target).allowance(_delegator, _spender) != 0, "ApprovalRevocationEnforcer:no-approval-to-revoke"
        );
    }

    /**
     * @dev Validates an ERC-721 `approve(address(0), tokenId)` revocation. Requires `getApproved(tokenId)` on the
     * target to be non-zero (i.e. an approval is currently set).
     */
    function _validateErc721Revocation(address _target, bytes calldata _callData) private view {
        uint256 tokenId_ = uint256(bytes32(_callData[36:68]));

        require(
            IERC721(_target).getApproved(tokenId_) != address(0), "ApprovalRevocationEnforcer:no-approval-to-revoke"
        );
    }

    /**
     * @dev Validates a `setApprovalForAll(operator, false)` revocation (ERC-721 and ERC-1155 share this selector).
     * Requires `isApprovedForAll(delegator, operator)` on the target to currently be true.
     */
    function _validateOperatorRevocation(address _target, bytes calldata _callData, address _delegator) private view {
        require(uint256(bytes32(_callData[36:68])) == 0, "ApprovalRevocationEnforcer:not-a-revocation");

        address operator_ = address(uint160(uint256(bytes32(_callData[4:36]))));
        require(
            IERC721(_target).isApprovedForAll(_delegator, operator_),
            "ApprovalRevocationEnforcer:no-approval-to-revoke"
        );
    }
}
