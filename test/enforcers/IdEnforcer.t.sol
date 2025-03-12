// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import "../../src/utils/Types.sol";
import { Execution } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { IdEnforcer } from "../../src/enforcers/IdEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";

contract IdEnforcerEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    IdEnforcer public idEnforcer;
    BasicERC20 public testFToken1;
    address public redeemer = address(users.bob.deleGator);

    ////////////////////////////// Events //////////////////////////////

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        idEnforcer = new IdEnforcer();
        vm.label(address(idEnforcer), "Id Enforcer");
        testFToken1 = new BasicERC20(address(users.alice.deleGator), "TestToken1", "TestToken1", 100 ether);
    }

    // Validates the terms get decoded correctly
    function test_decodedTheTerms() public {
        uint256 id_ = type(uint256).max;
        bytes memory terms_ = abi.encode(id_);
        assertEq(idEnforcer.getTermsInfo(terms_), id_);
    }

    // Validates that the enforcer reverts and returns false once reusing the nonce
    function test_blocksDelegationWithRepeatedNonce() public {
        Execution memory execution_;
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        uint256 id_ = uint256(123456789);
        bytes memory terms_ = abi.encode(id_);
        address delegator_ = address(users.alice.deleGator);

        vm.startPrank(address(delegationManager));

        // Before the first usage the enforcer the nonce is not used.
        assertFalse(idEnforcer.getIsUsed(address(delegationManager), delegator_, id_));

        // First usage works well
        vm.expectEmit(true, true, true, true, address(idEnforcer));
        emit IdEnforcer.UsedId(address(delegationManager), delegator_, redeemer, id_);
        idEnforcer.beforeHook(terms_, hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator_, redeemer);

        // After the first usage the enforcer marks the nonce as used.
        assertTrue(idEnforcer.getIsUsed(address(delegationManager), delegator_, id_));

        // Second usage reverts, and returns false.
        vm.expectRevert("IdEnforcer:id-already-used");

        idEnforcer.beforeHook(terms_, hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator_, redeemer);
    }

    // should FAIL to INVOKE with invalid input terms
    function test_methodFailsIfCalledWithInvalidInputTerms() public {
        Execution memory execution_;
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory terms_ = abi.encodePacked(uint32(1));
        vm.expectRevert("IdEnforcer:invalid-terms-length");
        idEnforcer.beforeHook(terms_, hex"", singleDefaultMode, executionCallData_, bytes32(0), address(0), redeemer);

        terms_ = abi.encodePacked(uint256(1), uint256(1));
        vm.expectRevert("IdEnforcer:invalid-terms-length");
        idEnforcer.beforeHook(terms_, hex"", singleDefaultMode, executionCallData_, bytes32(0), address(0), redeemer);
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        idEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    //////////////////////  Integration  //////////////////////

    // Should revert to use a delegation which nonce has already been used
    function test_methodFailsIfNonceAlreadyUsed() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        bytes memory inputTerms_ = abi.encode(uint256(12345));

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(idEnforcer), terms: inputTerms_ });
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
        // Validate that the count has increased by 1
        assertEq(aliceDeleGatorCounter.count(), initialValue_ + 1);

        // Enforcer blocks the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        // Validate that the count has not increased by 1
        assertEq(aliceDeleGatorCounter.count(), initialValue_ + 1);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(idEnforcer));
    }
}
