// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { MetaSwapFlexibleSettlementManagerBase } from "./MetaSwapFlexibleSettlementManagerBase.sol";
import { IMetaSwap } from "./helpers/interfaces/IMetaSwap.sol";
import { IDeleGatorCore } from "./interfaces/IDeleGatorCore.sol";
import { Execution } from "./utils/Types.sol";

/**
 * @title MetaSwapExecutionBuilderDelegationManager
 * @notice Constructs and executes one signed MetaSwap settlement from redeemer-supplied route data.
 * @dev Approval and swap targets, amounts, ordering, selectors, and values are created by this manager.
 */
contract MetaSwapExecutionBuilderDelegationManager is MetaSwapFlexibleSettlementManagerBase {
    using ExecutionLib for Execution[];

    string public constant NAME = "MetaSwapExecutionBuilderDelegationManager";

    constructor(SignatureMode signatureMode_) MetaSwapFlexibleSettlementManagerBase(NAME, signatureMode_) { }

    function _executeSettlement(address delegator_, bytes calldata executionContext_, Terms memory termsInfo_) internal override {
        (string memory aggregatorId_, bytes memory routeData_) = abi.decode(executionContext_, (string, bytes));
        Execution[] memory executions_ = _buildExecutions(termsInfo_, aggregatorId_, routeData_);

        IDeleGatorCore(delegator_).executeFromExecutor(ModeLib.encodeSimpleBatch(), executions_.encodeBatch());
    }

    function _buildExecutions(
        Terms memory termsInfo_,
        string memory aggregatorId_,
        bytes memory routeData_
    )
        private
        pure
        returns (Execution[] memory executions_)
    {
        ApprovalMode approvalMode_ = termsInfo_.approvalMode;

        if (termsInfo_.tokenIn == address(0)) {
            if (approvalMode_ != ApprovalMode.None) revert InvalidApprovalMode();

            executions_ = new Execution[](1);
            executions_[0] = _swapExecution(termsInfo_, termsInfo_.tokenInAmount, aggregatorId_, routeData_);
            return executions_;
        }

        uint256 swapIndex_;
        if (approvalMode_ == ApprovalMode.SkipApproval) {
            executions_ = new Execution[](1);
        } else if (approvalMode_ == ApprovalMode.Approve) {
            executions_ = new Execution[](2);
            executions_[0] = _approvalExecution(termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            swapIndex_ = 1;
        } else if (approvalMode_ == ApprovalMode.ResetApprove) {
            executions_ = new Execution[](3);
            executions_[0] = _approvalExecution(termsInfo_.tokenIn, termsInfo_.metaSwap, 0);
            executions_[1] = _approvalExecution(termsInfo_.tokenIn, termsInfo_.metaSwap, termsInfo_.tokenInAmount);
            swapIndex_ = 2;
        } else {
            revert InvalidApprovalMode();
        }

        executions_[swapIndex_] = _swapExecution(termsInfo_, 0, aggregatorId_, routeData_);
    }

    function _approvalExecution(address tokenIn_, address metaSwap_, uint256 amount_) private pure returns (Execution memory) {
        return Execution({ target: tokenIn_, value: 0, callData: abi.encodeCall(IERC20.approve, (metaSwap_, amount_)) });
    }

    function _swapExecution(
        Terms memory termsInfo_,
        uint256 value_,
        string memory aggregatorId_,
        bytes memory routeData_
    )
        private
        pure
        returns (Execution memory)
    {
        return Execution({
            target: termsInfo_.metaSwap,
            value: value_,
            callData: abi.encodeCall(
                IMetaSwap.swap, (aggregatorId_, IERC20(termsInfo_.tokenIn), termsInfo_.tokenInAmount, routeData_)
            )
        });
    }
}
