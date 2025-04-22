// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { LogicalOrWrapperEnforcer } from "../../src/enforcers/LogicalOrWrapperEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { TimestampEnforcer } from "../../src/enforcers/TimestampEnforcer.sol";

contract LogicalOrWrapperEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////

    LogicalOrWrapperEnforcer public logicalOrWrapperEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    TimestampEnforcer public timestampEnforcer;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer(delegationManager);
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        timestampEnforcer = new TimestampEnforcer();
        vm.label(address(logicalOrWrapperEnforcer), "Logical OR Wrapper Enforcer");
        vm.label(address(allowedMethodsEnforcer), "Allowed Methods Enforcer");
        vm.label(address(timestampEnforcer), "Timestamp Enforcer");
    }

    ////////////////////// Helper Functions //////////////////////

    function _createCaveatGroup(
        address[] memory enforcers,
        bytes[] memory terms
    )
        internal
        pure
        returns (LogicalOrWrapperEnforcer.CaveatGroup memory)
    {
        require(enforcers.length == terms.length, "LogicalOrWrapperEnforcerTest:invalid-input-length");
        Caveat[] memory caveats = new Caveat[](enforcers.length);
        for (uint256 i = 0; i < enforcers.length; ++i) {
            caveats[i] = Caveat({ enforcer: enforcers[i], terms: terms[i], args: hex"" });
        }
        return LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveats });
    }

    function _createSelectedGroup(
        uint256 groupIndex,
        bytes[] memory caveatArgs
    )
        internal
        pure
        returns (LogicalOrWrapperEnforcer.SelectedGroup memory)
    {
        return LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: groupIndex, caveatArgs: caveatArgs });
    }

    ////////////////////// Valid cases //////////////////////

    function test_singleCaveatGroupWithSingleCaveat() public {
        // Create a group with a single caveat (allowed methods)
        address[] memory enforcers = new address[](1);
        enforcers[0] = address(allowedMethodsEnforcer);
        bytes[] memory terms = new bytes[](1);
        terms[0] = abi.encodePacked(Counter.increment.selector);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups[0] = _createCaveatGroup(enforcers, terms);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs = new bytes[](1);
        caveatArgs[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs);

        // Call the hook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    function test_singleCaveatGroupWithMultipleCaveats() public {
        // Create a group with multiple caveats (allowed methods and timestamp)
        address[] memory enforcers = new address[](2);
        enforcers[0] = address(allowedMethodsEnforcer);
        enforcers[1] = address(timestampEnforcer);
        bytes[] memory terms = new bytes[](2);
        terms[0] = abi.encodePacked(Counter.increment.selector);
        terms[1] = abi.encode(block.timestamp + 1 days);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups[0] = _createCaveatGroup(enforcers, terms);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs = new bytes[](2);
        caveatArgs[0] = hex"";
        caveatArgs[1] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs);

        // Call the hook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    function test_multipleCaveatGroups() public {
        // Create two groups with different caveats
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups = new LogicalOrWrapperEnforcer.CaveatGroup[](2);

        // First group: allowed methods
        address[] memory enforcers1 = new address[](1);
        enforcers1[0] = address(allowedMethodsEnforcer);
        bytes[] memory terms1 = new bytes[](1);
        terms1[0] = abi.encodePacked(Counter.increment.selector);
        groups[0] = _createCaveatGroup(enforcers1, terms1);

        // Second group: timestamp
        address[] memory enforcers2 = new address[](1);
        enforcers2[0] = address(timestampEnforcer);
        bytes[] memory terms2 = new bytes[](1);
        terms2[0] = abi.encode(block.timestamp + 1 days);
        groups[1] = _createCaveatGroup(enforcers2, terms2);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Test first group
        bytes[] memory caveatArgs1 = new bytes[](1);
        caveatArgs1[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup1_ = _createSelectedGroup(0, caveatArgs1);

        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups),
            abi.encode(selectedGroup1_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Test second group
        bytes[] memory caveatArgs2 = new bytes[](1);
        caveatArgs2[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup2_ = _createSelectedGroup(1, caveatArgs2);

        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups),
            abi.encode(selectedGroup2_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    function test_invalidGroupIndex() public {
        // Create a single group
        address[] memory enforcers = new address[](1);
        enforcers[0] = address(allowedMethodsEnforcer);
        bytes[] memory terms = new bytes[](1);
        terms[0] = abi.encodePacked(Counter.increment.selector);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups[0] = _createCaveatGroup(enforcers, terms);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with invalid index
        bytes[] memory caveatArgs = new bytes[](1);
        caveatArgs[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(1, caveatArgs);

        // Call the hook
        vm.prank(address(delegationManager));
        vm.expectRevert("LogicalOrWrapperEnforcer:invalid-group-index");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    function test_invalidCaveatArgsLength() public {
        // Create a group with two caveats
        address[] memory enforcers = new address[](2);
        enforcers[0] = address(allowedMethodsEnforcer);
        enforcers[1] = address(timestampEnforcer);
        bytes[] memory terms = new bytes[](2);
        terms[0] = abi.encodePacked(Counter.increment.selector);
        terms[1] = abi.encode(block.timestamp + 1 days);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups[0] = _createCaveatGroup(enforcers, terms);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with wrong number of arguments
        bytes[] memory caveatArgs = new bytes[](1);
        caveatArgs[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs);

        // Call the hook
        vm.prank(address(delegationManager));
        vm.expectRevert("LogicalOrWrapperEnforcer:invalid-caveat-args-length");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    function test_invalidExecutionMode() public {
        // Create a group with a single caveat
        address[] memory enforcers = new address[](1);
        enforcers[0] = address(allowedMethodsEnforcer);
        bytes[] memory terms = new bytes[](1);
        terms[0] = abi.encodePacked(Counter.increment.selector);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups[0] = _createCaveatGroup(enforcers, terms);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group
        bytes[] memory caveatArgs = new bytes[](1);
        caveatArgs[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs);

        // Call the hook with invalid singleTryMode
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups), abi.encode(selectedGroup_), singleTryMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    ////////////////////// Integration //////////////////////

    function test_integrationWithDelegation() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create a group with multiple caveats
        address[] memory enforcers = new address[](2);
        enforcers[0] = address(allowedMethodsEnforcer);
        enforcers[1] = address(timestampEnforcer);
        bytes[] memory terms = new bytes[](2);
        terms[0] = abi.encodePacked(Counter.increment.selector);
        terms[1] = abi.encode(block.timestamp + 1 days);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups[0] = _createCaveatGroup(enforcers, terms);

        // Create execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Create caveat for the logical OR wrapper
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(logicalOrWrapperEnforcer),
            terms: abi.encode(groups),
            args: abi.encode(_createSelectedGroup(0, new bytes[](2)))
        });

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Enforcer allows the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Get count
        uint256 valueAfter_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(valueAfter_, initialValue_ + 1);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(logicalOrWrapperEnforcer));
    }
}
