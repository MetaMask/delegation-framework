// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { EncoderLib } from "./libraries/EncoderLib.sol";
import { ERC1271Lib } from "./libraries/ERC1271Lib.sol";
import { DELEGATION_TYPEHASH, CAVEAT_TYPEHASH } from "./utils/Constants.sol";
import { Caveat, Delegation, ModeCode } from "./utils/Types.sol";

/**
 * @title MetaSwapDelegationManagerBase
 * @notice Shared validation and settlement logic for specialized MetaSwap delegation managers.
 * @dev Supports exactly one root delegation containing one manager-enforced settlement caveat.
 */
abstract contract MetaSwapDelegationManagerBase is EIP712 {
    enum SignatureMode {
        DirectECDSA,
        ERC1271
    }

    enum ApprovalMode {
        None,
        SkipApproval,
        Approve,
        ResetApprove
    }

    struct Terms {
        address metaSwap;
        address tokenIn;
        uint256 tokenInAmount;
        ApprovalMode approvalMode;
        address tokenOut;
        address recipient;
        uint256 tokenOutMin;
    }

    string public constant DOMAIN_VERSION = "1";
    bytes32 public constant ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    address public constant ANY_DELEGATE = address(0xa11);

    uint256 internal constant TERMS_LENGTH = 145;

    SignatureMode public immutable signatureMode;

    /// @notice Records delegations that were cancelled or successfully consumed.
    mapping(bytes32 delegationHash => bool isUnavailable) public disabledDelegations;

    event DisabledDelegation(
        bytes32 indexed delegationHash, address indexed delegator, address indexed delegate, Delegation delegation
    );
    event RedeemedDelegation(address indexed rootDelegator, address indexed redeemer, Delegation delegation);

    error AlreadyDisabled();
    error BatchDataLengthMismatch();
    error CannotUseADisabledDelegation();
    error InsufficientOutput();
    error InvalidApprovalMode();
    error InvalidAuthority();
    error InvalidCaveat();
    error InvalidDelegate();
    error InvalidDelegator();
    error InvalidEOASignature();
    error InvalidERC1271Signature();
    error InvalidMode();
    error InvalidPermissionContext();
    error InvalidTerms();

    constructor(string memory name_, SignatureMode signatureMode_) EIP712(name_, DOMAIN_VERSION) {
        signatureMode = signatureMode_;
    }

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
     * @notice Redeems one specialized MetaSwap settlement delegation.
     * @param permissionContexts_ Must contain one ABI-encoded one-element `Delegation[]`.
     * @param modes_ Must contain the canonical batch/default mode.
     * @param executionContexts_ Manager-specific execution or route context.
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
        if (ModeCode.unwrap(modes_[0]) != ModeCode.unwrap(ModeLib.encodeSimpleBatch())) revert InvalidMode();

        Delegation[] memory delegations_ = abi.decode(permissionContexts_[0], (Delegation[]));
        if (delegations_.length != 1) revert InvalidPermissionContext();

        Delegation memory delegation_ = delegations_[0];
        if (delegation_.delegate != msg.sender && delegation_.delegate != ANY_DELEGATE) revert InvalidDelegate();
        if (delegation_.authority != ROOT_AUTHORITY) revert InvalidAuthority();
        if (delegation_.caveats.length != 1 || delegation_.caveats[0].enforcer != address(this)) revert InvalidCaveat();

        bytes32 delegationHash_ = _getSingleCaveatDelegationHash(delegation_);
        if (disabledDelegations[delegationHash_]) revert CannotUseADisabledDelegation();

        Terms memory termsInfo_ = getTermsInfo(delegation_.caveats[0].terms);
        _validateSignature(delegation_, delegationHash_);

        disabledDelegations[delegationHash_] = true;
        uint256 balanceBefore_ = _balanceOf(termsInfo_.tokenOut, termsInfo_.recipient);

        _executeSettlement(delegation_.delegator, executionContexts_[0], termsInfo_);

        uint256 balanceAfter_ = _balanceOf(termsInfo_.tokenOut, termsInfo_.recipient);
        if (balanceAfter_ < balanceBefore_ || balanceAfter_ - balanceBefore_ < termsInfo_.tokenOutMin) {
            revert InsufficientOutput();
        }

        emit RedeemedDelegation(delegation_.delegator, msg.sender, delegation_);
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
     * @notice Decodes and validates packed settlement terms.
     * @param terms_ Packed settlement terms.
     */
    function getTermsInfo(bytes memory terms_) public pure returns (Terms memory termsInfo_) {
        if (terms_.length != TERMS_LENGTH) revert InvalidTerms();

        // Terms are tightly packed. Loading their fixed offsets directly avoids allocating seven temporary byte arrays.
        assembly ("memory-safe") {
            let termsData_ := add(terms_, 0x20)
            mstore(termsInfo_, shr(96, mload(termsData_)))
            mstore(add(termsInfo_, 0x20), shr(96, mload(add(termsData_, 20))))
            mstore(add(termsInfo_, 0x40), mload(add(termsData_, 40)))
            mstore(add(termsInfo_, 0x80), shr(96, mload(add(termsData_, 73))))
            mstore(add(termsInfo_, 0xa0), shr(96, mload(add(termsData_, 93))))
            mstore(add(termsInfo_, 0xc0), mload(add(termsData_, 113)))
        }
        uint8 approvalMode_ = uint8(terms_[72]);

        if (
            termsInfo_.metaSwap == address(0) || termsInfo_.tokenInAmount == 0 || termsInfo_.recipient == address(0)
                || termsInfo_.tokenOutMin == 0 || termsInfo_.tokenIn == termsInfo_.tokenOut
        ) {
            revert InvalidTerms();
        }
        if (approvalMode_ > uint8(ApprovalMode.ResetApprove)) revert InvalidApprovalMode();
        termsInfo_.approvalMode = ApprovalMode(approvalMode_);
    }

    function _executeSettlement(address delegator_, bytes calldata executionContext_, Terms memory termsInfo_) internal virtual;

    function _validateSignature(Delegation memory delegation_, bytes32 delegationHash_) private view {
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), delegationHash_);

        if (signatureMode == SignatureMode.DirectECDSA) {
            if (ECDSA.recover(typedDataHash_, delegation_.signature) != delegation_.delegator) {
                revert InvalidEOASignature();
            }
        } else {
            bytes4 result_ = IERC1271(delegation_.delegator).isValidSignature(typedDataHash_, delegation_.signature);
            if (result_ != ERC1271Lib.EIP1271_MAGIC_VALUE) revert InvalidERC1271Signature();
        }
    }

    function _getSingleCaveatDelegationHash(Delegation memory delegation_) private pure returns (bytes32) {
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

    function _balanceOf(address token_, address recipient_) private view returns (uint256) {
        return token_ == address(0) ? recipient_.balance : IERC20(token_).balanceOf(recipient_);
    }
}
