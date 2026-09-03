// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { IMetaSwap } from "../helpers/interfaces/IMetaSwap.sol";
import { Execution, ModeCode } from "../utils/Types.sol";

/**
 * @title MetaSwapFlexibleSettlementEnforcer
 * @notice Authorizes one MetaSwap settlement with a redeemer-selected route, exact input, and minimum output.
 * @dev The settlement combines batch validation, one-shot consumption, and output enforcement. It accepts:
 *      - Native: `[swap{ value: tokenInAmount }(...)]`
 *      - ERC-20 without approval: `[swap(...)]`
 *      - ERC-20 with approval: `[approve(metaSwap, tokenInAmount), swap(...)]`
 *      - ERC-20 with reset: `[approve(metaSwap, 0), approve(metaSwap, tokenInAmount), swap(...)]`
 *
 * The signed approval mode selects one exact ERC-20 shape. MetaSwap's dynamic `aggregatorId` and route `data`
 * remain unrestricted. The configured MetaSwap contract and its adapters must therefore be trusted.
 */
contract MetaSwapFlexibleSettlementEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

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

    uint256 private constant TERMS_LENGTH = 145;
    uint256 private constant APPROVE_CALL_LENGTH = 68;
    // Selector + four-word head + two dynamic length words.
    uint256 private constant SWAP_CALL_MIN_LENGTH = 196;

    /// @notice Records settlements that have already been used.
    mapping(bytes32 settlementKey => bool isUsed) public consumedSettlements;

    /// @dev Caches the recipient's balance between the DelegationManager's before and after hooks.
    mapping(bytes32 settlementKey => uint256 balanceBefore) private balanceSnapshots;

    /**
     * @notice Emitted after a settlement satisfies its minimum output and is permanently consumed.
     * @param delegationManager DelegationManager that redeemed the settlement.
     * @param delegationHash Hash identifying the signed delegation.
     * @param redeemer Address that submitted the redemption.
     */
    event SettlementConsumed(address indexed delegationManager, bytes32 indexed delegationHash, address indexed redeemer);

    /**
     * @notice Returns the storage key used to isolate a settlement.
     * @param delegationManager_ DelegationManager that redeems the delegation.
     * @param delegationHash_ Hash identifying the delegation.
     */
    function getSettlementKey(address delegationManager_, bytes32 delegationHash_) external pure returns (bytes32) {
        return _getSettlementKey(delegationManager_, delegationHash_);
    }

    /**
     * @notice Validates the batch, caches the output balance, and locks the settlement against reuse.
     * @param terms_ Packed settlement constraints.
     * @param mode_ Execution mode; must be batch/default.
     * @param executionCallData_ ABI-encoded `Execution[]`.
     * @param delegationHash_ Hash identifying the signed delegation.
     */
    function beforeHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32 delegationHash_,
        address,
        address
    )
        public
        override
        onlyBatchCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        Terms memory termsInfo_ = getTermsInfo(terms_);
        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        _validateExecutions(executions_, termsInfo_);

        bytes32 settlementKey_ = _getSettlementKey(msg.sender, delegationHash_);
        require(!consumedSettlements[settlementKey_], "MetaSwapFlexibleSettlementEnforcer:settlement-already-used");

        consumedSettlements[settlementKey_] = true;
        balanceSnapshots[settlementKey_] = _balanceOf(termsInfo_.tokenOut, termsInfo_.recipient);
    }

    /**
     * @notice Enforces the minimum output and permanently consumes the successful settlement.
     * @param terms_ Packed settlement constraints.
     * @param delegationHash_ Hash identifying the signed delegation.
     * @param redeemer_ Address that submitted the redemption.
     */
    function afterHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32 delegationHash_,
        address,
        address redeemer_
    )
        public
        override
    {
        require(terms_.length == TERMS_LENGTH, "MetaSwapFlexibleSettlementEnforcer:invalid-terms");

        bytes32 settlementKey_ = _getSettlementKey(msg.sender, delegationHash_);
        address tokenOut_ = address(bytes20(terms_[73:93]));
        address recipient_ = address(bytes20(terms_[93:113]));
        uint256 tokenOutMin_ = uint256(bytes32(terms_[113:145]));
        uint256 balanceBefore_ = balanceSnapshots[settlementKey_];
        delete balanceSnapshots[settlementKey_];

        uint256 balanceAfter_ = _balanceOf(tokenOut_, recipient_);

        require(
            balanceAfter_ >= balanceBefore_ && balanceAfter_ - balanceBefore_ >= tokenOutMin_,
            "MetaSwapFlexibleSettlementEnforcer:insufficient-output"
        );

        emit SettlementConsumed(msg.sender, delegationHash_, redeemer_);
    }

    /**
     * @notice Decodes and validates signed settlement terms.
     * @param terms_ Packed as
     * `metaSwap(20) | tokenIn(20) | tokenInAmount(32) | approvalMode(1) | tokenOut(20) | recipient(20) | tokenOutMin(32)`.
     */
    function getTermsInfo(bytes calldata terms_) public pure returns (Terms memory termsInfo_) {
        require(terms_.length == TERMS_LENGTH, "MetaSwapFlexibleSettlementEnforcer:invalid-terms");

        termsInfo_.metaSwap = address(bytes20(terms_[0:20]));
        termsInfo_.tokenIn = address(bytes20(terms_[20:40]));
        termsInfo_.tokenInAmount = uint256(bytes32(terms_[40:72]));
        uint8 approvalMode_ = uint8(terms_[72]);
        termsInfo_.tokenOut = address(bytes20(terms_[73:93]));
        termsInfo_.recipient = address(bytes20(terms_[93:113]));
        termsInfo_.tokenOutMin = uint256(bytes32(terms_[113:145]));

        require(
            termsInfo_.metaSwap != address(0) && termsInfo_.tokenInAmount != 0 && termsInfo_.recipient != address(0)
                && termsInfo_.tokenOutMin != 0 && termsInfo_.tokenIn != termsInfo_.tokenOut,
            "MetaSwapFlexibleSettlementEnforcer:invalid-terms"
        );

        require(approvalMode_ <= uint8(ApprovalMode.ResetApprove), "MetaSwapFlexibleSettlementEnforcer:invalid-approval-mode");
        termsInfo_.approvalMode = ApprovalMode(approvalMode_);
    }

    function _validateExecutions(Execution[] calldata executions_, Terms memory termsInfo_) private pure {
        ApprovalMode approvalMode_ = termsInfo_.approvalMode;

        if (termsInfo_.tokenIn == address(0)) {
            require(approvalMode_ == ApprovalMode.None, "MetaSwapFlexibleSettlementEnforcer:invalid-approval-mode");
            require(executions_.length == 1, "MetaSwapFlexibleSettlementEnforcer:invalid-batch-length");
            _validateSwap(executions_[0], termsInfo_.metaSwap, address(0), termsInfo_.tokenInAmount, termsInfo_.tokenInAmount);
            return;
        }

        if (approvalMode_ == ApprovalMode.SkipApproval) {
            require(executions_.length == 1, "MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
            _validateSwap(executions_[0], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        } else if (approvalMode_ == ApprovalMode.Approve) {
            require(executions_.length == 2, "MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            _validateSwap(executions_[1], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        } else if (approvalMode_ == ApprovalMode.ResetApprove) {
            require(executions_.length == 3, "MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, 0);
            _validateApproval(executions_[1], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            _validateSwap(executions_[2], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        } else {
            revert("MetaSwapFlexibleSettlementEnforcer:invalid-approval-mode");
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
            revert("MetaSwapFlexibleSettlementEnforcer:invalid-approval");
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
            revert("MetaSwapFlexibleSettlementEnforcer:invalid-swap");
        }
    }

    function _balanceOf(address token_, address recipient_) private view returns (uint256) {
        return token_ == address(0) ? recipient_.balance : IERC20(token_).balanceOf(recipient_);
    }

    function _getSettlementKey(address delegationManager_, bytes32 delegationHash_) private pure returns (bytes32) {
        return keccak256(abi.encode(delegationManager_, delegationHash_));
    }
}
