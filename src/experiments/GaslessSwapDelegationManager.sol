// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ICaveatEnforcer } from "../interfaces/ICaveatEnforcer.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IDeleGatorCore } from "../interfaces/IDeleGatorCore.sol";
import { EncoderLib } from "../libraries/EncoderLib.sol";
import { ERC1271Lib } from "../libraries/ERC1271Lib.sol";
import { Caveat, Delegation, ModeCode } from "../utils/Types.sol";

/**
 * @title GaslessSwapDelegationManager
 * @notice Specialized ERC-7710 manager for exact one-shot swaps and one-shot limit orders.
 * @dev Supports one root delegation and one redemption per call. Two signed caveat profiles are accepted:
 *
 *      Gasless swap:
 *      1. ExactExecutionEnforcer
 *      2. LimitedCallsEnforcer with limit = 1
 *
 *      Limit order:
 *      1. ExactExecutionEnforcer OR MetaSwap7702CalldataEnforcer
 *      2. LimitedCallsEnforcer with limit = 1
 *      3. NativeBalanceChangeEnforcer OR ERC20BalanceChangeEnforcer, configured for a minimum increase
 *         of the root delegator's output-token balance.
 *
 * @dev Existing enforcers are reused unchanged. The manager invokes every `beforeHook`, executes once through
 *      `executeFromExecutor`, and invokes only the limit-order balance caveat's `afterHook`. Reverted executions or
 *      insufficient output revert the LimitedCalls counter too, so the same signed order remains retryable.
 * @dev Designed for {EIP7702MultiManagerDeleGatorCore}: this manager must first be approved by the 7702 account.
 */
