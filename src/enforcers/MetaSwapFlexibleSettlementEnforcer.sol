// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { BitMaps } from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { IMetaSwap } from "../helpers/interfaces/IMetaSwap.sol";
import { Execution, ModeCode } from "../utils/Types.sol";

/**
 * @title MetaSwapFlexibleSettlementEnforcer
 * @notice One MetaSwap router settlement (native/ERC-20, optional approval) with a minimum output.
 * @dev Single caveat combining:
 *      - MetaSwap batch shape validation (swap ± approve / reset-approve)
 *      - ERC20 / native min balance increase (`tokenOut == address(0)` → native)
 *      - Redeemer allowlist (required)
 *      - Timestamp window (optional: `0` disables a bound)
 *      - Id bitmap (optional: `id == 0` → per-delegation-hash one-shot instead)
 *
 * Shapes:
 *      - Native: `[swap{ value: tokenInAmount }(...)]`
 *      - ERC-20 skip approval: `[swap(...)]`
 *      - ERC-20 approve: `[approve(metaSwap, tokenInAmount), swap(...)]`
 *      - ERC-20 reset: `[approve(metaSwap, 0), approve(metaSwap, tokenInAmount), swap(...)]`
 *
 * `aggregatorId` / route `data` stay unrestricted — trust MetaSwap and its adapters.
 */
