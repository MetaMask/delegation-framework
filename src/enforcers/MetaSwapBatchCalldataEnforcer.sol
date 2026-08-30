// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { IMetaSwap } from "../helpers/interfaces/IMetaSwap.sol";
import { Execution, ModeCode } from "../utils/Types.sol";

/**
 * @title MetaSwapBatchCalldataEnforcer
 * @notice Restricts a direct DelegationManager batch while leaving MetaSwap route selection flexible.
 * @dev Supported signed shapes:
 *      - Native: `[swap{ value: tokenInAmount }(...)]`
 *      - ERC-20: `[approve(metaSwap, tokenInAmount), swap(...)]`
 *      - ERC-20 reset: `[approve(metaSwap, 0), approve(metaSwap, tokenInAmount), swap(...)]`
 *
 * MetaSwap's dynamic `aggregatorId` and route `data` are never copied or decoded. The enforcer reads only the selector,
 * `tokenFrom`, and `amount` words from swap calldata. Output constraints belong in a separate balance-change enforcer.
 */
contract MetaSwapBatchCalldataEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    struct Terms {
        address metaSwap;
        address tokenIn;
        uint256 tokenInAmount;
        bool resetApproval;
    }

    uint256 private constant TERMS_LENGTH = 73;
    uint256 private constant APPROVE_CALL_LENGTH = 68;
    uint256 private constant SWAP_CALL_MIN_LENGTH = 132;

    /**
     * @notice Validates the direct batch shape and all security-relevant static fields.
     * @param terms_ Packed `metaSwap(20) | tokenIn(20) | tokenInAmount(32) | resetApproval(1)`.
     * @param mode_ DelegationManager execution mode; must be batch/default.
     * @param executionCallData_ ABI-encoded `Execution[]`.
     */
    function beforeHook(
        bytes calldata terms_,
        bytes calldata,
        ModeCode mode_,
        bytes calldata executionCallData_,
        bytes32,
        address,
        address
    )
        public
        pure
        override
        onlyBatchCallTypeMode(mode_)
        onlyDefaultExecutionMode(mode_)
    {
        Terms memory termsInfo_ = getTermsInfo(terms_);
        Execution[] calldata executions_ = executionCallData_.decodeBatch();

        if (termsInfo_.tokenIn == address(0)) {
            require(!termsInfo_.resetApproval && executions_.length == 1, "MetaSwapBatchCalldataEnforcer:invalid-batch-length");
            _validateSwap(executions_[0], termsInfo_.metaSwap, address(0), termsInfo_.tokenInAmount, termsInfo_.tokenInAmount);
            return;
        }

        if (termsInfo_.resetApproval) {
            require(executions_.length == 3, "MetaSwapBatchCalldataEnforcer:invalid-batch-length");
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, 0);
            _validateApproval(executions_[1], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            _validateSwap(executions_[2], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        } else {
            require(executions_.length == 2, "MetaSwapBatchCalldataEnforcer:invalid-batch-length");
            _validateApproval(executions_[0], termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            _validateSwap(executions_[1], termsInfo_.metaSwap, termsInfo_.tokenIn, termsInfo_.tokenInAmount, 0);
        }
    }

    /**
     * @notice Decodes the compact signed terms.
     * @param terms_ Packed batch constraints.
     * @return termsInfo_ Decoded MetaSwap, input token, amount, and approval shape.
     */
    function getTermsInfo(bytes calldata terms_) public pure returns (Terms memory termsInfo_) {
        require(terms_.length == TERMS_LENGTH, "MetaSwapBatchCalldataEnforcer:invalid-terms");

        termsInfo_.metaSwap = address(bytes20(terms_[0:20]));
        termsInfo_.tokenIn = address(bytes20(terms_[20:40]));
        termsInfo_.tokenInAmount = uint256(bytes32(terms_[40:72]));
        uint8 resetApprovalValue_ = uint8(terms_[72]);
        require(
            termsInfo_.metaSwap != address(0) && termsInfo_.tokenInAmount != 0 && resetApprovalValue_ <= 1,
            "MetaSwapBatchCalldataEnforcer:invalid-terms"
        );
        termsInfo_.resetApproval = resetApprovalValue_ == 1;
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
            revert("MetaSwapBatchCalldataEnforcer:invalid-approval");
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
            revert("MetaSwapBatchCalldataEnforcer:invalid-swap");
        }
    }
}
