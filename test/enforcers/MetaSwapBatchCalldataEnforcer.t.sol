// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { MetaSwapBatchCalldataEnforcer } from "../../src/enforcers/MetaSwapBatchCalldataEnforcer.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { Execution, ModeCode } from "../../src/utils/Types.sol";

contract MetaSwapBatchCalldataEnforcerTest is Test {
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;

    MetaSwapBatchCalldataEnforcer internal enforcer;
    address internal metaSwap;
    address internal tokenIn;
    ModeCode internal batchDefaultMode = ModeLib.encodeSimpleBatch();

    function setUp() public {
        enforcer = new MetaSwapBatchCalldataEnforcer();
        metaSwap = makeAddr("MetaSwap");
        tokenIn = makeAddr("TokenIn");
    }

    function test_erc20OneApproval_acceptsFlexibleRoute() public view {
        _enforce(_terms(tokenIn, false), _erc20Batch(false, tokenIn, TOKEN_IN_AMOUNT, "a", hex"01"));
        _enforce(_terms(tokenIn, false), _erc20Batch(false, tokenIn, TOKEN_IN_AMOUNT, "different", new bytes(512)));
    }

    function test_erc20ResetApproval_acceptsSignedShape() public view {
        _enforce(_terms(tokenIn, true), _erc20Batch(true, tokenIn, TOKEN_IN_AMOUNT, "aggregator", new bytes(96)));
    }

    function test_nativeInput_acceptsSingleSwap() public view {
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = _swap(address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, "aggregator", hex"1234");
        _enforce(_terms(address(0), false), executions_);
    }

    function test_revertsOnSingleDelegationManagerMode() public {
        Execution[] memory executions_ = _erc20Batch(false, tokenIn, TOKEN_IN_AMOUNT, "aggregator", hex"");

        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        enforcer.beforeHook(
            _terms(tokenIn, false),
            hex"",
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeBatch(executions_),
            bytes32(0),
            address(0),
            address(0)
        );
    }

    function test_revertsOnDifferentSwapToken() public {
        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-swap");
        _enforce(_terms(tokenIn, false), _erc20Batch(false, makeAddr("OtherToken"), TOKEN_IN_AMOUNT, "aggregator", hex""));
    }

    function test_revertsOnDifferentSwapAmount() public {
        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-swap");
        _enforce(_terms(tokenIn, false), _erc20Batch(false, tokenIn, TOKEN_IN_AMOUNT - 1, "aggregator", hex""));
    }

    function test_revertsOnWrongApprovalSpender() public {
        Execution[] memory executions_ = _erc20Batch(false, tokenIn, TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.approve, (makeAddr("OtherSpender"), TOKEN_IN_AMOUNT));

        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-approval");
        _enforce(_terms(tokenIn, false), executions_);
    }

    function test_revertsWhenApprovalShapeDoesNotMatchTerms() public {
        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-batch-length");
        _enforce(_terms(tokenIn, false), _erc20Batch(true, tokenIn, TOKEN_IN_AMOUNT, "aggregator", hex""));
    }

    function _terms(address tokenIn_, bool resetApproval_) private view returns (bytes memory) {
        return abi.encodePacked(metaSwap, tokenIn_, TOKEN_IN_AMOUNT, bytes1(resetApproval_ ? 0x01 : 0x00));
    }

    function _erc20Batch(
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
        if (resetApproval_) executions_[0] = _approval(0);
        executions_[swapIndex_ - 1] = _approval(TOKEN_IN_AMOUNT);
        executions_[swapIndex_] = _swap(swapToken_, swapAmount_, 0, aggregatorId_, route_);
    }

    function _approval(uint256 amount_) private view returns (Execution memory) {
        return Execution({ target: tokenIn, value: 0, callData: abi.encodeCall(IERC20.approve, (metaSwap, amount_)) });
    }

    function _swap(
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

    function _enforce(bytes memory terms_, Execution[] memory executions_) private view {
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), bytes32(0), address(0), address(0)
        );
    }
}
