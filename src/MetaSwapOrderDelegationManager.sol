// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { MetaSwapDelegationManagerBase } from "./MetaSwapDelegationManagerBase.sol";
import { IMetaSwap } from "./helpers/interfaces/IMetaSwap.sol";
import { IDeleGatorCore } from "./interfaces/IDeleGatorCore.sol";
import { Execution } from "./utils/Types.sol";

/**
 * @title MetaSwapOrderDelegationManager
 * @notice One purpose-specific manager for exact gasless swaps and flexible MetaSwap limit orders.
 * @dev No external caveat hooks. Both intents redeem through a direct batch/default `executeFromExecutor`.
 *
 * Exact terms: `intent(1) | executionHash(32)` where `executionHash = keccak256(executionCallDatas[0])`.
 * Flexible terms: `intent(1) | metaSwap(20) | tokenIn(20) | tokenInAmount(32) | approvalMode(1) |
 * tokenOut(20) | recipient(20) | tokenOutMin(32)`.
 */
contract MetaSwapOrderDelegationManager is MetaSwapDelegationManagerBase {
    using ExecutionLib for bytes;

    enum Intent {
        ExactCalldata,
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
    }

    string public constant NAME = "MetaSwapOrderDelegationManager";

    uint256 private constant EXACT_TERMS_LENGTH = 33;
    uint256 private constant FLEXIBLE_TERMS_LENGTH = 146;
    uint256 private constant APPROVE_CALL_LENGTH = 68;
    uint256 private constant SWAP_CALL_MIN_LENGTH = 196;

    error ApprovalShapeNotAllowed();
    error InvalidApproval();
    error InvalidApprovalMode();
    error InvalidBatchLength();
    error InvalidExecutionHash();
    error InvalidIntent();
    error InvalidSwap();

    constructor() MetaSwapDelegationManagerBase(NAME) { }

    /**
     * @notice Decodes exact-calldata terms.
     * @param terms_ Packed as `intent(1) | executionHash(32)`.
     */
    function getExactTermsInfo(bytes memory terms_) public pure returns (bytes32 executionHash_) {
        if (terms_.length != EXACT_TERMS_LENGTH || uint8(terms_[0]) != uint8(Intent.ExactCalldata)) {
            revert InvalidTerms();
        }
        assembly ("memory-safe") {
            executionHash_ := mload(add(terms_, 33))
        }
    }

    /**
     * @notice Decodes flexible settlement terms.
     * @param terms_ Packed as `intent(1) | settlement fields(145)`.
     */
    function getFlexibleTermsInfo(bytes memory terms_) public pure returns (FlexibleTerms memory termsInfo_) {
        if (terms_.length != FLEXIBLE_TERMS_LENGTH || uint8(terms_[0]) != uint8(Intent.FlexibleSettlement)) {
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
    }

    function _executeIntent(address delegator_, bytes memory terms_, bytes calldata executionContext_) internal override {
        if (terms_.length == 0) revert InvalidTerms();

        uint8 intent_ = uint8(terms_[0]);
        if (intent_ == uint8(Intent.ExactCalldata)) {
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
        Execution[] calldata executions_ = executionContext_.decodeBatch();
        _validateExecutions(executions_, termsInfo_);

        uint256 balanceBefore_ = _balanceOf(termsInfo_.tokenOut, termsInfo_.recipient);
        IDeleGatorCore(delegator_).executeFromExecutor(SIMPLE_BATCH_MODE, executionContext_);
        uint256 balanceAfter_ = _balanceOf(termsInfo_.tokenOut, termsInfo_.recipient);

        if (balanceAfter_ < balanceBefore_ || balanceAfter_ - balanceBefore_ < termsInfo_.tokenOutMin) {
            revert InsufficientOutput();
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
