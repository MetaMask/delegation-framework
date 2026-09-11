// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { IDeleGatorCore } from "./interfaces/IDeleGatorCore.sol";
import { IMetaSwap } from "./helpers/interfaces/IMetaSwap.sol";
import { EncoderLib } from "./libraries/EncoderLib.sol";
import { ERC1271Lib } from "./libraries/ERC1271Lib.sol";
import { CallType, Caveat, Delegation, Execution, ExecType, ModeCode } from "./utils/Types.sol";
import { CALLTYPE_BATCH, CALLTYPE_SINGLE, EXECTYPE_DEFAULT } from "./utils/Constants.sol";

/**
 * @title MetaSwapMinimalDelegationManager
 * @notice Minimal one-shot manager for exact gasless swaps and dynamically routed MetaSwap limit orders.
 * @dev This manager does not invoke external caveat enforcers. Each delegation contains exactly one caveat whose enforcer is
 *      this manager and whose first terms byte selects one of two profiles:
 *
 *      - Gasless exact (`0x00`): terms commit to `keccak256(mode || executionCallData)`.
 *      - Limit order (`0x01`): terms commit to MetaSwap, tokenIn, tokenOut, tokenInAmount, tokenOutMin and approval shape.
 *
 * For a limit order, `executionCallDatas[0]` is `abi.encode(string aggregatorId, bytes routeData)`. The manager constructs the
 * approval-and-swap batch itself, so there is no caller-supplied batch to validate. Output balance is checked directly after
 * execution. A reverting execution or insufficient output rolls back the one-shot marker.
 */
