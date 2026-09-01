// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { IMetaSwap } from "../helpers/interfaces/IMetaSwap.sol";
import { Execution, ModeCode } from "../utils/Types.sol";

/**
 * @title MetaSwapOneShotLimitOrderEnforcer
 * @notice Authorizes one MetaSwap order with an exact input and a minimum recipient balance increase.
 * @dev The enforcer combines batch validation, one-shot consumption, and output enforcement. It accepts:
 *      - Native: `[swap{ value: tokenInAmount }(...)]`
 *      - ERC-20 without approval: `[swap(...)]`
 *      - ERC-20 with approval: `[approve(metaSwap, tokenInAmount), swap(...)]`
 *      - ERC-20 with reset: `[approve(metaSwap, 0), approve(metaSwap, tokenInAmount), swap(...)]`
 *
 * The signed approval policy selects which ERC-20 shapes are allowed. MetaSwap's dynamic `aggregatorId` and route `data`
 * remain unrestricted. The configured MetaSwap contract and its adapters must therefore be trusted.
 */
contract MetaSwapOneShotLimitOrderEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    struct Terms {
        address metaSwap;
        address tokenIn;
        uint256 tokenInAmount;
        uint8 approvalPolicy;
        address tokenOut;
        address recipient;
        uint256 tokenOutMin;
    }

    /// @notice Allows an ERC-20 swap to use an existing allowance.
    uint8 public constant ALLOW_SKIP_APPROVAL = 1;

    /// @notice Allows `approve(tokenInAmount)` before the swap.
    uint8 public constant ALLOW_APPROVAL = 2;

    /// @notice Allows `approve(0)` followed by `approve(tokenInAmount)` before the swap.
    uint8 public constant ALLOW_RESET_APPROVAL = 4;

    uint8 private constant ALL_APPROVAL_MODES = ALLOW_SKIP_APPROVAL | ALLOW_APPROVAL | ALLOW_RESET_APPROVAL;
    uint256 private constant TERMS_LENGTH = 145;
    uint256 private constant APPROVE_CALL_LENGTH = 68;
    uint256 private constant SWAP_CALL_MIN_LENGTH = 132;
    uint256 private constant CONSUMED = type(uint256).max;
    uint256 private constant MAX_CACHEABLE_BALANCE = CONSUMED - 1;

    /**
     * @dev One slot represents the complete lifecycle:
     *      - `0`: unused
     *      - `balanceBefore + 1`: executing and balance cached
     *      - `type(uint256).max`: consumed
     */
    mapping(bytes32 orderKey => uint256 state) public orderStates;

    /**
     * @notice Emitted after an order satisfies its minimum output and is permanently consumed.
     * @param delegationManager DelegationManager that redeemed the order.
     * @param delegationHash Hash identifying the signed delegation.
     * @param redeemer Address that submitted the redemption.
     */
    event OrderConsumed(address indexed delegationManager, bytes32 indexed delegationHash, address indexed redeemer);

    /**
     * @notice Returns the storage key used to isolate an order.
     * @param delegationManager_ DelegationManager that redeems the delegation.
     * @param delegationHash_ Hash identifying the delegation.
     */
    function getOrderKey(address delegationManager_, bytes32 delegationHash_) external pure returns (bytes32) {
        return _getOrderKey(delegationManager_, delegationHash_);
    }

    /**
     * @notice Validates the batch, caches the output balance, and locks the order against reuse.
     * @param terms_ Packed order constraints.
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

        bytes32 orderKey_ = _getOrderKey(msg.sender, delegationHash_);
        require(orderStates[orderKey_] == 0, "MetaSwapOneShotLimitOrderEnforcer:order-already-used");

        uint256 balanceBefore_ = _balanceOf(termsInfo_.tokenOut, termsInfo_.recipient);
        require(balanceBefore_ < MAX_CACHEABLE_BALANCE, "MetaSwapOneShotLimitOrderEnforcer:balance-overflow");
        orderStates[orderKey_] = balanceBefore_ + 1;
    }

    /**
     * @notice Enforces the minimum output and permanently consumes the successful order.
     * @param terms_ Packed order constraints.
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
        require(terms_.length == TERMS_LENGTH, "MetaSwapOneShotLimitOrderEnforcer:invalid-terms");

        bytes32 orderKey_ = _getOrderKey(msg.sender, delegationHash_);
        uint256 cachedState_ = orderStates[orderKey_];
        require(cachedState_ != 0 && cachedState_ != CONSUMED, "MetaSwapOneShotLimitOrderEnforcer:order-not-executing");

        address tokenOut_ = address(bytes20(terms_[73:93]));
        address recipient_ = address(bytes20(terms_[93:113]));
        uint256 tokenOutMin_ = uint256(bytes32(terms_[113:145]));
        uint256 balanceBefore_ = cachedState_ - 1;
        uint256 balanceAfter_ = _balanceOf(tokenOut_, recipient_);

        require(
            balanceAfter_ >= balanceBefore_ && balanceAfter_ - balanceBefore_ >= tokenOutMin_,
            "MetaSwapOneShotLimitOrderEnforcer:insufficient-output"
        );

        orderStates[orderKey_] = CONSUMED;
        emit OrderConsumed(msg.sender, delegationHash_, redeemer_);
    }

    /**
     * @notice Decodes and validates signed order terms.
     * @param terms_ Packed as
     * `metaSwap(20) | tokenIn(20) | tokenInAmount(32) | approvalPolicy(1) | tokenOut(20) | recipient(20) | tokenOutMin(32)`.
     */
    function getTermsInfo(bytes calldata terms_) public pure returns (Terms memory termsInfo_) {
        require(terms_.length == TERMS_LENGTH, "MetaSwapOneShotLimitOrderEnforcer:invalid-terms");

        termsInfo_.metaSwap = address(bytes20(terms_[0:20]));
        termsInfo_.tokenIn = address(bytes20(terms_[20:40]));
        termsInfo_.tokenInAmount = uint256(bytes32(terms_[40:72]));
        termsInfo_.approvalPolicy = uint8(terms_[72]);
        termsInfo_.tokenOut = address(bytes20(terms_[73:93]));
        termsInfo_.recipient = address(bytes20(terms_[93:113]));
        termsInfo_.tokenOutMin = uint256(bytes32(terms_[113:145]));

        require(
            termsInfo_.metaSwap != address(0) && termsInfo_.tokenInAmount != 0 && termsInfo_.recipient != address(0)
                && termsInfo_.tokenOutMin != 0 && termsInfo_.tokenIn != termsInfo_.tokenOut,
            "MetaSwapOneShotLimitOrderEnforcer:invalid-terms"
        );

        if (termsInfo_.tokenIn == address(0)) {
            require(termsInfo_.approvalPolicy == 0, "MetaSwapOneShotLimitOrderEnforcer:invalid-approval-policy");
        } else {
            require(
                termsInfo_.approvalPolicy != 0 && termsInfo_.approvalPolicy <= ALL_APPROVAL_MODES,
                "MetaSwapOneShotLimitOrderEnforcer:invalid-approval-policy"
            );
        }
    }

    function _validateExecutions(Execution[] calldata executions_, Terms memory termsInfo_) private pure {
        if (termsInfo_.tokenIn == address(0)) {
            require(executions_.length == 1, "MetaSwapOneShotLimitOrderEnforcer:invalid-batch-length");
            _validateSwap(executions_[0], termsInfo_.metaSwap, address(0), termsInfo_.tokenInAmount, termsInfo_.tokenInAmount);
            return;
        }

        uint256 swapIndex_ = 0;
        if (executions_.length == 1) {
            require(
                (termsInfo_.approvalPolicy & ALLOW_SKIP_APPROVAL) != 0,
                "MetaSwapOneShotLimitOrderEnforcer:approval-shape-not-allowed"
            );
        } else if (executions_.length == 2) {
            require(
                (termsInfo_.approvalPolicy & ALLOW_APPROVAL) != 0, "MetaSwapOneShotLimitOrderEnforcer:approval-shape-not-allowed"
            );
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            swapIndex_ = 1;
        } else {
            require(
                executions_.length == 3 && (termsInfo_.approvalPolicy & ALLOW_RESET_APPROVAL) != 0,
                "MetaSwapOneShotLimitOrderEnforcer:approval-shape-not-allowed"
            );
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, 0);
            _validateApproval(executions_[1], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            swapIndex_ = 2;
        }

        _validateSwap(executions_[swapIndex_], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
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
                || address(uint160(uint256(bytes32(callData_[4:36])))) != metaSwap_
                || uint256(bytes32(callData_[36:68])) != expectedAmount_
        ) {
            revert("MetaSwapOneShotLimitOrderEnforcer:invalid-approval");
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
                || address(uint160(uint256(bytes32(callData_[36:68])))) != tokenIn_
                || uint256(bytes32(callData_[68:100])) != tokenInAmount_
        ) {
            revert("MetaSwapOneShotLimitOrderEnforcer:invalid-swap");
        }
    }

    function _balanceOf(address token_, address recipient_) private view returns (uint256) {
        return token_ == address(0) ? recipient_.balance : IERC20(token_).balanceOf(recipient_);
    }

    function _getOrderKey(address delegationManager_, bytes32 delegationHash_) private pure returns (bytes32) {
        return keccak256(abi.encode(delegationManager_, delegationHash_));
    }
}
