// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC7579Account } from "@erc7579/interfaces/IERC7579Account.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { ExactExecutionEnforcer } from "../../../src/enforcers/ExactExecutionEnforcer.sol";
import { LimitedCallsEnforcer } from "../../../src/enforcers/LimitedCallsEnforcer.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import { ExactGasComparison } from "./GasComparisonFixture.t.sol";

/**
 * @notice Gasless exact baseline on `DelegationManager`.
 * @dev `ExactExecutionEnforcer` pins one outer call: `user.execute(SIMPLE_BATCH_MODE, innerBatch)`.
 *      `LimitedCalls(1)` makes that root single use. Delegate is `ANY_DELEGATE`.
 *      The inner batch is approve + swap + an ERC-20 fee transfer, or a native-value swap + that transfer.
 */
contract GaslessExactSelfCallGasTest is ExactGasComparison {
    ExactExecutionEnforcer private exactExecution;
    LimitedCallsEnforcer private limitedCalls;

    function _comparisonName() internal pure override returns (string memory) {
        return "GaslessExactSelfCall";
    }

    function _installComparison() internal override {
        exactExecution = new ExactExecutionEnforcer();
        limitedCalls = new LimitedCallsEnforcer();
        _installUser(address(delegationManager));
    }

    function _armLaterExact(Shape shape_) internal override {
        _prepareLaterGaslessBalances(shape_);
    }

    /// @dev The delegated execution is the self-call. The swap batch is its calldata.
    function _runExact(Shape shape_) internal override returns (uint256) {
        bytes memory batch_ = ExecutionLib.encodeBatch(_gaslessExecutions(shape_));
        Execution memory outerExecution_ =
            Execution({ target: user, value: 0, callData: abi.encodeCall(IERC7579Account.execute, (_batchMode(), batch_)) });
        bytes memory outerExecutionCallData_ =
            ExecutionLib.encodeSingle(outerExecution_.target, outerExecution_.value, outerExecution_.callData);
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ enforcer: address(exactExecution), terms: outerExecutionCallData_, args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(limitedCalls), terms: abi.encode(uint256(1)), args: hex"" });
        Delegation[] memory chains_ = new Delegation[](1);
        chains_[0] = _signRoot(ANY_DELEGATE, ROOT_AUTHORITY, delegationManager.getDomainHash(), caveats_, 1);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = _singleMode();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = outerExecutionCallData_;
        return _redeemDelegationsGasless(address(delegationManager), chains_, modes_, executionCallDatas_, shape_);
    }
}
