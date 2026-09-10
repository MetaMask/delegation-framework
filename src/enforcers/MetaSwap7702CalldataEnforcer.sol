// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { IMetaSwap } from "../helpers/interfaces/IMetaSwap.sol";
import { IERC7821 } from "../interfaces/IERC7821.sol";
import { Execution, ModeCode } from "../utils/Types.sol";

/**
 * @title MetaSwap7702CalldataEnforcer
 * @notice Validates a direct MetaSwap limit-order call nested inside one EIP-7702 self-call batch.
 * @dev The DelegationManager sees one single execution targeting the delegator:
 *      `delegator.execute(BATCH_DEFAULT_MODE, innerExecutions)`.
 *
 *      ERC-20 input supports one of two signed shapes:
 *      - `[approve(metaSwap, tokenInAmount), swap(...)]`
 *      - `[approve(metaSwap, 0), approve(metaSwap, tokenInAmount), swap(...)]`
 *
 *      Native input requires `[swap{ value: tokenInAmount }(...)]`.
 *
 * @dev MetaSwap's aggregator ID and dynamic route bytes remain completely flexible. The enforcer reads only the static
 *      `tokenFrom` and `amount` ABI words, avoiding allocation or decoding of either dynamic argument. Output token and
 *      minimum output are intentionally enforced by a separate NativeBalanceChangeEnforcer or ERC20BalanceChangeEnforcer.
 *      Address zero represents native input.
 */
contract MetaSwap7702CalldataEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    struct Terms {
        address metaSwap;
        address tokenIn;
        uint256 tokenInAmount;
        bool resetApproval;
    }

    uint256 private constant TERMS_LENGTH = 73;
    uint256 private constant OUTER_CALL_MIN_LENGTH = 100;
    uint256 private constant OUTER_DYNAMIC_OFFSET = 64;
    uint256 private constant APPROVE_CALL_LENGTH = 68;
    uint256 private constant SWAP_CALL_MIN_LENGTH = 132;

    /**
     * @notice Validates the fixed security fields while leaving MetaSwap route selection flexible.
     * @param terms_ Packed as `metaSwap(20) | tokenIn(20) | tokenInAmount(32) | resetApproval(1)`.
     * @param mode_ DelegationManager execution mode; must be single/default.
     * @param executionCallData_ Packed outer single execution targeting the delegator's 7702 account.
     * @param delegator_ Root 7702 account that must be the outer execution target.
     */
    function beforeHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32,
        address delegator_,
        address
    )
        public
        pure
        override
        onlySingleCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        Terms memory termsInfo_ = getTermsInfo(terms_);
        (address outerTarget_, uint256 outerValue_, bytes calldata outerCallData_) = executionCallData_.decodeSingle();

        require(outerTarget_ == delegator_ && outerValue_ == 0, "MetaSwap7702CalldataEnforcer:invalid-outer-execution");

        bytes calldata innerExecutionCallData_ = _decodeOuterExecute(outerCallData_);
        Execution[] calldata executions_ = innerExecutionCallData_.decodeBatch();

        if (termsInfo_.tokenIn == address(0)) {
            require(!termsInfo_.resetApproval && executions_.length == 1, "MetaSwap7702CalldataEnforcer:invalid-batch-length");
            _validateSwap(
                executions_[0], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, termsInfo_.tokenInAmount
            );
            return;
        }

        if (termsInfo_.resetApproval) {
            require(executions_.length == 3, "MetaSwap7702CalldataEnforcer:invalid-batch-length");
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, 0);
            _validateApproval(executions_[1], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            _validateSwap(executions_[2], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        } else {
            require(executions_.length == 2, "MetaSwap7702CalldataEnforcer:invalid-batch-length");
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            _validateSwap(executions_[1], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        }
    }

    /**
     * @notice Decodes the packed signed terms.
     * @return termsInfo_ Decoded MetaSwap, input token, input amount, and approval shape.
     */
    function getTermsInfo(bytes calldata terms_) public pure returns (Terms memory termsInfo_) {
        require(terms_.length == TERMS_LENGTH, "MetaSwap7702CalldataEnforcer:invalid-terms");

        termsInfo_.metaSwap = address(bytes20(terms_[0:20]));
        termsInfo_.tokenIn = address(bytes20(terms_[20:40]));
        termsInfo_.tokenInAmount = uint256(bytes32(terms_[40:72]));
        uint8 resetApprovalValue_ = uint8(terms_[72]);

        require(
            termsInfo_.metaSwap != address(0) && termsInfo_.tokenInAmount != 0 && resetApprovalValue_ <= 1,
            "MetaSwap7702CalldataEnforcer:invalid-terms"
        );
        termsInfo_.resetApproval = resetApprovalValue_ == 1;
    }

    function _decodeOuterExecute(bytes calldata callData_) private pure returns (bytes calldata innerExecutionCallData_) {
        if (callData_.length < OUTER_CALL_MIN_LENGTH || bytes4(callData_[0:4]) != IERC7821.execute.selector) {
            revert("MetaSwap7702CalldataEnforcer:invalid-outer-execution");
        }
        if (ModeCode.unwrap(ModeCode.wrap(bytes32(callData_[4:36]))) != ModeCode.unwrap(ModeLib.encodeSimpleBatch())) {
            revert("MetaSwap7702CalldataEnforcer:invalid-inner-mode");
        }
        require(uint256(bytes32(callData_[36:68])) == OUTER_DYNAMIC_OFFSET, "MetaSwap7702CalldataEnforcer:invalid-inner-encoding");

        uint256 innerLength_ = uint256(bytes32(callData_[68:100]));
        require(innerLength_ <= callData_.length - OUTER_CALL_MIN_LENGTH, "MetaSwap7702CalldataEnforcer:invalid-inner-encoding");

        uint256 paddedInnerLength_ = (innerLength_ + 31) & ~uint256(31);
        require(
            callData_.length == OUTER_CALL_MIN_LENGTH + paddedInnerLength_, "MetaSwap7702CalldataEnforcer:invalid-inner-encoding"
        );

        innerExecutionCallData_ = callData_[OUTER_CALL_MIN_LENGTH:OUTER_CALL_MIN_LENGTH + innerLength_];
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
        if (
            execution_.target != tokenIn_ || execution_.value != 0 || execution_.callData.length != APPROVE_CALL_LENGTH
                || bytes4(execution_.callData[0:4]) != IERC20.approve.selector
                || address(uint160(uint256(bytes32(execution_.callData[4:36])))) != metaSwap_
                || uint256(bytes32(execution_.callData[36:68])) != expectedAmount_
        ) {
            revert("MetaSwap7702CalldataEnforcer:invalid-approval");
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
        if (
            execution_.target != metaSwap_ || execution_.value != expectedValue_
                || execution_.callData.length < SWAP_CALL_MIN_LENGTH || bytes4(execution_.callData[0:4]) != IMetaSwap.swap.selector
                || address(uint160(uint256(bytes32(execution_.callData[36:68])))) != tokenIn_
                || uint256(bytes32(execution_.callData[68:100])) != tokenInAmount_
        ) {
            revert("MetaSwap7702CalldataEnforcer:invalid-swap");
        }
    }
}
