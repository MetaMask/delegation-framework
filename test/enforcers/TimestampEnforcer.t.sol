// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { TimestampEnforcer } from "../../src/enforcers/TimestampEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { DelegationManager } from "../../src/DelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract TimestampEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////

    TimestampEnforcer public timestampEnforcer;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        timestampEnforcer = new TimestampEnforcer();
        vm.label(address(timestampEnforcer), "Timestamp Enforcer");
    }

    ////////////////////// Valid cases //////////////////////

    // should SUCCEED to INVOKE method AFTER timestamp reached
    function test_methodCanBeCalledAfterTimestamp() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        skip(1 hours); // Increase time 1 hour
        uint128 timestampAfterThreshold_ = 1; // Minimum timestamp
        uint128 timestampBeforeThreshold_ = 0; // Not using before threshold
        bytes memory inputTerms_ = abi.encodePacked(timestampAfterThreshold_, timestampBeforeThreshold_);
        vm.prank(address(delegationManager));
        timestampEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should SUCCEED to INVOKE method BEFORE timestamp reached
    function test_methodCanBeCalledBeforeTimestamp() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 timestampAfterThreshold_ = 0; //  Not using after threshold
        uint128 timestampBeforeThreshold_ = uint128(block.timestamp + 1 hours);
        bytes memory inputTerms_ = abi.encodePacked(timestampAfterThreshold_, timestampBeforeThreshold_);
        vm.prank(address(delegationManager));
        timestampEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should SUCCEED to INVOKE method inside of timestamp RANGE
    function test_methodCanBeCalledInsideTimestampRange() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 timestampAfterThreshold_ = 1; // Minimum timestamp
        uint128 timestampBeforeThreshold_ = uint128(block.timestamp + 1 hours);
        skip(1 minutes); // Increase time 1 minute
        bytes memory inputTerms_ = abi.encodePacked(timestampAfterThreshold_, timestampBeforeThreshold_);
        vm.prank(address(delegationManager));
        timestampEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to INVOKE method BEFORE timestamp reached
    function test_methodFailsIfCalledTimestamp() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 timestampAfterThreshold_ = uint128(block.timestamp + 1 hours);
        uint128 timestampBeforeThreshold_ = 0; // Not using before threshold
        bytes memory inputTerms_ = abi.encodePacked(timestampAfterThreshold_, timestampBeforeThreshold_);
        vm.prank(address(delegationManager));
        vm.expectRevert("TimestampEnforcer:early-delegation");

        timestampEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should FAIL to INVOKE method AFTER timestamp reached
    function test_methodFailsIfCalledAfterTimestamp() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 timestampAfterThreshold_ = 0; //  Not using after threshold
        uint128 timestampBeforeThreshold_ = uint128(block.timestamp);
        skip(1 hours); // Increase time 1 hour
        bytes memory inputTerms_ = abi.encodePacked(timestampAfterThreshold_, timestampBeforeThreshold_);
        vm.prank(address(delegationManager));
        vm.expectRevert("TimestampEnforcer:expired-delegation");
        timestampEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should FAIL to INVOKE method BEFORE timestamp RANGE
    function test_methodFailsIfCalledBeforeTimestampRange() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 timestampAfterThreshold_ = uint128(block.timestamp + 1 hours);
        uint128 timestampBeforeThreshold_ = uint128(block.timestamp + 2 hours);
        bytes memory inputTerms_ = abi.encodePacked(timestampAfterThreshold_, timestampBeforeThreshold_);
        vm.prank(address(delegationManager));
        vm.expectRevert("TimestampEnforcer:early-delegation");
        timestampEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should FAIL to INVOKE method AFTER timestamp RANGE
    function test_methodFailsIfCalledAfterTimestampRange() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 timestampAfterThreshold_ = uint128(block.timestamp + 1 hours);
        uint128 timestampBeforeThreshold_ = uint128(block.timestamp + 2 hours);
        skip(3 hours); // Increase time 3 hours
        bytes memory inputTerms_ = abi.encodePacked(timestampAfterThreshold_, timestampBeforeThreshold_);
        vm.prank(address(delegationManager));
        vm.expectRevert("TimestampEnforcer:expired-delegation");
        timestampEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should FAIL to INVOKE with invalid input terms
    function test_methodFailsIfCalledWithInvalidInputTerms() public {
        Execution memory execution_;
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory terms_ = abi.encodePacked(uint32(1));
        vm.expectRevert("TimestampEnforcer:invalid-terms-length");
        timestampEnforcer.beforeHook(terms_, hex"", singleDefaultMode, executionCallData_, bytes32(0), address(0), address(0));

        terms_ = abi.encodePacked(uint256(1), uint256(1));
        vm.expectRevert("TimestampEnforcer:invalid-terms-length");
        timestampEnforcer.beforeHook(terms_, hex"", singleDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }
    ////////////////////// Integration //////////////////////

    // should SUCCEED to INVOKE until reaching timestamp Integration
    function test_methodCanBeCalledAfterTimestampIntegration() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        skip(10); // Increase time 10 seconds
        // Not using before threshold (timestampAfterThreshold_ = 1, timestampBeforeThreshold_ = 100)
        bytes memory inputTerms_ = abi.encodePacked(uint128(1), uint128(100));

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(timestampEnforcer), terms: inputTerms_ });
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation;

        // Enforcer allows the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Get final count
        uint256 valueAfter_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(valueAfter_, initialValue_ + 1);

        // Enforcer blocks the delegation
        skip(100); // Increase time 100 seconds
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();
        // Validate that the count has not increased by 1
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        timestampEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(timestampEnforcer));
    }
}
