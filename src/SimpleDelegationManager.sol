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

/**
 * @title SimpleDelegationManager
 * @notice A gas-optimized, purpose-built DelegationManager for gasless flows (ADR #0002 Option 3).
 *
 * @dev It keeps the canonical ERC-7710 `redeemDelegations(bytes[],ModeCode[],bytes[])` interface and the `Delegation`-struct
 *      signing model, validates the delegation chain leaf-to-root, and supports a one-way `disableDelegation` (revoke). It is
 *      deliberately leaner than the canonical `DelegationManager`:
 *
 *        - No owner / pausing (no `Ownable`, no `Pausable`).
 *        - Revoke-only: `disableDelegation` permanently disables a delegation; there is NO `enableDelegation`.
 *        - No self-authorized redemption (the empty-permissionContext path is removed).
 *        - `beforeHook` ONLY. The canonical manager runs four hook phases (`beforeAllHook`, `beforeHook`, `afterHook`,
 *          `afterAllHook`) over every caveat; this manager runs ONLY `beforeHook`, which is all the gasless caveats
 *          (`ExactExecution*`, replay/limit) implement. Enforcers that rely on the other phases are NOT supported here.
 *        - One combined validation+hook pass: signature, disabled, authority/delegate-chain, and `beforeHook` are all done in a
 *          SINGLE leaf-to-root loop (vs the canonical manager's separate passes), then `executeFromExecutor`, then events.
 *        - Inline-ECDSA signature fast path (see {_validateSignature}).
 *
 * @dev SECURITY ORDERING: because validation and `beforeHook` are fused into one pass, a delegation's `beforeHook` may run
 *      before a more-rootward delegation's signature/authority is validated. Redemption is atomic, so any later validation
 *      failure reverts the whole transaction (rolling back any hook side effects), preserving safety. `beforeHook` still runs
 *      leaf-to-root, and execution still happens only after the entire chain is validated and every `beforeHook` has run.
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

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted per delegation when redeemed. Leaner than `IDelegationManager.RedeemedDelegation`, which carries the full
    ///      `Delegation` struct in log data: this emits only the (fully indexed) delegation hash, which uniquely identifies it,
    ///      saving the struct ABI-encoding. The full delegation is recoverable from the signed payload off-chain.
    event RedeemedDelegation(address indexed rootDelegator, address indexed redeemer, bytes32 indexed delegationHash);

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
     * @notice Processes a single redemption: validate the chain + run beforeHook in one pass, execute, then emit.
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

        // The root delegator (most-rootward) is the account executed on, and the `rootDelegator` of every emitted event.
        address rootDelegator_ = delegations_[length_ - 1].delegator;

        // Single combined leaf-to-root pass: hash + signature + disabled + authority/delegate chain + beforeHook + emit.
        // The authority/delegate link between delegation (i-1) and i is checked when i is reached: delegations_[i-1].authority
        // must equal i's hash, mirroring the canonical manager's chain validation.
        for (uint256 i; i < length_; ++i) {
            bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegations_[i]);

            // Signature validation (inline ECDSA fast path, ERC-1271 fallback).
            _validateSignature(
                delegations_[i].delegator, MessageHashUtils.toTypedDataHash(_domainHash, delegationHash_), delegations_[i].signature
            );

            // Disabled check.
            if (disabledDelegations[delegationHash_]) revert IDelegationManager.CannotUseADisabledDelegation();

            // Authority + delegate chain.
            if (i != 0) {
                if (delegations_[i - 1].authority != delegationHash_) revert IDelegationManager.InvalidAuthority();
                address nextDelegate_ = delegations_[i].delegate;
                if (nextDelegate_ != ANY_DELEGATE && delegations_[i - 1].delegator != nextDelegate_) {
                    revert IDelegationManager.InvalidDelegate();
                }
            }

            // beforeHook for every caveat in this delegation (this manager runs no other hook phase).
            _runBeforeHooks(delegations_[i], delegationHash_, _mode, _executionCallData);

            // Emit the (lean, hash-only) redemption event. The hash is already in hand here, so no second loop / re-hash; on any
            // later revert (incl. the root-authority check or the execution) the whole tx rolls back, so no spurious event
            // persists.
            emit RedeemedDelegation(rootDelegator_, msg.sender, delegationHash_);
        }

        // Root authority: the most-rootward delegation must be self-authorized.
        if (delegations_[length_ - 1].authority != ROOT_AUTHORITY) revert IDelegationManager.InvalidAuthority();

        // Execute on the root delegator.
        IDeleGatorCore(rootDelegator_).executeFromExecutor(_mode, _executionCallData);
    }

    /**
     * @notice Validates a delegation signature.
     * @dev Optimized for the gasless target: a FAST PATH does an inline ECDSA recover-to-delegator (covers plain EOAs AND
     *      EIP-7702 accounts that use the EOA recover-to-self scheme) with NO external ERC-1271 call — this is the dominant
     *      saving vs the canonical manager, which always pays an external `isValidSignature` call for code-bearing accounts.
     *      Only if the inline recovery does not match does it fall back to ERC-1271 (preserving support for contract accounts
     *      with other signature schemes, e.g. multisig). The fast path is purely an optimization: it can never accept an
     *      invalid signature (`tryRecover` never reverts and a non-matching recovery falls through), it just avoids the external
     *      call in the common case.
     * @dev Isolated to keep the redemption loop's stack shallow.
     */
    function _validateSignature(address _delegator, bytes32 _typedDataHash, bytes memory _signature) private view {
        (address recovered_, ECDSA.RecoverError err_,) = ECDSA.tryRecover(_typedDataHash, _signature);
        if (err_ == ECDSA.RecoverError.NoError && recovered_ == _delegator) return;

        // A codeless delegator can only be an EOA, so a non-matching recovery is conclusively invalid.
        if (_delegator.code.length == 0) revert IDelegationManager.InvalidEOASignature();

        // Fallback: contract delegator with a non-ECDSA scheme — validate via ERC-1271.
        if (IERC1271(_delegator).isValidSignature(_typedDataHash, _signature) != ERC1271Lib.EIP1271_MAGIC_VALUE) {
            revert IDelegationManager.InvalidERC1271Signature();
        }
    }

    /**
     * @notice Runs `beforeHook` for every caveat in a single delegation (this manager runs no other hook phase).
     * @dev Scoped to one delegation to keep the redemption loop's stack shallow.
     */
    function _runBeforeHooks(
        Delegation memory _delegation,
        bytes32 _delegationHash,
        ModeCode _mode,
        bytes calldata _executionCallData
    )
        private
    {
        Caveat[] memory caveats_ = _delegation.caveats;
        address delegator_ = _delegation.delegator;
        for (uint256 c; c < caveats_.length; ++c) {
            ICaveatEnforcer(caveats_[c].enforcer)
                .beforeHook(caveats_[c].terms, caveats_[c].args, _mode, _executionCallData, _delegationHash, delegator_, msg.sender);
        }
    }
}
