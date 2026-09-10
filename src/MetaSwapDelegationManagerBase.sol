// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { EncoderLib } from "./libraries/EncoderLib.sol";
import { ERC1271Lib } from "./libraries/ERC1271Lib.sol";
import { DELEGATION_TYPEHASH, CAVEAT_TYPEHASH } from "./utils/Constants.sol";
import { Caveat, Delegation, ModeCode } from "./utils/Types.sol";

/**
 * @title MetaSwapDelegationManagerBase
 * @notice Cheap one-shot redeem shell for purpose-specific MetaSwap managers.
 * @dev Supports exactly one root delegation containing one manager-enforced caveat.
 *      No redelegation chains: `delegate` is the intended redeemer (or `ANY_DELEGATE`) and
 *      `authority` is `ROOT_AUTHORITY`. Redemption is `SIMPLE_BATCH_MODE` only.
 *      Settlement-specific decoding and min-output checks live in subclasses.
 */
abstract contract MetaSwapDelegationManagerBase is EIP712 {
    string public constant DOMAIN_VERSION = "1";
    bytes32 public constant ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    address public constant ANY_DELEGATE = address(0xa11);
    /// @dev Equivalent to `ModeLib.encodeSimpleBatch()` (batch calltype, default exec).
    ModeCode public constant SIMPLE_BATCH_MODE = ModeCode.wrap(0x0100000000000000000000000000000000000000000000000000000000000000);

    /// @notice Records delegations that were cancelled or successfully consumed.
    mapping(bytes32 delegationHash => bool isUnavailable) public disabledDelegations;

    event DisabledDelegation(
        bytes32 indexed delegationHash, address indexed delegator, address indexed delegate, Delegation delegation
    );
    /// @dev `intent` is the first terms byte (`Intent` on MetaSwapIntentDelegationManager).
    event RedeemedDelegation(address indexed rootDelegator, address indexed redeemer, bytes32 indexed delegationHash, uint8 intent);

    error AlreadyDisabled();
    error BatchDataLengthMismatch();
    error CannotUseADisabledDelegation();
    error InsufficientOutput();
    error InvalidAuthority();
    error InvalidCaveat();
    error InvalidDelegate();
    error InvalidDelegator();
    error InvalidEOASignature();
    error InvalidERC1271Signature();
    error InvalidMode();
    error InvalidPermissionContext();
    error InvalidTerms();

    constructor(string memory name_) EIP712(name_, DOMAIN_VERSION) { }

    /**
     * @notice Cancels a settlement delegation.
     * @dev Successful settlements use the same state, so consumed delegations cannot be re-enabled.
     * @param delegation_ Delegation to cancel.
     */
    function disableDelegation(Delegation calldata delegation_) external {
        if (delegation_.delegator != msg.sender) revert InvalidDelegator();

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        if (disabledDelegations[delegationHash_]) revert AlreadyDisabled();

        disabledDelegations[delegationHash_] = true;
        emit DisabledDelegation(delegationHash_, delegation_.delegator, delegation_.delegate, delegation_);
    }

    /**
     * @notice Redeems one specialized MetaSwap delegation.
     * @dev These intents are leaf delegations: `delegate` is a specific redeemer (or `ANY_DELEGATE`),
     *      `authority` is always `ROOT_AUTHORITY` so there is no redelegation chain, and `modes_[0]`
     *      must be `SIMPLE_BATCH_MODE`.
     * @param permissionContexts_ Must contain one ABI-encoded one-element `Delegation[]`.
     * @param modes_ Must contain the canonical batch/default mode.
     * @param executionContexts_ Manager-specific execution context.
     */
    function redeemDelegations(
        bytes[] calldata permissionContexts_,
        ModeCode[] calldata modes_,
        bytes[] calldata executionContexts_
    )
        external
    {
        if (permissionContexts_.length != 1 || modes_.length != 1 || executionContexts_.length != 1) {
            revert BatchDataLengthMismatch();
        }
        if (ModeCode.unwrap(modes_[0]) != ModeCode.unwrap(SIMPLE_BATCH_MODE)) revert InvalidMode();

        Delegation[] memory delegations_ = abi.decode(permissionContexts_[0], (Delegation[]));
        if (delegations_.length != 1) revert InvalidPermissionContext();

        Delegation memory delegation_ = delegations_[0];
        if (delegation_.delegate != msg.sender && delegation_.delegate != ANY_DELEGATE) revert InvalidDelegate();
        if (delegation_.authority != ROOT_AUTHORITY) revert InvalidAuthority();
        if (delegation_.caveats.length != 1 || delegation_.caveats[0].enforcer != address(this)) revert InvalidCaveat();

        bytes32 delegationHash_ = _getSingleCaveatDelegationHash(delegation_);
        if (disabledDelegations[delegationHash_]) revert CannotUseADisabledDelegation();

        _validateSignature(delegation_, delegationHash_);

        disabledDelegations[delegationHash_] = true;
        bytes memory terms_ = delegation_.caveats[0].terms;
        _executeIntent(delegation_.delegator, terms_, executionContexts_[0]);

        emit RedeemedDelegation(delegation_.delegator, msg.sender, delegationHash_, uint8(terms_[0]));
    }

    /**
     * @notice Returns the EIP-712 hash used to sign a delegation.
     * @param delegation_ Delegation to hash.
     */
    function getDelegationHash(Delegation calldata delegation_) external pure returns (bytes32) {
        return EncoderLib._getDelegationHash(delegation_);
    }

    /**
     * @notice Returns this manager's EIP-712 domain separator.
     */
    function getDomainHash() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Executes the signed intent after the one-shot lock is recorded.
     * @param delegator_ Root delegator account that will execute.
     * @param terms_ Signed caveat terms.
     * @param executionContext_ Redeemer-supplied execution context.
     */
    function _executeIntent(address delegator_, bytes memory terms_, bytes calldata executionContext_) internal virtual;

    function _validateSignature(Delegation memory delegation_, bytes32 delegationHash_) private view {
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), delegationHash_);
        (address recovered_, ECDSA.RecoverError error_,) = ECDSA.tryRecover(typedDataHash_, delegation_.signature);
        if (error_ == ECDSA.RecoverError.NoError && recovered_ == delegation_.delegator) return;

        // Codeless delegators are EOAs: a non-matching recovery cannot succeed via ERC-1271.
        if (delegation_.delegator.code.length == 0) revert InvalidEOASignature();

        if (
            IERC1271(delegation_.delegator).isValidSignature(typedDataHash_, delegation_.signature)
                != ERC1271Lib.EIP1271_MAGIC_VALUE
        ) {
            revert InvalidERC1271Signature();
        }
    }

    function _getSingleCaveatDelegationHash(Delegation memory delegation_) internal pure returns (bytes32) {
        Caveat memory caveat_ = delegation_.caveats[0];
        bytes32 caveatHash_ = keccak256(abi.encode(CAVEAT_TYPEHASH, caveat_.enforcer, keccak256(caveat_.terms)));
        bytes32 caveatsHash_ = keccak256(abi.encodePacked(caveatHash_));

        return keccak256(
            abi.encode(
                DELEGATION_TYPEHASH,
                delegation_.delegate,
                delegation_.delegator,
                delegation_.authority,
                caveatsHash_,
                delegation_.salt
            )
        );
    }

    function _balanceOf(address token_, address recipient_) internal view returns (uint256) {
        return token_ == address(0) ? recipient_.balance : IERC20(token_).balanceOf(recipient_);
    }
}
