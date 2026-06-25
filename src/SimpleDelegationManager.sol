// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { ICaveatEnforcer } from "./interfaces/ICaveatEnforcer.sol";
import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { IDeleGatorCore } from "./interfaces/IDeleGatorCore.sol";
import { Delegation, Caveat, ModeCode } from "./utils/Types.sol";
import { EncoderLib } from "./libraries/EncoderLib.sol";
import { ERC1271Lib } from "./libraries/ERC1271Lib.sol";
import { HookFlagsLib } from "./libraries/HookFlagsLib.sol";

/**
 * @title SimpleDelegationManager
 * @notice A gas-optimized, purpose-built DelegationManager
 *
 * @dev It keeps the canonical ERC-7710 `redeemDelegations(bytes[],ModeCode[],bytes[])` interface and the `Delegation`-struct
 *      signing model, validates the delegation chain leaf-to-root, and supports a one-way `disableDelegation` (revoke). It is
 *      deliberately leaner than the canonical `DelegationManager`:
 *
 *        - No owner / pausing. There is no `Ownable`, no `Pausable`, no `pause`/`unpause`.
 *        - Revoke-only. `disableDelegation` permanently disables a delegation; there is NO `enableDelegation`.
 *        - No self-authorized redemption (the empty-permissionContext path is removed).
 *        - One combined validation+hook pass. Signature, disabled, authority/delegate-chain, and `beforeHook` are all done
 *          in a SINGLE leaf-to-root loop (vs the canonical manager's separate passes), then `executeFromExecutor`, then an
 *          OPTIONAL `afterHook` reverse pass (entered only if a caveat advertises it), then events.
 *        - No `beforeAllHook` / `afterAllHook`. Those batch-level phases are not run.
 *        - `beforeHook`/`afterHook` are called ONLY when the enforcer's address advertises the
 *          matching permission (see {HookFlagsLib})
 *
 * @dev SECURITY ORDERING: because validation and `beforeHook` are fused into one pass, a delegation's `beforeHook` may run
 *      before a more-rootward delegation's signature/authority is validated. Redemption is atomic, so any later validation
 *      failure reverts the whole transaction (rolling back any hook side effects), preserving safety. `beforeHook` still runs
 *      leaf-to-root and `afterHook` root-to-leaf, and execution still happens only after the entire chain is validated and all
 *      `beforeHook`s have run.
 *
 * @dev !!! SECURITY WARNING !!! There is NO on-chain check that an enforcer's address flags match the hooks it
 *      actually implements. If a security-relevant enforcer (e.g. a BalanceChangeEnforcer whose check is in `afterHook`, or an
 *      ExactExecution / LimitedCalls enforcer whose check is in `beforeHook`) is deployed at an address LACKING the matching
 *      flag bit, this manager SILENTLY SKIPS that hook and the constraint is not enforced.
 */
