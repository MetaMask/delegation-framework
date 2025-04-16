// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { LogicalOrWrapperEnforcer } from "../../src/enforcers/LogicalOrWrapperEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract LogicalOrWrapperEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////

    LogicalOrWrapperEnforcer public logicalOrWrapperEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer1;
    AllowedMethodsEnforcer public allowedMethodsEnforcer2;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer();
        allowedMethodsEnforcer1 = new AllowedMethodsEnforcer();
        allowedMethodsEnforcer2 = new AllowedMethodsEnforcer();
        vm.label(address(logicalOrWrapperEnforcer), "Logical OR Wrapper Enforcer");
        vm.label(address(allowedMethodsEnforcer1), "Allowed Methods Enforcer 1");
        vm.label(address(allowedMethodsEnforcer2), "Allowed Methods Enforcer 2");
    }

    ////////////////////// Valid cases //////////////////////

    // should pass when a single caveat in a group passes
    function test_singleCaveatInGroupPasses() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create a single group with a single caveat that allows increment
        LogicalOrWrapperEnforcer.CaveatData[] memory caveats_ = new LogicalOrWrapperEnforcer.CaveatData[](1);
        caveats_[0] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer1),
            terms: abi.encodePacked(Counter.increment.selector)
        });

        LogicalOrWrapperEnforcer.CaveatGroup[] memory caveatGroups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        caveatGroups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveats_ });

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(caveatGroups_), hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should pass when all caveats in one group pass (AND logic within group)
    function test_allCaveatsInGroupPass() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create a group with multiple caveats that all allow increment
        LogicalOrWrapperEnforcer.CaveatData[] memory caveats_ = new LogicalOrWrapperEnforcer.CaveatData[](2);
        caveats_[0] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer1),
            terms: abi.encodePacked(Counter.increment.selector)
        });
        caveats_[1] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer2),
            terms: abi.encodePacked(Counter.increment.selector)
        });

        LogicalOrWrapperEnforcer.CaveatGroup[] memory caveatGroups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        caveatGroups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveats_ });

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(caveatGroups_), hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should pass when one group passes while others fail (OR logic between groups)
    function test_oneGroupPassesOthersFail() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create first group that will fail
        LogicalOrWrapperEnforcer.CaveatData[] memory caveatsGroup1_ = new LogicalOrWrapperEnforcer.CaveatData[](1);
        caveatsGroup1_[0] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer1),
            terms: abi.encodePacked(Counter.setCount.selector)
        });

        // Create second group that will pass
        LogicalOrWrapperEnforcer.CaveatData[] memory caveatsGroup2_ = new LogicalOrWrapperEnforcer.CaveatData[](1);
        caveatsGroup2_[0] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer2),
            terms: abi.encodePacked(Counter.increment.selector)
        });

        LogicalOrWrapperEnforcer.CaveatGroup[] memory caveatGroups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);
        caveatGroups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveatsGroup1_ });
        caveatGroups_[1] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveatsGroup2_ });

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(caveatGroups_), hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should pass when selecting a specific valid group by index
    function test_selectValidGroupByIndex() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create first group that will fail
        LogicalOrWrapperEnforcer.CaveatData[] memory caveatsGroup1_ = new LogicalOrWrapperEnforcer.CaveatData[](1);
        caveatsGroup1_[0] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer1),
            terms: abi.encodePacked(Counter.setCount.selector)
        });

        // Create second group that will pass
        LogicalOrWrapperEnforcer.CaveatData[] memory caveatsGroup2_ = new LogicalOrWrapperEnforcer.CaveatData[](1);
        caveatsGroup2_[0] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer2),
            terms: abi.encodePacked(Counter.increment.selector)
        });

        LogicalOrWrapperEnforcer.CaveatGroup[] memory caveatGroups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);
        caveatGroups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveatsGroup1_ });
        caveatGroups_[1] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveatsGroup2_ });

        // Select the second group (index 1) which should pass
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(caveatGroups_),
            abi.encode(uint256(1)), // Select second group
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should fail when no groups pass
    function test_allGroupsFail() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create two groups that will both fail
        LogicalOrWrapperEnforcer.CaveatData[] memory caveatsGroup1_ = new LogicalOrWrapperEnforcer.CaveatData[](1);
        caveatsGroup1_[0] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer1),
            terms: abi.encodePacked(Counter.setCount.selector)
        });

        LogicalOrWrapperEnforcer.CaveatData[] memory caveatsGroup2_ = new LogicalOrWrapperEnforcer.CaveatData[](1);
        caveatsGroup2_[0] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer2),
            terms: abi.encodePacked(Ownable.renounceOwnership.selector)
        });

        LogicalOrWrapperEnforcer.CaveatGroup[] memory caveatGroups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);
        caveatGroups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveatsGroup1_ });
        caveatGroups_[1] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveatsGroup2_ });

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        vm.expectRevert("LogicalOrWrapperEnforcer:all-groups-reverted");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(caveatGroups_), hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should fail when selecting an invalid group index
    function test_invalidGroupIndex() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        LogicalOrWrapperEnforcer.CaveatGroup[] memory caveatGroups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        caveatGroups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: new LogicalOrWrapperEnforcer.CaveatData[](0) });

        // Try to select group index 1 when only 0 exists
        vm.prank(address(delegationManager));
        vm.expectRevert("LogicalOrWrapperEnforcer:invalid-group-index");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(caveatGroups_),
            abi.encode(uint256(1)), // Invalid index
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    // should fail when selected group's caveats fail
    function test_selectedGroupFails() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create a group that will fail
        LogicalOrWrapperEnforcer.CaveatData[] memory caveats_ = new LogicalOrWrapperEnforcer.CaveatData[](1);
        caveats_[0] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer1),
            terms: abi.encodePacked(Counter.setCount.selector)
        });

        LogicalOrWrapperEnforcer.CaveatGroup[] memory caveatGroups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        caveatGroups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveats_ });

        // Try to use the failing group
        vm.prank(address(delegationManager));
        vm.expectRevert("LogicalOrWrapperEnforcer:all-caveats-reverted");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(caveatGroups_),
            abi.encode(uint256(0)),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        logicalOrWrapperEnforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        logicalOrWrapperEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    // should allow execution when one group passes in integration test
    function test_oneGroupPassesIntegration() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Create two groups - one that fails and one that passes
        LogicalOrWrapperEnforcer.CaveatData[] memory caveatsGroup1_ = new LogicalOrWrapperEnforcer.CaveatData[](1);
        caveatsGroup1_[0] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer1),
            terms: abi.encodePacked(Counter.setCount.selector)
        });

        LogicalOrWrapperEnforcer.CaveatData[] memory caveatsGroup2_ = new LogicalOrWrapperEnforcer.CaveatData[](1);
        caveatsGroup2_[0] = LogicalOrWrapperEnforcer.CaveatData({
            enforcer: address(allowedMethodsEnforcer2),
            terms: abi.encodePacked(Counter.increment.selector)
        });

        LogicalOrWrapperEnforcer.CaveatGroup[] memory caveatGroups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);
        caveatGroups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveatsGroup1_ });
        caveatGroups_[1] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveatsGroup2_ });

        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ args: hex"", enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(caveatGroups_) });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
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

        // Enforcer allows to reuse the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();
        // Validate that the count has increased again
        assertEq(finalValue_, initialValue_ + 2);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(logicalOrWrapperEnforcer));
    }
}