contract GaslessSwapDelegationManager is EIP712 {
    using MessageHashUtils for bytes32;

    string public constant NAME = "GaslessSwapDelegationManager";
    string public constant VERSION = "1.0.0";
    string public constant DOMAIN_VERSION = "1";

    bytes32 public constant ROOT_AUTHORITY = bytes32(type(uint256).max);
    address public constant ANY_DELEGATE = address(0xa11);

    address public immutable exactExecutionEnforcer;
    address public immutable metaSwap7702CalldataEnforcer;
    address public immutable limitedCallsEnforcer;
    address public immutable nativeBalanceChangeEnforcer;
    address public immutable erc20BalanceChangeEnforcer;

    mapping(bytes32 delegationHash => bool isDisabled) public disabledDelegations;

    event RedeemedDelegation(address indexed rootDelegator, address indexed redeemer, bytes32 indexed delegationHash);

    error InvalidConfiguration();
    error InvalidProfile();
    error InvalidBalanceTerms();
    error InvalidDelegatorAccount();

    modifier onlyDeleGator(address delegator_) {
        if (delegator_ != msg.sender) revert IDelegationManager.InvalidDelegator();
        _;
    }

    /**
     * @notice Configures the only enforcers accepted by this manager.
     * @param exactExecutionEnforcer_ ExactExecutionEnforcer deployment.
     * @param metaSwap7702CalldataEnforcer_ MetaSwap7702CalldataEnforcer deployment.
     * @param limitedCallsEnforcer_ LimitedCallsEnforcer deployment.
     * @param nativeBalanceChangeEnforcer_ NativeBalanceChangeEnforcer deployment.
     * @param erc20BalanceChangeEnforcer_ ERC20BalanceChangeEnforcer deployment.
     */
    constructor(
        address exactExecutionEnforcer_,
        address metaSwap7702CalldataEnforcer_,
        address limitedCallsEnforcer_,
        address nativeBalanceChangeEnforcer_,
        address erc20BalanceChangeEnforcer_
    )
        EIP712(NAME, DOMAIN_VERSION)
    {
        if (
            exactExecutionEnforcer_ == address(0) || metaSwap7702CalldataEnforcer_ == address(0)
                || limitedCallsEnforcer_ == address(0)
                || nativeBalanceChangeEnforcer_ == address(0) || erc20BalanceChangeEnforcer_ == address(0)
        ) {
            revert InvalidConfiguration();
        }

        exactExecutionEnforcer = exactExecutionEnforcer_;
        metaSwap7702CalldataEnforcer = metaSwap7702CalldataEnforcer_;
        limitedCallsEnforcer = limitedCallsEnforcer_;
        nativeBalanceChangeEnforcer = nativeBalanceChangeEnforcer_;
        erc20BalanceChangeEnforcer = erc20BalanceChangeEnforcer_;

        emit IDelegationManager.SetDomain(_domainSeparatorV4(), NAME, DOMAIN_VERSION, block.chainid, address(this));
    }

    /**
     * @notice Permanently disables a signed swap or limit-order delegation.
     * @param delegation_ Delegation being cancelled by its delegator.
     */
    function disableDelegation(Delegation calldata delegation_) external onlyDeleGator(delegation_.delegator) {
        bytes32 delegationHash_ = getDelegationHash(delegation_);
        if (disabledDelegations[delegationHash_]) revert IDelegationManager.AlreadyDisabled();

        disabledDelegations[delegationHash_] = true;
        emit IDelegationManager.DisabledDelegation(delegationHash_, delegation_.delegator, delegation_.delegate, delegation_);
    }

    /**
     * @notice Redeems one exact gasless swap or one exact limit order.
     * @param permissionContexts_ Exactly one `abi.encode(Delegation[])` containing one root delegation.
     * @param modes_ Exactly one execution mode; ExactExecutionEnforcer requires single/default mode.
     * @param executionCallDatas_ Exactly one packed single execution.
     */
    function redeemDelegations(
        bytes[] calldata permissionContexts_,
        ModeCode[] calldata modes_,
        bytes[] calldata executionCallDatas_
    )
        external
    {
        if (permissionContexts_.length != 1 || modes_.length != 1 || executionCallDatas_.length != 1) {
            revert IDelegationManager.BatchDataLengthMismatch();
        }

        Delegation[] memory delegations_ = abi.decode(permissionContexts_[0], (Delegation[]));
        if (delegations_.length != 1) revert InvalidProfile();

        Delegation memory delegation_ = delegations_[0];
        if (delegation_.delegate != msg.sender && delegation_.delegate != ANY_DELEGATE) {
            revert IDelegationManager.InvalidDelegate();
        }
        if (delegation_.authority != ROOT_AUTHORITY) revert IDelegationManager.InvalidAuthority();
        if (delegation_.delegator.code.length == 0) revert InvalidDelegatorAccount();

        bool isLimitOrder_ = _validateProfile(delegation_);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        _validateSignature(
            delegation_.delegator, MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), delegationHash_), delegation_.signature
        );
        if (disabledDelegations[delegationHash_]) revert IDelegationManager.CannotUseADisabledDelegation();

        Caveat[] memory caveats_ = delegation_.caveats;
        uint256 caveatCount_ = caveats_.length;
        for (uint256 i; i < caveatCount_; ++i) {
            _beforeHook(caveats_[i], modes_[0], executionCallDatas_[0], delegationHash_, delegation_.delegator);
        }

        IDeleGatorCore(delegation_.delegator).executeFromExecutor(modes_[0], executionCallDatas_[0]);

        if (isLimitOrder_) {
            Caveat memory balanceCaveat_ = caveats_[2];
            ICaveatEnforcer(balanceCaveat_.enforcer)
                .afterHook(
                    balanceCaveat_.terms,
                    balanceCaveat_.args,
                    modes_[0],
                    executionCallDatas_[0],
                    delegationHash_,
                    delegation_.delegator,
                    msg.sender
                );
        }

        emit RedeemedDelegation(delegation_.delegator, msg.sender, delegationHash_);
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
     * @param delegation_ Delegation to hash.
     * @return delegationHash_ Delegation struct hash.
     */
    function getDelegationHash(Delegation calldata delegation_) public pure returns (bytes32 delegationHash_) {
        delegationHash_ = EncoderLib._getDelegationHash(delegation_);
    }

    function _validateProfile(Delegation memory delegation_) private view returns (bool isLimitOrder_) {
        Caveat[] memory caveats_ = delegation_.caveats;
        uint256 count_ = caveats_.length;
        if (count_ != 2 && count_ != 3) revert InvalidProfile();

        bool exactExecution_ = caveats_[0].enforcer == exactExecutionEnforcer;
        bool flexibleMetaSwap_ = caveats_[0].enforcer == metaSwap7702CalldataEnforcer;
        if (
            (!exactExecution_ && !flexibleMetaSwap_) || (count_ == 2 && !exactExecution_)
                || caveats_[1].enforcer != limitedCallsEnforcer
                || caveats_[0].args.length != 0 || caveats_[1].args.length != 0 || caveats_[1].terms.length != 32
                || _loadWord(caveats_[1].terms, 0) != 1
        ) {
            revert InvalidProfile();
        }

        if (count_ == 2) return false;

        Caveat memory balanceCaveat_ = caveats_[2];
        if (balanceCaveat_.args.length != 0) revert InvalidProfile();

        if (balanceCaveat_.enforcer == nativeBalanceChangeEnforcer) {
            _validateNativeBalanceTerms(balanceCaveat_.terms, delegation_.delegator);
        } else if (balanceCaveat_.enforcer == erc20BalanceChangeEnforcer) {
            _validateERC20BalanceTerms(balanceCaveat_.terms, delegation_.delegator);
        } else {
            revert InvalidProfile();
        }

        return true;
    }

    function _validateNativeBalanceTerms(bytes memory terms_, address delegator_) private pure {
        // packed: bool enforceDecrease | address recipient | uint256 tokenOutMin
        if (terms_.length != 53 || terms_[0] != bytes1(0) || _loadAddress(terms_, 1) != delegator_ || _loadWord(terms_, 21) == 0) {
            revert InvalidBalanceTerms();
        }
    }

    function _validateERC20BalanceTerms(bytes memory terms_, address delegator_) private pure {
        // packed: bool enforceDecrease | address tokenOut | address recipient | uint256 tokenOutMin
        if (
            terms_.length != 73 || terms_[0] != bytes1(0) || _loadAddress(terms_, 1) == address(0)
                || _loadAddress(terms_, 21) != delegator_ || _loadWord(terms_, 41) == 0
        ) {
            revert InvalidBalanceTerms();
        }
    }

    function _beforeHook(
        Caveat memory caveat_,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32 delegationHash_,
        address delegator_
    )
        private
    {
        ICaveatEnforcer(caveat_.enforcer)
            .beforeHook(caveat_.terms, caveat_.args, mode_, executionCallData_, delegationHash_, delegator_, msg.sender);
    }

    function _validateSignature(address delegator_, bytes32 typedDataHash_, bytes memory signature_) private view {
        (address recovered_, ECDSA.RecoverError error_,) = ECDSA.tryRecover(typedDataHash_, signature_);
        if (error_ == ECDSA.RecoverError.NoError && recovered_ == delegator_) return;

        if (IERC1271(delegator_).isValidSignature(typedDataHash_, signature_) != ERC1271Lib.EIP1271_MAGIC_VALUE) {
            revert IDelegationManager.InvalidERC1271Signature();
        }
    }

    function _loadAddress(bytes memory data_, uint256 offset_) private pure returns (address value_) {
        assembly {
            value_ := shr(96, mload(add(add(data_, 0x20), offset_)))
        }
    }

    function _loadWord(bytes memory data_, uint256 offset_) private pure returns (uint256 value_) {
        assembly {
            value_ := mload(add(add(data_, 0x20), offset_))
        }
    }
}