contract MetaSwapFlexibleSettlementEnforcer is CaveatEnforcer {
    using BitMaps for BitMaps.BitMap;
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
        uint128 timestampAfter;
        uint128 timestampBefore;
        uint256 id;
        address[] redeemers;
    }

    /// @dev Settlement (145) + timestampAfter (16) + timestampBefore (16) + id (32).
    uint256 private constant FIXED_TERMS_LENGTH = 209;
    uint256 private constant APPROVE_CALL_LENGTH = 68;
    // Selector + four-word head + two dynamic length words.
    uint256 private constant SWAP_CALL_MIN_LENGTH = 196;

    /// @notice Used when `id == 0` (hash-based one-shot).
    mapping(bytes32 settlementKey => bool isUsed) public consumedSettlements;

    /// @dev Used when `id != 0` (IdEnforcer-style bitmap).
    mapping(address delegationManager => mapping(address delegator => BitMaps.BitMap id)) private isUsedId;

    /// @dev Recipient output balance between before/after hooks.
    mapping(bytes32 settlementKey => uint256 balanceBefore) private balanceSnapshots;

    event SettlementConsumed(
        address indexed delegationManager, bytes32 indexed delegationHash, address indexed redeemer, uint256 id
    );

    event UsedId(address indexed sender, address indexed delegator, address indexed redeemer, uint256 id);

    function getSettlementKey(address delegationManager_, bytes32 delegationHash_) external pure returns (bytes32) {
        return _getSettlementKey(delegationManager_, delegationHash_);
    }

    function getIsUsed(address delegationManager_, address delegator_, uint256 id_) external view returns (bool) {
        return isUsedId[delegationManager_][delegator_].get(id_);
    }

    /**
     * @notice Validates policies and batch shape, locks one-shot state, and snapshots output balance.
     */
    function beforeHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32 delegationHash_,
        address delegator_,
        address redeemer_
    )
        public
        override
        onlyBatchCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        Terms memory termsInfo_ = getTermsInfo(terms_);
        _validateRedeemer(termsInfo_.redeemers, redeemer_);
        _validateTimestamp(termsInfo_.timestampAfter, termsInfo_.timestampBefore);
        _validateExecutions(executionCallData_.decodeBatch(), termsInfo_);
        _consume(termsInfo_.id, delegationHash_, delegator_, redeemer_);

        balanceSnapshots[_getSettlementKey(msg.sender, delegationHash_)] = _balanceOf(termsInfo_.tokenOut, termsInfo_.recipient);
    }

    /**
     * @notice Requires the recipient's output balance to have increased by at least `tokenOutMin`.
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
        _requireValidTermsLength(terms_.length);

        bytes32 settlementKey_ = _getSettlementKey(msg.sender, delegationHash_);
        address tokenOut_ = address(bytes20(terms_[73:93]));
        address recipient_ = address(bytes20(terms_[93:113]));
        uint256 tokenOutMin_ = uint256(bytes32(terms_[113:145]));
        uint256 id_ = uint256(bytes32(terms_[177:209]));
        uint256 balanceBefore_ = balanceSnapshots[settlementKey_];
        delete balanceSnapshots[settlementKey_];

        uint256 balanceAfter_ = _balanceOf(tokenOut_, recipient_);
        require(
            balanceAfter_ >= balanceBefore_ && balanceAfter_ - balanceBefore_ >= tokenOutMin_,
            "MetaSwapFlexibleSettlementEnforcer:insufficient-output"
        );

        emit SettlementConsumed(msg.sender, delegationHash_, redeemer_, id_);
    }

    /**
     * @notice Decodes packed terms:
     * `metaSwap(20) | tokenIn(20) | tokenInAmount(32) | approvalMode(1) | tokenOut(20) | recipient(20) |
     *  tokenOutMin(32) | timestampAfter(16) | timestampBefore(16) | id(32) | redeemers(20*N)`.
     */
    function getTermsInfo(bytes calldata terms_) public pure returns (Terms memory termsInfo_) {
        _requireValidTermsLength(terms_.length);

        termsInfo_.metaSwap = address(bytes20(terms_[0:20]));
        termsInfo_.tokenIn = address(bytes20(terms_[20:40]));
        termsInfo_.tokenInAmount = uint256(bytes32(terms_[40:72]));
        uint8 approvalMode_ = uint8(terms_[72]);
        termsInfo_.tokenOut = address(bytes20(terms_[73:93]));
        termsInfo_.recipient = address(bytes20(terms_[93:113]));
        termsInfo_.tokenOutMin = uint256(bytes32(terms_[113:145]));
        termsInfo_.timestampAfter = uint128(bytes16(terms_[145:161]));
        termsInfo_.timestampBefore = uint128(bytes16(terms_[161:177]));
        termsInfo_.id = uint256(bytes32(terms_[177:209]));

        require(
            termsInfo_.metaSwap != address(0) && termsInfo_.tokenInAmount != 0 && termsInfo_.recipient != address(0)
                && termsInfo_.tokenOutMin != 0 && termsInfo_.tokenIn != termsInfo_.tokenOut,
            "MetaSwapFlexibleSettlementEnforcer:invalid-terms"
        );

        // Native input requires None; ERC-20 input requires a non-None mode.
        if (termsInfo_.tokenIn == address(0)) {
            require(approvalMode_ == uint8(ApprovalMode.None), "MetaSwapFlexibleSettlementEnforcer:invalid-approval-mode");
        } else {
            require(
                approvalMode_ > uint8(ApprovalMode.None) && approvalMode_ <= uint8(ApprovalMode.ResetApprove),
                "MetaSwapFlexibleSettlementEnforcer:invalid-approval-mode"
            );
        }
        termsInfo_.approvalMode = ApprovalMode(approvalMode_);

        uint256 redeemerCount_ = (terms_.length - FIXED_TERMS_LENGTH) / 20;
        termsInfo_.redeemers = new address[](redeemerCount_);
        for (uint256 i_; i_ < redeemerCount_; ++i_) {
            uint256 offset_ = FIXED_TERMS_LENGTH + (i_ * 20);
            termsInfo_.redeemers[i_] = address(bytes20(terms_[offset_:offset_ + 20]));
        }
    }

    function _requireValidTermsLength(uint256 length_) private pure {
        require(length_ >= FIXED_TERMS_LENGTH + 20, "MetaSwapFlexibleSettlementEnforcer:invalid-terms");
        require((length_ - FIXED_TERMS_LENGTH) % 20 == 0, "MetaSwapFlexibleSettlementEnforcer:invalid-terms");
    }

    function _validateRedeemer(address[] memory redeemers_, address redeemer_) private pure {
        uint256 length_ = redeemers_.length;
        for (uint256 i_; i_ < length_; ++i_) {
            if (redeemer_ == redeemers_[i_]) return;
        }
        revert("MetaSwapFlexibleSettlementEnforcer:unauthorized-redeemer");
    }

    function _validateTimestamp(uint128 timestampAfter_, uint128 timestampBefore_) private view {
        if (timestampAfter_ > 0) {
            require(block.timestamp > timestampAfter_, "MetaSwapFlexibleSettlementEnforcer:early-delegation");
        }
        if (timestampBefore_ > 0) {
            require(block.timestamp < timestampBefore_, "MetaSwapFlexibleSettlementEnforcer:expired-delegation");
        }
    }

    /**
     * @dev `id == 0`: one-shot keyed by `(manager, delegationHash)`.
     *      `id != 0`: one-shot + mutual exclusion keyed by `(manager, delegator, id)`.
     *      Hash consumption is skipped in the id path — replaying the same delegation reuses the same id,
     *      so the bitmap already blocks it; the id also blocks other hashes that share that order id.
     */
    function _consume(uint256 id_, bytes32 delegationHash_, address delegator_, address redeemer_) private {
        if (id_ == 0) {
            bytes32 settlementKey_ = _getSettlementKey(msg.sender, delegationHash_);
            require(!consumedSettlements[settlementKey_], "MetaSwapFlexibleSettlementEnforcer:settlement-already-used");
            consumedSettlements[settlementKey_] = true;
            return;
        }

        require(!isUsedId[msg.sender][delegator_].get(id_), "MetaSwapFlexibleSettlementEnforcer:id-already-used");
        isUsedId[msg.sender][delegator_].set(id_);
        emit UsedId(msg.sender, delegator_, redeemer_, id_);
    }

    function _validateExecutions(Execution[] calldata executions_, Terms memory termsInfo_) private pure {
        if (termsInfo_.tokenIn == address(0)) {
            require(executions_.length == 1, "MetaSwapFlexibleSettlementEnforcer:invalid-batch-length");
            _validateSwap(executions_[0], termsInfo_.metaSwap, address(0), termsInfo_.tokenInAmount, termsInfo_.tokenInAmount);
            return;
        }

        ApprovalMode approvalMode_ = termsInfo_.approvalMode;
        if (approvalMode_ == ApprovalMode.SkipApproval) {
            require(executions_.length == 1, "MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
            _validateSwap(executions_[0], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        } else if (approvalMode_ == ApprovalMode.Approve) {
            require(executions_.length == 2, "MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            _validateSwap(executions_[1], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        } else {
            // ResetApprove — only remaining ERC-20 mode after getTermsInfo.
            require(executions_.length == 3, "MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, 0);
            _validateApproval(executions_[1], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            _validateSwap(executions_[2], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
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
