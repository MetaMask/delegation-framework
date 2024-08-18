// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import { Action, Caveat, Delegation } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";

contract AllowedTargetsEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    BasicERC20 public testFToken1;
    BasicERC20 public testFToken2;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        testFToken1 = new BasicERC20(address(users.alice.deleGator), "TestToken1", "TestToken1", 100 ether);
        testFToken2 = new BasicERC20(address(users.alice.deleGator), "TestToken2", "TestToken2", 100 ether);
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");
    }

    ////////////////////// Valid cases //////////////////////

    // should allow a method to be called when a single target is allowed
    function test_singleTargetCanBeCalled() public {
        // Create the action that would be executed
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        allowedTargetsEnforcer.beforeHook(
            abi.encodePacked(address(aliceDeleGatorCounter)), hex"", action_, keccak256(""), address(0), address(0)
        );
    }

    // should allow a method to be called when a multiple targets are allowed
    function test_multiTargetCanBeCalled() public {
        // Create the action that would be executed
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        allowedTargetsEnforcer.beforeHook(
            abi.encodePacked(address(bobDeleGatorCounter), address(carolDeleGatorCounter), address(aliceDeleGatorCounter)),
            hex"",
            action_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to get terms info when passing an invalid terms length
    function test_getTermsInfoFailsForInvalidLength() public {
        vm.expectRevert("AllowedTargetsEnforcer:invalid-terms-length");
        allowedTargetsEnforcer.getTermsInfo(bytes("1"));
    }

    // should NOT allow a method to be called when the target is not allowed
    function test_onlyApprovedTargetsCanBeCalled() public {
        // Create the action that would be executed
        Action memory action_ =
            Action({ to: address(daveDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // beforeHook, mimicking the behavior of Dave's DeleGator
        vm.prank(address(delegationManager));
        vm.expectRevert("AllowedTargetsEnforcer:target-address-not-allowed");
        allowedTargetsEnforcer.beforeHook(
            abi.encodePacked(address(bobDeleGatorCounter), address(carolDeleGatorCounter), address(aliceDeleGatorCounter)),
            hex"",
            action_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    ////////////////////// Integration //////////////////////

    // should allow a method to be called when a multiple targets are allowed Integration
    function test_multiTargetCanBeCalledIntegration() public {
        assertEq(aliceDeleGatorCounter.count(), 0);
        assertEq(testFToken1.balanceOf(address(users.bob.deleGator)), 0);

        // Create the action that would be executed on Alice for incrementing the count
        Action memory action1_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Create the action that would be executed on Alice for transferring a ft tokens
        Action memory action2_ = Action({
            to: address(testFToken1),
            value: 0,
            data: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 1 ether)
        });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(aliceDeleGatorCounter), address(testFToken1))
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
        invokeDelegation_UserOp(users.bob, delegations_, action1_);
        invokeDelegation_UserOp(users.bob, delegations_, action2_);

        // Validate that the count and balance have increased
        assertEq(aliceDeleGatorCounter.count(), 1);
        assertEq(testFToken1.balanceOf(address(users.bob.deleGator)), 1 ether);

        // Enforcer allows to reuse the delegation
        invokeDelegation_UserOp(users.bob, delegations_, action1_);
        invokeDelegation_UserOp(users.bob, delegations_, action2_);

        // Validate that the count and balance has increased again
        assertEq(aliceDeleGatorCounter.count(), 2);
        assertEq(testFToken1.balanceOf(address(users.bob.deleGator)), 2 ether);
    }

    // should NOT allow a method to be called when the method is not allowed Integration
    function test_onlyApprovedMethodsCanBeCalledIntegration() public {
        assertEq(testFToken1.balanceOf(address(users.bob.deleGator)), 0);
        assertEq(testFToken2.balanceOf(address(users.bob.deleGator)), 0);

        // Create the action that would be executed on Alice for transferring FToken2
        Action memory action_ = Action({
            to: address(testFToken2),
            value: 0,
            data: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 1 ether)
        });

        // Approving the user to use the FToken1
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(testFToken1)) });
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
        invokeDelegation_UserOp(users.bob, delegations_, action_);

        // Validate that the balances on both FTokens has not increased
        assertEq(testFToken1.balanceOf(address(users.bob.deleGator)), 0);
        assertEq(testFToken2.balanceOf(address(users.bob.deleGator)), 0);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(allowedTargetsEnforcer));
    }
}
