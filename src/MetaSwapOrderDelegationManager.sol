// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { BitMaps } from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { MetaSwapDelegationManagerBase } from "./MetaSwapDelegationManagerBase.sol";
import { IMetaSwap } from "./helpers/interfaces/IMetaSwap.sol";
import { IDeleGatorCore } from "./interfaces/IDeleGatorCore.sol";
import { Execution } from "./utils/Types.sol";

/**
 * @title MetaSwapOrderDelegationManager
 * @notice One purpose-specific manager for exact batches and flexible MetaSwap limit orders.
 * @dev No external caveat hooks and no redelegation chains. Both intents redeem through a direct
 *      batch/default `executeFromExecutor`.
 *
 * Exact batch terms: `intent(1) | executionHash(32)` where `executionHash = keccak256(executionCallDatas[0])`.
 * Expiry and the redeemer stay off this path: `delegate` is the redeemer (or `ANY_DELEGATE`), and
 * `disabledDelegations` is the one-shot.
 *
 * Flexible terms: `intent(1) | metaSwap(20) | tokenIn(20) | tokenInAmount(32) | approvalMode(1) |
 * tokenOut(20) | recipient(20) | tokenOutMin(32) | timestampAfter(16) | timestampBefore(16) | id(32) |
 * redeemers(20*N)`.
 *
 * Limit-order policies, embedded because this manager does not call caveat hooks:
 * - Redeemers are required. `address(0)` is a normal allowlist entry, so a Sentinel pre-sign (`from = 0x0`)
 *   can be included without authorizing every caller.
 * - Timestamp bounds are optional. `0` disables that bound. Bounds are exclusive, matching `TimestampEnforcer`.
 * - `id == 0` skips the bitmap. One-shot is still the delegation hash. `id != 0` also burns that id for the
 *   delegator, so sibling orders that share it cannot fill. `disableDelegation` does not burn the id.
 */
