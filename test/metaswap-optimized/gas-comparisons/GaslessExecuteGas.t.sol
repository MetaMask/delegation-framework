// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { ExactExecutionEnforcer } from "../../../src/enforcers/ExactExecutionEnforcer.sol";
import { LimitedCallsEnforcer } from "../../../src/enforcers/LimitedCallsEnforcer.sol";
import { RedeemerEnforcer } from "../../../src/enforcers/RedeemerEnforcer.sol";
import { TimestampEnforcer } from "../../../src/enforcers/TimestampEnforcer.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import { ExactGasComparison } from "./GasComparisonFixture.t.sol";

/**
 * @notice Signed gasless 7702 baseline on `DelegationManager`.
 * @dev One root, single mode. The execution is `user.execute(batch)`, and that call is what
 *      `ExactExecutionEnforcer` pins. Native input carries one inner call, the swap with value.
 *      ERC-20 input carries approve then swap. The gas fee is inside the swap. Caveats follow the
 *      wallet: `LimitedCallsEnforcer(1)`, `TimestampEnforcer`, `RedeemerEnforcer`, then exact execution.
 */
contract GaslessExecuteGasTest is ExactGasComparison {
    ExactExecutionEnforcer private exactExecution;
    LimitedCallsEnforcer private limitedCalls;
    TimestampEnforcer private timestampEnforcer;
    RedeemerEnforcer private redeemerEnforcer;

    function _comparisonName() internal pure override returns (string memory) {
        return "GaslessExecute";
    }

    function _installComparison() internal override {
        exactExecution = new ExactExecutionEnforcer();
        limitedCalls = new LimitedCallsEnforcer();
        timestampEnforcer = new TimestampEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();
        _installUser(address(delegationManager));
    }

    function _armLaterExact(Shape shape_) internal override {
        _prepareLaterGaslessBalances(shape_);
    }

    function _runExact(Shape shape_) internal override returns (uint256) {
        bytes memory executionCallData_ = _executeCall(shape_);
        Caveat[] memory caveats_ = new Caveat[](4);
        caveats_[0] = Caveat({ enforcer: address(limitedCalls), terms: abi.encode(uint256(1)), args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(timestampEnforcer), terms: _timestampTerms(), args: hex"" });
        caveats_[2] = Caveat({ enforcer: address(redeemerEnforcer), terms: _redeemerTerms(), args: hex"" });
        caveats_[3] = Caveat({ enforcer: address(exactExecution), terms: executionCallData_, args: hex"" });
        Delegation[] memory chains_ = new Delegation[](1);
        chains_[0] = _signRoot(ANY_DELEGATE, ROOT_AUTHORITY, delegationManager.getDomainHash(), caveats_, 1);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = _singleMode();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = executionCallData_;
        return _redeemDelegationsGasless(address(delegationManager), chains_, modes_, executionCallDatas_, shape_);
    }

    /// @dev The redeem execution is one self-call. `execute` runs the inner batch.
    function _executeCall(Shape shape_) private view returns (bytes memory) {
        return ExecutionLib.encodeSingle(
            user, 0, abi.encodeWithSignature("execute(bytes32,bytes)", _batchMode(), ExecutionLib.encodeBatch(_innerBatch(shape_)))
        );
    }

    /// @dev Native input is the swap alone, value on that call. ERC-20 input approves the pull, then swaps.
    ///      A source fee is part of that pull. A destination fee is split from the output.
    function _innerBatch(Shape shape_) private view returns (Execution[] memory executions_) {
        if (shape_ == Shape.NativeToErc20) {
            executions_ = new Execution[](1);
            executions_[0] = _swapExecutionWithFee(address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, address(tokenOut), false);
            return executions_;
        }

        bool feeFromSource_ = shape_ == Shape.Erc20ToNative;
        address tokenOut_ = feeFromSource_ ? address(0) : address(tokenOut);
        uint256 pull_ = feeFromSource_ ? TOKEN_IN_AMOUNT + GASLESS_FEE_AMOUNT : TOKEN_IN_AMOUNT;
        executions_ = new Execution[](2);
        executions_[0] = _approvalExecution(pull_);
        executions_[1] = _swapExecutionWithFee(address(tokenIn), pull_, 0, tokenOut_, feeFromSource_);
    }
}