contract MetaSwapMinimalDelegationManager is EIP712 {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;

    string public constant NAME = "MetaSwapMinimalDelegationManager";
    string public constant VERSION = "1.0.0";
    string public constant DOMAIN_VERSION = "1";

    bytes32 public constant ROOT_AUTHORITY = bytes32(type(uint256).max);
    address public constant ANY_DELEGATE = address(0xa11);

    uint8 public constant GASLESS_EXACT_PROFILE = 0;
    uint8 public constant LIMIT_ORDER_PROFILE = 1;

    uint256 private constant GASLESS_TERMS_LENGTH = 33;
    uint256 private constant LIMIT_ORDER_TERMS_LENGTH = 126;

    mapping(bytes32 delegationHash => bool isDisabled) public disabledDelegations;
    mapping(bytes32 delegationHash => bool isUsed) public usedDelegations;

    event RedeemedDelegation(
        address indexed rootDelegator, address indexed redeemer, bytes32 indexed delegationHash, uint8 profile
    );

    error InvalidProfile();
    error InvalidTerms();
    error InvalidMode();
    error InvalidDelegatorAccount();
    error DelegationAlreadyUsed();
    error InsufficientOutput(uint256 minimum, uint256 received);

    struct LimitOrderTerms {
        address metaSwap;
        address tokenIn;
        address tokenOut;
        uint256 tokenInAmount;
        uint256 tokenOutMin;
        bool resetApproval;
    }

    modifier onlyDeleGator(address delegator_) {
        if (delegator_ != msg.sender) revert IDelegationManager.InvalidDelegator();
        _;
    }

    constructor() EIP712(NAME, DOMAIN_VERSION) {
        emit IDelegationManager.SetDomain(_domainSeparatorV4(), NAME, DOMAIN_VERSION, block.chainid, address(this));
    }

    /**
     * @notice Permanently cancels a delegation.
     * @param delegation_ Delegation being cancelled by its delegator.
     */
    function disableDelegation(Delegation calldata delegation_) external onlyDeleGator(delegation_.delegator) {
        bytes32 delegationHash_ = getDelegationHash(delegation_);
        if (disabledDelegations[delegationHash_]) revert IDelegationManager.AlreadyDisabled();
        disabledDelegations[delegationHash_] = true;
        emit IDelegationManager.DisabledDelegation(delegationHash_, delegation_.delegator, delegation_.delegate, delegation_);
    }

    /**
     * @notice Executes one exact gasless action or fills one dynamically routed limit order.
     * @param permissionContexts_ Exactly one ABI-encoded array containing one root delegation.
     * @param modes_ Gasless execution mode, or batch/default for the limit-order profile.
     * @param executionCallDatas_ Exact ERC-7579 execution data for gasless, or ABI-encoded aggregator ID and route for a limit.
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
        if (
            delegation_.caveats.length != 1 || delegation_.caveats[0].enforcer != address(this)
                || delegation_.caveats[0].args.length != 0 || delegation_.caveats[0].terms.length == 0
        ) {
            revert InvalidProfile();
        }

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        _validateSignature(
            delegation_.delegator, MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), delegationHash_), delegation_.signature
        );
        if (disabledDelegations[delegationHash_]) revert IDelegationManager.CannotUseADisabledDelegation();
        if (usedDelegations[delegationHash_]) revert DelegationAlreadyUsed();

        Caveat memory profileCaveat_ = delegation_.caveats[0];
        uint8 profile_ = uint8(profileCaveat_.terms[0]);
        usedDelegations[delegationHash_] = true;

        if (profile_ == GASLESS_EXACT_PROFILE) {
            _executeGasless(delegation_.delegator, profileCaveat_.terms, modes_[0], executionCallDatas_[0]);
        } else if (profile_ == LIMIT_ORDER_PROFILE) {
            _executeLimitOrder(delegation_.delegator, profileCaveat_.terms, modes_[0], executionCallDatas_[0]);
        } else {
            revert InvalidProfile();
        }

        emit RedeemedDelegation(delegation_.delegator, msg.sender, delegationHash_, profile_);
    }

    /**
     * @notice Returns the exact gasless commitment signed in profile terms.
     */
    function getGaslessExecutionHash(ModeCode mode_, bytes calldata executionCallData_) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(ModeCode.unwrap(mode_), executionCallData_));
    }

    /**
     * @notice Returns this manager's EIP-712 domain separator.
     */
    function getDomainHash() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Returns the EIP-712 delegation struct hash.
     */
    function getDelegationHash(Delegation calldata delegation_) public pure returns (bytes32) {
        return EncoderLib._getDelegationHash(delegation_);
    }

    function _executeGasless(address delegator_, bytes memory terms_, ModeCode mode_, bytes calldata executionCallData_) private {
        if (terms_.length != GASLESS_TERMS_LENGTH) revert InvalidTerms();
        (CallType callType_, ExecType execType_,,) = mode_.decode();
        if (
            ExecType.unwrap(execType_) != ExecType.unwrap(EXECTYPE_DEFAULT)
                || (CallType.unwrap(callType_) != CallType.unwrap(CALLTYPE_SINGLE)
                    && CallType.unwrap(callType_) != CallType.unwrap(CALLTYPE_BATCH))
                || bytes32(_loadWord(terms_, 1)) != getGaslessExecutionHash(mode_, executionCallData_)
        ) {
            revert InvalidMode();
        }

        IDeleGatorCore(delegator_).executeFromExecutor(mode_, executionCallData_);
    }

    function _executeLimitOrder(address delegator_, bytes memory terms_, ModeCode mode_, bytes calldata routePayload_) private {
        if (ModeCode.unwrap(mode_) != ModeCode.unwrap(ModeLib.encodeSimpleBatch())) revert InvalidMode();
        LimitOrderTerms memory order_ = _decodeLimitOrderTerms(terms_);
        (string memory aggregatorId_, bytes memory routeData_) = abi.decode(routePayload_, (string, bytes));

        uint256 balanceBefore_ = _balanceOf(order_.tokenOut, delegator_);
        Execution[] memory executions_ = _buildLimitOrderExecutions(order_, aggregatorId_, routeData_);
        IDeleGatorCore(delegator_).executeFromExecutor(mode_, ExecutionLib.encodeBatch(executions_));

        uint256 balanceAfter_ = _balanceOf(order_.tokenOut, delegator_);
        uint256 received_ = balanceAfter_ > balanceBefore_ ? balanceAfter_ - balanceBefore_ : 0;
        if (received_ < order_.tokenOutMin) revert InsufficientOutput(order_.tokenOutMin, received_);
    }

    function _decodeLimitOrderTerms(bytes memory terms_) private pure returns (LimitOrderTerms memory order_) {
        if (terms_.length != LIMIT_ORDER_TERMS_LENGTH) revert InvalidTerms();

        order_.metaSwap = _loadAddress(terms_, 1);
        order_.tokenIn = _loadAddress(terms_, 21);
        order_.tokenOut = _loadAddress(terms_, 41);
        order_.tokenInAmount = _loadWord(terms_, 61);
        order_.tokenOutMin = _loadWord(terms_, 93);
        uint8 resetApprovalValue_ = uint8(terms_[125]);
        if (
            order_.metaSwap == address(0) || order_.tokenInAmount == 0 || order_.tokenOutMin == 0
                || order_.tokenIn == order_.tokenOut || resetApprovalValue_ > 1
                || (order_.tokenIn == address(0) && resetApprovalValue_ == 1)
        ) {
            revert InvalidTerms();
        }
        order_.resetApproval = resetApprovalValue_ == 1;
    }

    function _buildLimitOrderExecutions(
        LimitOrderTerms memory order_,
        string memory aggregatorId_,
        bytes memory routeData_
    )
        private
        pure
        returns (Execution[] memory executions_)
    {
        bytes memory swapCallData_ =
            abi.encodeCall(IMetaSwap.swap, (aggregatorId_, IERC20(order_.tokenIn), order_.tokenInAmount, routeData_));

        if (order_.tokenIn == address(0)) {
            executions_ = new Execution[](1);
            executions_[0] = Execution({ target: order_.metaSwap, value: order_.tokenInAmount, callData: swapCallData_ });
            return executions_;
        }

        uint256 swapIndex_ = order_.resetApproval ? 2 : 1;
        executions_ = new Execution[](swapIndex_ + 1);
        if (order_.resetApproval) {
            executions_[0] =
                Execution({ target: order_.tokenIn, value: 0, callData: abi.encodeCall(IERC20.approve, (order_.metaSwap, 0)) });
        }
        executions_[swapIndex_ - 1] = Execution({
            target: order_.tokenIn, value: 0, callData: abi.encodeCall(IERC20.approve, (order_.metaSwap, order_.tokenInAmount))
        });
        executions_[swapIndex_] = Execution({ target: order_.metaSwap, value: 0, callData: swapCallData_ });
    }

    function _balanceOf(address token_, address account_) private view returns (uint256) {
        return token_ == address(0) ? account_.balance : IERC20(token_).balanceOf(account_);
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