contract SimpleDelegationManager is EIP712 {
    using MessageHashUtils for bytes32;

    ////////////////////////////// State //////////////////////////////

    /// @dev The name of the contract
    string public constant NAME = "SimpleDelegationManager";

    /// @dev The full version of the contract
    string public constant VERSION = "1.3.0";

    /// @dev The version used in the domainSeparator for EIP712
    string public constant DOMAIN_VERSION = "1";

    /// @dev Special authority value. Indicates that the delegator is the authority
    bytes32 public constant ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    /// @dev Special delegate value. Allows any delegate to redeem the delegation
    address public constant ANY_DELEGATE = address(0xa11);

    /// @dev A mapping of delegation hashes that have been (permanently) disabled by the delegator
    mapping(bytes32 delegationHash => bool isDisabled) public disabledDelegations;

    ////////////////////////////// Modifier //////////////////////////////

    /**
     * @notice Require the caller to be the delegator.
     */
    modifier onlyDeleGator(address delegator) {
        if (delegator != msg.sender) revert IDelegationManager.InvalidDelegator();
        _;
    }

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the SimpleDelegationManager's EIP-712 domain.
     */
    constructor() EIP712(NAME, DOMAIN_VERSION) {
        emit IDelegationManager.SetDomain(_domainSeparatorV4(), NAME, DOMAIN_VERSION, block.chainid, address(this));
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Permanently disables a delegation (revoke). Disabled delegations always fail upon redemption.
     * @dev MUST be called by the delegator. There is no way to re-enable.
     * @param _delegation The delegation to disable.
     */
    function disableDelegation(Delegation calldata _delegation) external onlyDeleGator(_delegation.delegator) {
        bytes32 delegationHash_ = getDelegationHash(_delegation);
        if (disabledDelegations[delegationHash_]) revert IDelegationManager.AlreadyDisabled();
        disabledDelegations[delegationHash_] = true;
        emit IDelegationManager.DisabledDelegation(delegationHash_, _delegation.delegator, _delegation.delegate, _delegation);
    }

    /**
     * @notice Validates permission contexts and executes the corresponding executions on behalf of each root delegator.
     * @dev Same ERC-7710 interface as `DelegationManager.redeemDelegations`.
     * @param _permissionContexts An array where each element is `abi.encode(Delegation[])` ordered leaf to root (NON-empty).
     * @param _modes An array of execution modes, one per redemption.
     * @param _executionCallDatas An array of encoded executions, one per redemption.
     */
    function redeemDelegations(
        bytes[] calldata _permissionContexts,
        ModeCode[] calldata _modes,
        bytes[] calldata _executionCallDatas
    )
        external
    {
        uint256 batchSize_ = _permissionContexts.length;
        if (batchSize_ != _executionCallDatas.length || batchSize_ != _modes.length) {
            revert IDelegationManager.BatchDataLengthMismatch();
        }

        // Hoist the domain separator once for all redemptions.
        bytes32 domainHash_ = _domainSeparatorV4();

        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            _redeem(domainHash_, _permissionContexts[batchIndex_], _modes[batchIndex_], _executionCallDatas[batchIndex_]);
        }
    }

    /**
     * @notice This method returns the domain hash used for signing typed data.
     */
    function getDomainHash() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Creates a hash of a Delegation.
     */
    function getDelegationHash(Delegation calldata _input) public pure returns (bytes32) {
        return EncoderLib._getDelegationHash(_input);
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Processes a single redemption: validate the chain + run beforeHook in one pass, execute, then optional afterHook.
     * @param _domainHash The hoisted EIP-712 domain separator.
     * @param _permissionContext `abi.encode(Delegation[])` ordered leaf to root (must be non-empty).
     * @param _mode The execution mode.
     * @param _executionCallData The encoded execution.
     */
    function _redeem(
        bytes32 _domainHash,
        bytes calldata _permissionContext,
        ModeCode _mode,
        bytes calldata _executionCallData
    )
        internal
    {
        Delegation[] memory delegations_ = abi.decode(_permissionContext, (Delegation[]));
        uint256 length_ = delegations_.length;

        // The leaf delegate must be the caller (or the open ANY_DELEGATE sentinel).
        if (delegations_[0].delegate != msg.sender && delegations_[0].delegate != ANY_DELEGATE) {
            revert IDelegationManager.InvalidDelegate();
        }

        // Single combined leaf-to-root pass: hash + signature + disabled + authority/delegate chain + beforeHook.
        // The authority/delegate link between delegation (i-1) and i is checked when i is reached: delegations_[i-1].authority
        // must equal i's hash, mirroring the canonical manager's chain validation.
        bool hasAfterHook_;
        for (uint256 i; i < length_; ++i) {
            bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegations_[i]);

            // Signature validation (EOA via ECDSA, or contract/EIP-7702 via ERC-1271).
            _validateSignature(
                delegations_[i].delegator, MessageHashUtils.toTypedDataHash(_domainHash, delegationHash_), delegations_[i].signature
            );

            // Disabled check.
            if (disabledDelegations[delegationHash_]) revert IDelegationManager.CannotUseADisabledDelegation();

            // Authority + delegate chain: validate the (i-1) -> i link (delegations_[i-1].authority must equal i's hash).
            if (i != 0) {
                if (delegations_[i - 1].authority != delegationHash_) revert IDelegationManager.InvalidAuthority();
                address curDelegate_ = delegations_[i].delegate;
                if (curDelegate_ != ANY_DELEGATE && delegations_[i - 1].delegator != curDelegate_) {
                    revert IDelegationManager.InvalidDelegate();
                }
            }

            // beforeHook (flag-gated) for this delegation's caveats; note if any caveat also wants an afterHook.
            if (_beforeHooksForDelegation(delegations_[i], delegationHash_, _mode, _executionCallData)) hasAfterHook_ = true;
        }

        // Root authority: the most-rootward delegation must be self-authorized.
        if (delegations_[length_ - 1].authority != ROOT_AUTHORITY) revert IDelegationManager.InvalidAuthority();

        // Execute on the root delegator.
        address rootDelegator_ = delegations_[length_ - 1].delegator;
        IDeleGatorCore(rootDelegator_).executeFromExecutor(_mode, _executionCallData);

        // Optional afterHook (flag-gated, root to leaf) — entered only when a caveat advertised it. Hashes are recomputed
        // here (rather than buffered) so the common gasless path pays for no hash array.
        if (hasAfterHook_) {
            for (uint256 i = length_; i > 0; --i) {
                Delegation memory delegation_ = delegations_[i - 1];
                _afterHooksForDelegation(delegation_, EncoderLib._getDelegationHash(delegation_), _mode, _executionCallData);
            }
        }

        // Emit one RedeemedDelegation per delegation in the chain.
        for (uint256 i; i < length_; ++i) {
            emit IDelegationManager.RedeemedDelegation(rootDelegator_, msg.sender, delegations_[i]);
        }
    }

    /**
     * @notice Validates a delegation signature: ECDSA for EOA delegators, ERC-1271 for contracts (incl. EIP-7702 accounts).
     * @dev Isolated to keep the redemption loop's stack shallow.
     */
    function _validateSignature(address _delegator, bytes32 _typedDataHash, bytes memory _signature) private view {
        if (_delegator.code.length == 0) {
            if (ECDSA.recover(_typedDataHash, _signature) != _delegator) revert IDelegationManager.InvalidEOASignature();
        } else {
            if (IERC1271(_delegator).isValidSignature(_typedDataHash, _signature) != ERC1271Lib.EIP1271_MAGIC_VALUE) {
                revert IDelegationManager.InvalidERC1271Signature();
            }
        }
    }

    /**
     * @notice Runs the flag-gated `beforeHook` for every caveat in a single delegation.
     * @dev Scoped to one delegation to keep the redemption loop's stack shallow.
     * @return hasAfterHook_ True if any caveat in this delegation advertises {HookFlagsLib.AFTER_HOOK_FLAG}.
     */
    function _beforeHooksForDelegation(
        Delegation memory _delegation,
        bytes32 _delegationHash,
        ModeCode _mode,
        bytes calldata _executionCallData
    )
        private
        returns (bool hasAfterHook_)
    {
        Caveat[] memory caveats_ = _delegation.caveats;
        address delegator_ = _delegation.delegator;
        for (uint256 c; c < caveats_.length; ++c) {
            address enforcer_ = caveats_[c].enforcer;
            if (HookFlagsLib.hasFlag(enforcer_, HookFlagsLib.BEFORE_HOOK_FLAG)) {
                ICaveatEnforcer(enforcer_)
                    .beforeHook(
                        caveats_[c].terms, caveats_[c].args, _mode, _executionCallData, _delegationHash, delegator_, msg.sender
                    );
            }
            if (HookFlagsLib.hasFlag(enforcer_, HookFlagsLib.AFTER_HOOK_FLAG)) hasAfterHook_ = true;
        }
    }

    /**
     * @notice Runs the flag-gated `afterHook` for every caveat in a single delegation (reverse caveat order).
     */
    function _afterHooksForDelegation(
        Delegation memory _delegation,
        bytes32 _delegationHash,
        ModeCode _mode,
        bytes calldata _executionCallData
    )
        private
    {
        Caveat[] memory caveats_ = _delegation.caveats;
        address delegator_ = _delegation.delegator;
        for (uint256 c = caveats_.length; c > 0; --c) {
            address enforcer_ = caveats_[c - 1].enforcer;
            if (HookFlagsLib.hasFlag(enforcer_, HookFlagsLib.AFTER_HOOK_FLAG)) {
                ICaveatEnforcer(enforcer_)
                    .afterHook(
                        caveats_[c - 1].terms,
                        caveats_[c - 1].args,
                        _mode,
                        _executionCallData,
                        _delegationHash,
                        delegator_,
                        msg.sender
                    );
            }
        }
    }
}