contract MetaSwapOrderDelegationManager is MetaSwapDelegationManagerBase {
    using BitMaps for BitMaps.BitMap;
    using ExecutionLib for bytes;

    enum Intent {
        ExactBatch,
        FlexibleSettlement
    }

    enum ApprovalMode {
        None,
        SkipApproval,
        Approve,
        ResetApprove
    }

    struct FlexibleTerms {
        address metaSwap;
        address tokenIn;
        uint256 tokenInAmount;
        ApprovalMode approvalMode;
        address tokenOut;
        address recipient;
        uint256 tokenOutMin;
        uint128 timestampAfter;
        uint128 timestampBefore;
        uint256 id;
        address[] redeemers;
    }

    string public constant NAME = "MetaSwapOrderDelegationManager";

    uint256 private constant EXACT_TERMS_LENGTH = 33;
    /// @dev Intent through id. Redeemers are a non-empty 20-byte tail.
    uint256 private constant FLEXIBLE_FIXED_TERMS_LENGTH = 210;
    uint256 private constant APPROVE_CALL_LENGTH = 68;
    uint256 private constant SWAP_CALL_MIN_LENGTH = 196;

    /// @dev IdEnforcer bitmap. Unused when `id == 0`.
    mapping(address delegator => BitMaps.BitMap ids) private isUsedId;

    event UsedId(address indexed delegator, address indexed redeemer, uint256 id);

    error ApprovalShapeNotAllowed();
    error EarlyDelegation();
    error ExpiredDelegation();
    error IdAlreadyUsed();
    error InvalidApproval();
    error InvalidApprovalMode();
    error InvalidBatchLength();
    error InvalidExecutionHash();
    error InvalidIntent();
    error InvalidSwap();
    error UnauthorizedRedeemer();

    constructor() MetaSwapDelegationManagerBase(NAME) { }

    /**
     * @notice Decodes exact-batch terms.
     * @param terms_ Packed as `intent(1) | executionHash(32)`.
     */
    function getExactTermsInfo(bytes memory terms_) public pure returns (bytes32 executionHash_) {
        if (terms_.length != EXACT_TERMS_LENGTH || uint8(terms_[0]) != uint8(Intent.ExactBatch)) {
            revert InvalidTerms();
        }
        assembly ("memory-safe") {
            executionHash_ := mload(add(terms_, 33))
        }
    }

    /**
     * @notice Decodes flexible settlement terms.
     * @param terms_ Packed as `intent(1) | settlement(145) | timestampAfter(16) | timestampBefore(16) | id(32) |
     * redeemers(20*N)`.
     */
    function getFlexibleTermsInfo(bytes memory terms_) public pure returns (FlexibleTerms memory termsInfo_) {
        uint256 termsLength_ = terms_.length;
        uint256 redeemerBytes_ = termsLength_ < FLEXIBLE_FIXED_TERMS_LENGTH ? 0 : termsLength_ - FLEXIBLE_FIXED_TERMS_LENGTH;
        if (
            termsLength_ < FLEXIBLE_FIXED_TERMS_LENGTH + 20 || redeemerBytes_ % 20 != 0
                || uint8(terms_[0]) != uint8(Intent.FlexibleSettlement)
        ) {
            revert InvalidTerms();
        }

        assembly ("memory-safe") {
            let termsData_ := add(terms_, 0x21)
            mstore(termsInfo_, shr(96, mload(termsData_)))
            mstore(add(termsInfo_, 0x20), shr(96, mload(add(termsData_, 20))))
            mstore(add(termsInfo_, 0x40), mload(add(termsData_, 40)))
            mstore(add(termsInfo_, 0x80), shr(96, mload(add(termsData_, 73))))
            mstore(add(termsInfo_, 0xa0), shr(96, mload(add(termsData_, 93))))
            mstore(add(termsInfo_, 0xc0), mload(add(termsData_, 113)))
            // Memory structs keep one 32-byte slot per field, so the packed uint128s are widened here.
            mstore(add(termsInfo_, 0xe0), shr(128, mload(add(termsData_, 145))))
            mstore(add(termsInfo_, 0x100), shr(128, mload(add(termsData_, 161))))
            mstore(add(termsInfo_, 0x120), mload(add(termsData_, 177)))
        }
        uint8 approvalMode_ = uint8(terms_[73]);

        if (
            termsInfo_.metaSwap == address(0) || termsInfo_.tokenInAmount == 0 || termsInfo_.recipient == address(0)
                || termsInfo_.tokenOutMin == 0 || termsInfo_.tokenIn == termsInfo_.tokenOut
        ) {
            revert InvalidTerms();
        }
        if (approvalMode_ > uint8(ApprovalMode.ResetApprove)) revert InvalidApprovalMode();
        termsInfo_.approvalMode = ApprovalMode(approvalMode_);

        uint256 redeemerCount_ = redeemerBytes_ / 20;
        address[] memory redeemers_ = new address[](redeemerCount_);
        for (uint256 i_; i_ < redeemerCount_; ++i_) {
            uint256 offset_ = FLEXIBLE_FIXED_TERMS_LENGTH + (i_ * 20);
            redeemers_[i_] = address(bytes20(_loadWord(terms_, offset_)));
        }
        termsInfo_.redeemers = redeemers_;
    }

    /**
     * @notice Returns whether a limit-order id has been filled for this delegator.
     * @dev `id == 0` is never recorded. Hash one-shot for that order lives in `disabledDelegations`.
     */
    function getIsUsed(address delegator_, uint256 id_) external view returns (bool) {
        return isUsedId[delegator_].get(id_);
    }

    function _executeIntent(address delegator_, bytes memory terms_, bytes calldata executionContext_) internal override {
        if (terms_.length == 0) revert InvalidTerms();

        uint8 intent_ = uint8(terms_[0]);
        if (intent_ == uint8(Intent.ExactBatch)) {
            _executeExact(delegator_, terms_, executionContext_);
        } else if (intent_ == uint8(Intent.FlexibleSettlement)) {
            _executeFlexible(delegator_, terms_, executionContext_);
        } else {
            revert InvalidIntent();
        }
    }

    function _executeExact(address delegator_, bytes memory terms_, bytes calldata executionContext_) private {
        bytes32 expectedHash_ = getExactTermsInfo(terms_);
        if (keccak256(executionContext_) != expectedHash_) revert InvalidExecutionHash();

        IDeleGatorCore(delegator_).executeFromExecutor(SIMPLE_BATCH_MODE, executionContext_);
    }

    function _executeFlexible(address delegator_, bytes memory terms_, bytes calldata executionContext_) private {
        FlexibleTerms memory termsInfo_ = getFlexibleTermsInfo(terms_);
        _validateRedeemer(termsInfo_.redeemers);
        _validateTimestamp(termsInfo_.timestampAfter, termsInfo_.timestampBefore);

        Execution[] calldata executions_ = executionContext_.decodeBatch();
        _validateExecutions(executions_, termsInfo_);
        _consumeId(delegator_, termsInfo_.id);

        uint256 balanceBefore_ = _balanceOf(termsInfo_.tokenOut, termsInfo_.recipient);
        IDeleGatorCore(delegator_).executeFromExecutor(SIMPLE_BATCH_MODE, executionContext_);
        uint256 balanceAfter_ = _balanceOf(termsInfo_.tokenOut, termsInfo_.recipient);

        if (balanceAfter_ < balanceBefore_ || balanceAfter_ - balanceBefore_ < termsInfo_.tokenOutMin) {
            revert InsufficientOutput();
        }
    }

    function _validateRedeemer(address[] memory redeemers_) private view {
        uint256 length_ = redeemers_.length;
        for (uint256 i_; i_ < length_; ++i_) {
            if (msg.sender == redeemers_[i_]) return;
        }
        revert UnauthorizedRedeemer();
    }

    /// @dev `0` disables a bound. A set bound is exclusive, matching TimestampEnforcer.
    function _validateTimestamp(uint128 timestampAfter_, uint128 timestampBefore_) private view {
        if (timestampAfter_ != 0 && block.timestamp <= timestampAfter_) revert EarlyDelegation();
        if (timestampBefore_ != 0 && block.timestamp >= timestampBefore_) revert ExpiredDelegation();
    }

    /// @dev `id == 0` keeps the delegation-hash one-shot only. A non-zero id also excludes sibling orders.
    function _consumeId(address delegator_, uint256 id_) private {
        if (id_ == 0) return;
        if (isUsedId[delegator_].get(id_)) revert IdAlreadyUsed();
        isUsedId[delegator_].set(id_);
        emit UsedId(delegator_, msg.sender, id_);
    }

    function _loadWord(bytes memory data_, uint256 offset_) private pure returns (bytes32 value_) {
        assembly ("memory-safe") {
            value_ := mload(add(add(data_, 0x20), offset_))
        }
    }

    function _validateExecutions(Execution[] calldata executions_, FlexibleTerms memory termsInfo_) private pure {
        ApprovalMode approvalMode_ = termsInfo_.approvalMode;

        if (termsInfo_.tokenIn == address(0)) {
            if (approvalMode_ != ApprovalMode.None) revert InvalidApprovalMode();
            if (executions_.length != 1) revert InvalidBatchLength();
            _validateSwap(executions_[0], termsInfo_.metaSwap, address(0), termsInfo_.tokenInAmount, termsInfo_.tokenInAmount);
            return;
        }

        if (approvalMode_ == ApprovalMode.SkipApproval) {
            if (executions_.length != 1) revert ApprovalShapeNotAllowed();
            _validateSwap(executions_[0], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        } else if (approvalMode_ == ApprovalMode.Approve) {
            if (executions_.length != 2) revert ApprovalShapeNotAllowed();
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            _validateSwap(executions_[1], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        } else if (approvalMode_ == ApprovalMode.ResetApprove) {
            if (executions_.length != 3) revert ApprovalShapeNotAllowed();
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, 0);
            _validateApproval(executions_[1], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            _validateSwap(executions_[2], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        } else {
            revert InvalidApprovalMode();
        }
    }

    function _validateApproval(
        Execution calldata execution_,
        address tokenIn_,
        address metaSwap_,
        uint256 expectedAmount_
    )
        private
        pure
    {
        bytes calldata callData_ = execution_.callData;
        if (
            execution_.target != tokenIn_ || execution_.value != 0 || callData_.length != APPROVE_CALL_LENGTH
                || bytes4(callData_[0:4]) != IERC20.approve.selector
                || bytes32(callData_[4:36]) != bytes32(uint256(uint160(metaSwap_)))
                || uint256(bytes32(callData_[36:68])) != expectedAmount_
        ) {
            revert InvalidApproval();
        }
    }

    function _validateSwap(
        Execution calldata execution_,
        address metaSwap_,
        address tokenIn_,
        uint256 tokenInAmount_,
        uint256 expectedValue_
    )
        private
        pure
    {
        bytes calldata callData_ = execution_.callData;
        if (
            execution_.target != metaSwap_ || execution_.value != expectedValue_ || callData_.length < SWAP_CALL_MIN_LENGTH
                || bytes4(callData_[0:4]) != IMetaSwap.swap.selector
                || bytes32(callData_[36:68]) != bytes32(uint256(uint160(tokenIn_)))
                || uint256(bytes32(callData_[68:100])) != tokenInAmount_
        ) {
            revert InvalidSwap();
        }
    }
}
