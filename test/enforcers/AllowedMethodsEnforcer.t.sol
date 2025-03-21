// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract AllowedMethodsEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////

    AllowedMethodsEnforcer public allowedMethodsEnforcer;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        vm.label(address(allowedMethodsEnforcer), "Allowed Methods Enforcer");
    }

    ////////////////////// Valid cases //////////////////////

    // should allow a method to be called when a single method is allowed
    function test_singleMethodCanBeCalled() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        allowedMethodsEnforcer.beforeHook(
            abi.encodePacked(Counter.increment.selector),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    // should allow a method to be called when a multiple methods are allowed
    function test_multiMethodCanBeCalled() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        allowedMethodsEnforcer.beforeHook(
            abi.encodePacked(Counter.setCount.selector, Ownable.renounceOwnership.selector, Counter.increment.selector),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to get terms info when passing an invalid terms length
    function test_getTermsInfoFailsForInvalidLength() public {
        // 0 bytes
        vm.expectRevert("AllowedMethodsEnforcer:invalid-terms-length");
        allowedMethodsEnforcer.getTermsInfo(hex"");

        // Less than 4 bytes
        vm.expectRevert("AllowedMethodsEnforcer:invalid-terms-length");
        allowedMethodsEnforcer.getTermsInfo(bytes("1"));
    }

    // should FAIL if execution.callData length < 4
    function test_notAllow_invalidExecutionLength() public {
        // Create the execution that would be executed
        Execution memory execution_ =
            Execution({ target: address(aliceDeleGatorCounter), value: 0, callData: abi.encodePacked(true) });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        vm.expectRevert("AllowedMethodsEnforcer:invalid-execution-data-length");
        allowedMethodsEnforcer.beforeHook(
            abi.encodePacked(Counter.setCount.selector, Ownable.renounceOwnership.selector, Ownable.owner.selector),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    // should NOT allow a method to be called when the method is not allowed
    function test_onlyApprovedMethodsCanBeCalled() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        vm.expectRevert("AllowedMethodsEnforcer:method-not-allowed");
        allowedMethodsEnforcer.beforeHook(
            abi.encodePacked(Counter.setCount.selector, Ownable.renounceOwnership.selector, Ownable.owner.selector),
            hex"",
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

        allowedMethodsEnforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        allowedMethodsEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    // should allow a method to be called when a single method is allowed Integration
    function test_methodCanBeSingleMethodIntegration() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(Counter.increment.selector) });
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

        // Enforcer allows to reuse the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();
        // Validate that the count has increased again
        assertEq(finalValue_, initialValue_ + 2);
    }

    // should NOT allow a method to be called when the method is not allowed Integration
    function test_onlyApprovedMethodsCanBeCalledIntegration() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(allowedMethodsEnforcer),
            terms: abi.encodePacked(Counter.setCount.selector, Ownable.renounceOwnership.selector, Ownable.owner.selector)
        });
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
        // Get final count
        uint256 valueAfter_ = aliceDeleGatorCounter.count();
        // Validate that the count has not changed
        assertEq(valueAfter_, initialValue_);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(allowedMethodsEnforcer));
    }
}
