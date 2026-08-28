// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { GasStation7702SwapTestBase } from "./GasStation7702SwapTestBase.t.sol";
import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";

/**
 * @title User pays gas in ERC-20 — `Delegation7702PublishHook` when `selectedGasFeeToken` is set
 *
 * @dev Mobile:
 *      `includeTransfer = true` → `BATCH_DEFAULT_MODE` → `[userExecution, feeTransfer]`
 *      caveats: `specificActionERC20TransferBatch(token, recipient, amount, to, value, data)` + `limitedCalls(1)`
 *
 * @dev Second execution MUST be `ERC20.transfer(feeRecipient, amount)` — not approve, not swap.
 *      `userExecution` is still `txParams` (7702 `execute` wrapping the nested swap calls).
 */
contract UserPaysGasWithTokenTest is GasStation7702SwapTestBase {
    function setUp() public override {
        super.setUp();
        // Alice needs USDC both to swap (ERC-20 case) and to pay the gas fee (both cases).
        usdc.mint(alice7702, FEE_AMOUNT);
    }

    function test_native_batch_swapThenFeeTransfer() public {
        Execution memory userExecution_ = _wrapAs7702Execute(_nativeSwapNested());
        Execution memory feeExecution_ = _feeTransferExecution();

        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = userExecution_;
        executions_[1] = feeExecution_;

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _specificActionCaveat(address(usdc), feeRecipient, FEE_AMOUNT, userExecution_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation memory delegation_ = _signOpenDelegation(caveats_);

        uint256 ethBefore_ = alice7702.balance;
        uint256 destBefore_ = destToken.balanceOf(alice7702);
        uint256 feeBefore_ = usdc.balanceOf(feeRecipient);
        uint256 aliceUsdcBefore_ = usdc.balanceOf(alice7702);

        _redeem(delegation_, batchDefaultMode, ExecutionLib.encodeBatch(executions_));

        assertEq(alice7702.balance, ethBefore_ - SWAP_AMOUNT, "native in");
        assertEq(destToken.balanceOf(alice7702), destBefore_ + SWAP_AMOUNT, "dest out");
        assertEq(usdc.balanceOf(feeRecipient), feeBefore_ + FEE_AMOUNT, "fee paid in usdc");
        assertEq(usdc.balanceOf(alice7702), aliceUsdcBefore_ - FEE_AMOUNT, "fee debited from alice");
    }

    function test_erc20_batch_approveSwapThenFeeTransfer() public {
        Execution memory userExecution_ = _wrapAs7702Execute(_erc20SwapNested());
        Execution memory feeExecution_ = _feeTransferExecution();

        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = userExecution_;
        executions_[1] = feeExecution_;

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _specificActionCaveat(address(usdc), feeRecipient, FEE_AMOUNT, userExecution_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation memory delegation_ = _signOpenDelegation(caveats_);

        uint256 usdcBefore_ = usdc.balanceOf(alice7702);
        uint256 destBefore_ = destToken.balanceOf(alice7702);

        _redeem(delegation_, batchDefaultMode, ExecutionLib.encodeBatch(executions_));

        assertEq(usdc.balanceOf(alice7702), usdcBefore_ - SWAP_AMOUNT - FEE_AMOUNT, "swap in + fee");
        assertEq(destToken.balanceOf(alice7702), destBefore_ + SWAP_AMOUNT, "dest out");
        assertEq(usdc.balanceOf(feeRecipient), FEE_AMOUNT, "fee paid in usdc");
    }

    function test_native_secondRedeemReverts_limitedCallsAndSpecificAction() public {
        Execution memory userExecution_ = _wrapAs7702Execute(_nativeSwapNested());
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = userExecution_;
        executions_[1] = _feeTransferExecution();

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _specificActionCaveat(address(usdc), feeRecipient, FEE_AMOUNT, userExecution_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation memory delegation_ = _signOpenDelegation(caveats_);
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        _redeem(delegation_, batchDefaultMode, executionCallData_);

        // SpecificAction marks usedDelegations in beforeHook; LimitedCalls also increments.
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:delegation-already-used");
        _redeem(delegation_, batchDefaultMode, executionCallData_);
    }

    function test_erc20_wrongFeeAmountReverts_specificAction() public {
        Execution memory userExecution_ = _wrapAs7702Execute(_erc20SwapNested());

        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = userExecution_;
        executions_[1] = Execution({
            target: address(usdc), value: 0, callData: abi.encodeCall(IERC20.transfer, (feeRecipient, FEE_AMOUNT + 1))
        });

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _specificActionCaveat(address(usdc), feeRecipient, FEE_AMOUNT, userExecution_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation memory delegation_ = _signOpenDelegation(caveats_);

        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-second-transaction");
        _redeem(delegation_, batchDefaultMode, ExecutionLib.encodeBatch(executions_));
    }

    function test_revertsIfRedeemedAsSingle_specificActionRequiresBatchMode() public {
        Execution memory userExecution_ = _wrapAs7702Execute(_nativeSwapNested());

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = _specificActionCaveat(address(usdc), feeRecipient, FEE_AMOUNT, userExecution_);
        caveats_[1] = _limitedCallsCaveat(1);

        Delegation memory delegation_ = _signOpenDelegation(caveats_);

        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        _redeem(
            delegation_,
            singleDefaultMode,
            ExecutionLib.encodeSingle(userExecution_.target, userExecution_.value, userExecution_.callData)
        );
    }
}
