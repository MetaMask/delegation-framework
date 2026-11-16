// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { ExactExecutionBatchEnforcer } from "../../../src/enforcers/ExactExecutionBatchEnforcer.sol";
import { LimitedCallsEnforcer } from "../../../src/enforcers/LimitedCallsEnforcer.sol";
import { RedeemerEnforcer } from "../../../src/enforcers/RedeemerEnforcer.sol";
import { TimestampEnforcer } from "../../../src/enforcers/TimestampEnforcer.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import { ExactGasComparison } from "./GasComparisonFixture.t.sol";

/**
 * @notice Gasless 7702 baseline for a relay that repays the gas station with its own ERC-20 transfer.
 * @dev One root, batch mode. The batch is the parent `user.execute(swap legs)` plus `feeToken.transfer`.
 *      Native input is one inner swap with value. ERC-20 input is approve then swap. The swap pays the
 *      full output; the fee leaves in the second execution. Caveats follow the wallet: `LimitedCallsEnforcer(1)`,
 *      `TimestampEnforcer`, `RedeemerEnforcer`, then `ExactExecutionBatchEnforcer`.
 */
contract GaslessFeeTransferGasTest is ExactGasComparison {
    ExactExecutionBatchEnforcer private exactBatch;
    LimitedCallsEnforcer private limitedCalls;
    TimestampEnforcer private timestampEnforcer;
    RedeemerEnforcer private redeemerEnforcer;

    function _comparisonName() internal pure override returns (string memory) {
        return "GaslessFeeTransfer";
    }

    function _installComparison() internal override {
        exactBatch = new ExactExecutionBatchEnforcer();
        limitedCalls = new LimitedCallsEnforcer();
        timestampEnforcer = new TimestampEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();
        _installUser(address(delegationManager));
    }

    function _runExact(Shape shape_, uint256 fill_) internal override returns (uint256) {
        bytes memory batch_ = ExecutionLib.encodeBatch(_redeemBatch(shape_));
        Caveat[] memory caveats_ = new Caveat[](4);
        caveats_[0] = Caveat({ enforcer: address(limitedCalls), terms: abi.encode(uint256(1)), args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(timestampEnforcer), terms: _timestampTerms(), args: hex"" });
        caveats_[2] = Caveat({ enforcer: address(redeemerEnforcer), terms: _redeemerTerms(), args: hex"" });
        caveats_[3] = Caveat({ enforcer: address(exactBatch), terms: batch_, args: hex"" });
        Delegation[] memory chains_ = new Delegation[](1);
        chains_[0] = _signRoot(ANY_DELEGATE, ROOT_AUTHORITY, delegationManager.getDomainHash(), caveats_, fill_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = _batchMode();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = batch_;
        return _redeemDelegationsGasless(address(delegationManager), chains_, modes_, executionCallDatas_, shape_);
    }

    /// @dev Two redeem executions: the swap batch, then the fee transfer.
    function _redeemBatch(Shape shape_) private view returns (Execution[] memory executions_) {
        executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: user,
            value: 0,
            callData: abi.encodeWithSignature("execute(bytes32,bytes)", _batchMode(), ExecutionLib.encodeBatch(_innerBatch(shape_)))
        });
        executions_[1] = _feeTransferExecution(_feeToken(shape_));
    }

    /// @dev The swap pays the full output. The fee token is what the following transfer sends.
    function _innerBatch(Shape shape_) private view returns (Execution[] memory executions_) {
        if (shape_ == Shape.NativeToErc20) {
            executions_ = new Execution[](1);
            executions_[0] = _swapExecution(address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, address(tokenOut));
            return executions_;
        }

        address tokenOut_ = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
        executions_ = new Execution[](2);
        executions_[0] = _approvalExecution(TOKEN_IN_AMOUNT);
        executions_[1] = _swapExecution(address(tokenIn), TOKEN_IN_AMOUNT, 0, tokenOut_);
    }

    function _feeToken(Shape shape_) private view returns (address) {
        return shape_ == Shape.Erc20ToNative ? address(tokenIn) : address(tokenOut);
    }
}
