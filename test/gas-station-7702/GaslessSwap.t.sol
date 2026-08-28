// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { GasStation7702SwapTestBase } from "./GasStation7702SwapTestBase.t.sol";
import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";

/**
 * @title Gasless 7702 swap — `Delegation7702PublishHook` when `isGasFeeIncluded`
 *
 * @dev Mobile:
 *      `includeTransfer = false` → `SINGLE_DEFAULT_MODE` → one execution from `txParams`
 *      caveats: `exactExecution(to, value, data)` + `limitedCalls(1)`
 *
 * @dev Relayer pays native gas. Fee is priced into the quote (`feeData.txFee`), not a second execution.
 */
contract GaslessSwapTest is GasStation7702SwapTestBase {
    function test_native_singleExecution_exactExecutionAndLimitedCalls() public {
        Execution[] memory nested_ = _nativeSwapNested();
        Execution memory userExecution_ = _wrapAs7702Execute(nested_);

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _exactExecutionCaveat(userExecution_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation memory delegation_ = _signOpenDelegation(caveats_);

        uint256 ethBefore_ = alice7702.balance;
        uint256 destBefore_ = destToken.balanceOf(alice7702);

        _redeem(
            delegation_,
            singleDefaultMode,
            ExecutionLib.encodeSingle(userExecution_.target, userExecution_.value, userExecution_.callData)
        );

        assertEq(alice7702.balance, ethBefore_ - SWAP_AMOUNT, "native in");
        assertEq(destToken.balanceOf(alice7702), destBefore_ + SWAP_AMOUNT, "dest out");
        assertEq(usdc.balanceOf(feeRecipient), 0, "no fee-token transfer on gasless");
    }

    function test_erc20_singleExecution_approveAndSwapInside7702Execute() public {
        Execution[] memory nested_ = _erc20SwapNested();
        Execution memory userExecution_ = _wrapAs7702Execute(nested_);

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _exactExecutionCaveat(userExecution_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation memory delegation_ = _signOpenDelegation(caveats_);

        uint256 usdcBefore_ = usdc.balanceOf(alice7702);
        uint256 destBefore_ = destToken.balanceOf(alice7702);

        _redeem(
            delegation_,
            singleDefaultMode,
            ExecutionLib.encodeSingle(userExecution_.target, userExecution_.value, userExecution_.callData)
        );

        assertEq(usdc.balanceOf(alice7702), usdcBefore_ - SWAP_AMOUNT, "usdc in");
        assertEq(destToken.balanceOf(alice7702), destBefore_ + SWAP_AMOUNT, "dest out");
        assertEq(usdc.allowance(alice7702, address(router)), 0, "approve spent by swap");
    }

    function test_native_secondRedeemReverts_limitedCalls() public {
        Execution memory userExecution_ = _wrapAs7702Execute(_nativeSwapNested());

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _exactExecutionCaveat(userExecution_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation memory delegation_ = _signOpenDelegation(caveats_);
        bytes memory executionCallData_ =
            ExecutionLib.encodeSingle(userExecution_.target, userExecution_.value, userExecution_.callData);

        _redeem(delegation_, singleDefaultMode, executionCallData_);

        vm.expectRevert("LimitedCallsEnforcer:limit-exceeded");
        _redeem(delegation_, singleDefaultMode, executionCallData_);
    }

    function test_erc20_tamperedCalldataReverts_exactExecution() public {
        Execution memory userExecution_ = _wrapAs7702Execute(_erc20SwapNested());

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _exactExecutionCaveat(userExecution_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation memory delegation_ = _signOpenDelegation(caveats_);

        // Relayer cannot swap in a different inner batch: ExactExecution pins the whole execute blob.
        Execution[] memory tamperedNested_ = _erc20SwapNested();
        tamperedNested_[1].callData = abi.encodeWithSelector(bytes4(0xdeadbeef));
        Execution memory tampered_ = _wrapAs7702Execute(tamperedNested_);

        vm.expectRevert("ExactExecutionEnforcer:invalid-execution");
        _redeem(delegation_, singleDefaultMode, ExecutionLib.encodeSingle(tampered_.target, tampered_.value, tampered_.callData));
    }

    function test_revertsIfRedeemedAsBatch_exactExecutionRequiresSingleMode() public {
        Execution memory userExecution_ = _wrapAs7702Execute(_nativeSwapNested());

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _exactExecutionCaveat(userExecution_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation memory delegation_ = _signOpenDelegation(caveats_);

        Execution[] memory asBatch_ = new Execution[](1);
        asBatch_[0] = userExecution_;

        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        _redeem(delegation_, batchDefaultMode, ExecutionLib.encodeBatch(asBatch_));
    }
}
