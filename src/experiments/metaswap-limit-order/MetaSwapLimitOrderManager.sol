// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IDelegationManager } from "../../interfaces/IDelegationManager.sol";
import { IDeleGatorCore } from "../../interfaces/IDeleGatorCore.sol";
import { EncoderLib } from "../../libraries/EncoderLib.sol";
import { ERC1271Lib } from "../../libraries/ERC1271Lib.sol";
import { Delegation, ModeCode } from "../../utils/Types.sol";
import { MetaSwapLimitOrderLib } from "./MetaSwapLimitOrderLib.sol";

/**
 * @title MetaSwapLimitOrderManager
 * @notice Specialized one-shot MetaSwap manager with the standard `redeemDelegations` entry point.
 * @dev Supports exactly one root delegation, one manager-profile caveat, and one transfer-plus-swap batch.
 */
contract MetaSwapLimitOrderManager is IDelegationManager, Ownable2Step, Pausable, EIP712 {
    string public constant NAME = "MetaSwapLimitOrderManager";
    string public constant VERSION = "1.0.0-experiment";
    string public constant DOMAIN_VERSION = "1";

    bytes32 public constant ROOT_AUTHORITY = bytes32(type(uint256).max);
    address public constant ANY_DELEGATE = address(0xa11);

    mapping(bytes32 delegationHash => bool disabled) public disabledDelegations;
    mapping(bytes32 delegationHash => bool used) public usedDelegations;

    event LimitOrderUsed(bytes32 indexed delegationHash, address indexed maker, address indexed executor);

    error DelegationAlreadyUsed();
    error InvalidOrderProfile();

    modifier onlyDeleGator(address _delegator) {
        if (_delegator != msg.sender) revert InvalidDelegator();
        _;
    }

    /**
     * @notice Initializes the manager and its EIP-712 domain.
     * @param _owner Initial pause authority.
     */
    constructor(address _owner) Ownable(_owner) EIP712(NAME, DOMAIN_VERSION) {
        emit SetDomain(_domainSeparatorV4(), NAME, DOMAIN_VERSION, block.chainid, address(this));
    }

    /**
     * @notice Pauses new limit-order fills.
     * @dev Recommended delegation: owner-only emergency action restricted to this selector.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resumes limit-order fills.
     * @dev Recommended delegation: owner-only emergency action restricted to this selector.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Disables an unfilled order.
     * @param _delegation Maker-signed delegation to cancel.
     */
    function disableDelegation(Delegation calldata _delegation) external onlyDeleGator(_delegation.delegator) {
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(_delegation);
        if (disabledDelegations[delegationHash_]) revert AlreadyDisabled();
        disabledDelegations[delegationHash_] = true;
        emit DisabledDelegation(delegationHash_, _delegation.delegator, _delegation.delegate, _delegation);
    }

    /**
     * @notice Re-enables a previously disabled, unfilled order.
     * @param _delegation Maker-signed delegation to enable.
     */
    function enableDelegation(Delegation calldata _delegation) external onlyDeleGator(_delegation.delegator) {
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(_delegation);
        if (!disabledDelegations[delegationHash_]) revert AlreadyEnabled();
        disabledDelegations[delegationHash_] = false;
        emit EnabledDelegation(delegationHash_, _delegation.delegator, _delegation.delegate, _delegation);
    }

    /**
     * @notice Validates and executes one specialized MetaSwap limit order.
     * @param _permissionContexts Exactly one ABI-encoded single-delegation array.
     * @param _modes Exactly one ERC-7579 batch/default mode.
     * @param _executionCallDatas Exactly one transfer-plus-swap batch.
     */
    function redeemDelegations(
        bytes[] calldata _permissionContexts,
        ModeCode[] calldata _modes,
        bytes[] calldata _executionCallDatas
    )
        external
        whenNotPaused
    {
        if (_permissionContexts.length != 1 || _modes.length != 1 || _executionCallDatas.length != 1) {
            revert BatchDataLengthMismatch();
        }

        Delegation[] memory delegations_ = abi.decode(_permissionContexts[0], (Delegation[]));
        if (delegations_.length != 1) revert InvalidOrderProfile();
        Delegation memory delegation_ = delegations_[0];

        if (delegation_.delegate != msg.sender && delegation_.delegate != ANY_DELEGATE) revert InvalidDelegate();
        if (
            delegation_.authority != ROOT_AUTHORITY || delegation_.caveats.length != 1
                || delegation_.caveats[0].enforcer != address(this)
        ) {
            revert InvalidOrderProfile();
        }

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        _validateSignature(delegation_.delegator, delegationHash_, delegation_.signature);
        if (disabledDelegations[delegationHash_]) revert CannotUseADisabledDelegation();
        if (usedDelegations[delegationHash_]) revert DelegationAlreadyUsed();

        MetaSwapLimitOrderLib.Terms memory terms_ = abi.decode(delegation_.caveats[0].terms, (MetaSwapLimitOrderLib.Terms));
        MetaSwapLimitOrderLib.validateTerms(terms_);
        MetaSwapLimitOrderLib.validateExecution(terms_, _modes[0], _executionCallDatas[0]);

        usedDelegations[delegationHash_] = true;
        IDeleGatorCore(delegation_.delegator).executeFromExecutor(_modes[0], _executionCallDatas[0]);

        emit LimitOrderUsed(delegationHash_, delegation_.delegator, msg.sender);
        emit RedeemedDelegation(delegation_.delegator, msg.sender, delegation_);
    }

    /**
     * @notice Returns this manager's EIP-712 domain separator.
     * @return domainHash_ Current domain separator.
     */
    function getDomainHash() public view returns (bytes32 domainHash_) {
        domainHash_ = _domainSeparatorV4();
    }

    /**
     * @notice Hashes a delegation without its signature or caveat args.
     * @param _delegation Delegation to hash.
     * @return delegationHash_ EIP-712 delegation struct hash.
     */
    function getDelegationHash(Delegation calldata _delegation) public pure returns (bytes32 delegationHash_) {
        delegationHash_ = EncoderLib._getDelegationHash(_delegation);
    }

    function _validateSignature(address _delegator, bytes32 _delegationHash, bytes memory _signature) private view {
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), _delegationHash);
        if (_delegator.code.length == 0) {
            if (ECDSA.recover(typedDataHash_, _signature) != _delegator) revert InvalidEOASignature();
            return;
        }

        if (IERC1271(_delegator).isValidSignature(typedDataHash_, _signature) != ERC1271Lib.EIP1271_MAGIC_VALUE) {
            revert InvalidERC1271Signature();
        }
    }
}
