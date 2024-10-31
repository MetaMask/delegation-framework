// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Counter } from "../utils/Counter.t.sol";
import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { NoValueEnforcer } from "../../src/enforcers/NoValueEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { BasicCF721 } from "../utils/BasicCF721.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract DummyContract {
    function stringFn(uint256[] calldata _str) public { }
    function arrayFn(string calldata _str) public { }
}

contract NoValueEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    ////////////////////////////// State //////////////////////////////
    NoValueEnforcer public noValueEnforcer;
    DummyContract public c;

    ModeCode public singleMode = ModeLib.encodeSimpleSingle();
    ModeCode public batchMode = ModeLib.encodeSimpleBatch();

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        noValueEnforcer = new NoValueEnforcer();
        vm.label(address(noValueEnforcer), "No Value Enforcer");
        c = new DummyContract();
    }

    ////////////////////// Valid cases //////////////////////

    // should allow an execution in single mode with no calldata
    function test_singleMethodNoCalldataIsAllowed() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({ target: address(c), value: 0, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        noValueEnforcer.beforeHook(hex"", hex"", singleMode, executionCallData_, keccak256(""), address(0), address(0));
    }

    // should allow an execution in batch mode with no calldata
    function test_batchMethodNoCalldataIsAllowed() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({ target: address(c), value: 0, callData: hex"" });
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = execution_;
        executions_[1] = execution_;
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        noValueEnforcer.beforeHook(hex"", hex"", batchMode, executionCallData_, keccak256(""), address(0), address(0));
    }

    ////////////////////// Invalid cases //////////////////////

    // should not allow an execution in single mode with calldata
    function test_singleMethodCalldataIsNotAllowed() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({ target: address(c), value: 1, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("NoValueEnforcer:value-not-allowed");
        noValueEnforcer.beforeHook(hex"", hex"", singleMode, executionCallData_, keccak256(""), address(0), address(0));
    }

    // should not allow an execution in batch mode with calldata
    function test_batchMethodCalldataIsNotAllowed() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({ target: address(c), value: 1, callData: hex"" });
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = execution_;
        executions_[1] = execution_;
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("NoValueEnforcer:value-not-allowed");
        noValueEnforcer.beforeHook(hex"", hex"", batchMode, executionCallData_, keccak256(""), address(0), address(0));

        // Make a subset of the executions have no calldata
        execution_ = Execution({ target: address(c), value: 0, callData: hex"" });
        executions_[0] = execution_;
        executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("NoValueEnforcer:value-not-allowed");
        noValueEnforcer.beforeHook(hex"", hex"", batchMode, executionCallData_, keccak256(""), address(0), address(0));
    }

    //////////////////////  Integration  //////////////////////

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(noValueEnforcer));
    }
}
