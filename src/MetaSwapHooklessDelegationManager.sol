// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { MetaSwapDelegationManagerBase } from "./MetaSwapDelegationManagerBase.sol";
import { IMetaSwap } from "./helpers/interfaces/IMetaSwap.sol";
import { IDeleGatorCore } from "./interfaces/IDeleGatorCore.sol";
import { Execution } from "./utils/Types.sol";

/**
 * @title MetaSwapHooklessDelegationManager
 * @notice Executes one signed MetaSwap settlement without invoking external caveat hooks.
 * @dev The redeemer supplies a complete batch, which is validated directly by this manager.
 */
contract MetaSwapHooklessDelegationManager is MetaSwapDelegationManagerBase {
    using ExecutionLib for bytes;

    string public constant NAME = "MetaSwapHooklessDelegationManager";

    uint256 private constant APPROVE_CALL_LENGTH = 68;
    uint256 private constant SWAP_CALL_MIN_LENGTH = 196;

    error ApprovalShapeNotAllowed();
    error InvalidApproval();
    error InvalidBatchLength();
    error InvalidSwap();

    constructor(SignatureMode signatureMode_) MetaSwapDelegationManagerBase(NAME, signatureMode_) { }

    function _executeSettlement(address delegator_, bytes calldata executionContext_, Terms memory termsInfo_) internal override {
        Execution[] calldata executions_ = executionContext_.decodeBatch();
        _validateExecutions(executions_, termsInfo_);

        IDeleGatorCore(delegator_).executeFromExecutor(ModeLib.encodeSimpleBatch(), executionContext_);
    }

    function _validateExecutions(Execution[] calldata executions_, Terms memory termsInfo_) private pure {
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
