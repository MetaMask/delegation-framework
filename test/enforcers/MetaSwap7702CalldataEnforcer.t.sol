// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { MetaSwap7702CalldataEnforcer } from "../../src/enforcers/MetaSwap7702CalldataEnforcer.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { IERC7821 } from "../../src/interfaces/IERC7821.sol";
import { Execution, ModeCode } from "../../src/utils/Types.sol";

contract MetaSwap7702CalldataEnforcerTest is Test {
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;

    MetaSwap7702CalldataEnforcer internal enforcer;
    address internal delegator;
    address internal metaSwap;
    address internal tokenIn;

    ModeCode internal singleDefaultMode = ModeLib.encodeSimpleSingle();

    function setUp() public {
        enforcer = new MetaSwap7702CalldataEnforcer();
        delegator = makeAddr("Delegator");
        metaSwap = makeAddr("MetaSwap");
        tokenIn = makeAddr("TokenIn");
    }

    function test_erc20OneApproval_acceptsArbitraryDynamicRoute() public view {
        _enforce(_terms(tokenIn, false), _outer(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "aggregator-a", hex"01")));
        _enforce(
            _terms(tokenIn, false), _outer(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "different-aggregator", new bytes(512)))
        );
    }

    function test_erc20ResetApproval_acceptsSignedThreeCallShape() public view {
        _enforce(_terms(tokenIn, true), _outer(_erc20Inner(true, tokenIn, TOKEN_IN_AMOUNT, "aggregator", new bytes(96))));
    }

    function test_nativeInput_acceptsOneSwapWithExactValue() public view {
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = _swapExecution(address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, "aggregator", hex"1234");

        _enforce(_terms(address(0), false), _outer(executions_));
    }

    function test_revertsOnDifferentSwapTokenFrom() public {
        Execution memory outer_ = _outer(_erc20Inner(false, makeAddr("OtherToken"), TOKEN_IN_AMOUNT, "aggregator", hex""));

        vm.expectRevert("MetaSwap7702CalldataEnforcer:invalid-swap");
        _enforce(_terms(tokenIn, false), outer_);
    }

    function test_revertsOnDifferentSwapAmount() public {
        Execution memory outer_ = _outer(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT - 1, "aggregator", hex""));

        vm.expectRevert("MetaSwap7702CalldataEnforcer:invalid-swap");
        _enforce(_terms(tokenIn, false), outer_);
    }

    function test_revertsWhenResetShapeDoesNotMatchTerms() public {
        Execution memory outer_ = _outer(_erc20Inner(true, tokenIn, TOKEN_IN_AMOUNT, "aggregator", hex""));

        vm.expectRevert("MetaSwap7702CalldataEnforcer:invalid-batch-length");
        _enforce(_terms(tokenIn, false), outer_);
    }

    function test_revertsWhenApprovalAmountDoesNotMatch() public {
        Execution[] memory executions_ = _erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.approve, (metaSwap, TOKEN_IN_AMOUNT - 1));

        vm.expectRevert("MetaSwap7702CalldataEnforcer:invalid-approval");
        _enforce(_terms(tokenIn, false), _outer(executions_));
    }

    function test_revertsWhenOuterTargetIsNotDelegator() public {
        Execution memory outer_ = _outer(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "aggregator", hex""));
        outer_.target = makeAddr("OtherTarget");

        vm.expectRevert("MetaSwap7702CalldataEnforcer:invalid-outer-execution");
        _enforce(_terms(tokenIn, false), outer_);
    }

    function test_revertsWhenInnerModeIsNotBatchDefault() public {
        Execution[] memory executions_ = _erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "aggregator", hex"");
        Execution memory outer_ = Execution({
            target: delegator,
            value: 0,
            callData: abi.encodeCall(IERC7821.execute, (ModeLib.encodeSimpleSingle(), ExecutionLib.encodeBatch(executions_)))
        });

        vm.expectRevert("MetaSwap7702CalldataEnforcer:invalid-inner-mode");
        _enforce(_terms(tokenIn, false), outer_);
    }

    function _terms(address tokenIn_, bool resetApproval_) private view returns (bytes memory) {
        return abi.encodePacked(metaSwap, tokenIn_, TOKEN_IN_AMOUNT, bytes1(resetApproval_ ? 0x01 : 0x00));
    }

    function _erc20Inner(
        bool resetApproval_,
        address swapToken_,
        uint256 swapAmount_,
        string memory aggregatorId_,
        bytes memory route_
    )
        private
        view
        returns (Execution[] memory executions_)
    {
        uint256 swapIndex_ = resetApproval_ ? 2 : 1;
        executions_ = new Execution[](swapIndex_ + 1);

        if (resetApproval_) {
            executions_[0] = _approvalExecution(0);
        }
        executions_[swapIndex_ - 1] = _approvalExecution(TOKEN_IN_AMOUNT);
        executions_[swapIndex_] = _swapExecution(swapToken_, swapAmount_, 0, aggregatorId_, route_);
    }

    function _approvalExecution(uint256 amount_) private view returns (Execution memory) {
        return Execution({ target: tokenIn, value: 0, callData: abi.encodeCall(IERC20.approve, (metaSwap, amount_)) });
    }

    function _swapExecution(
        address swapToken_,
        uint256 swapAmount_,
        uint256 value_,
        string memory aggregatorId_,
        bytes memory route_
    )
        private
        view
        returns (Execution memory)
    {
        return Execution({
            target: metaSwap,
            value: value_,
            callData: abi.encodeCall(IMetaSwap.swap, (aggregatorId_, IERC20(swapToken_), swapAmount_, route_))
        });
    }

    function _outer(Execution[] memory executions_) private view returns (Execution memory) {
        return Execution({
            target: delegator,
            value: 0,
            callData: abi.encodeCall(IERC7821.execute, (ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(executions_)))
        });
    }

    function _enforce(bytes memory terms_, Execution memory outer_) private view {
        enforcer.beforeHook(
            terms_,
            hex"",
            singleDefaultMode,
            ExecutionLib.encodeSingle(outer_.target, outer_.value, outer_.callData),
            bytes32(0),
            delegator,
            address(0)
        );
    }
}
