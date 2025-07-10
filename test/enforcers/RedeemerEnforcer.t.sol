// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract RedeemerEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    RedeemerEnforcer public redeemerEnforcer;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        redeemerEnforcer = new RedeemerEnforcer();
        vm.label(address(redeemerEnforcer), "Redeemer Enforcer");
    }

    ////////////////////// Valid cases //////////////////////

    // should SUCCEED to get terms info when passing valid terms
    function test_decodeTermsInfo() public {
        bytes memory terms_ = abi.encodePacked(address(users.alice.deleGator), address(users.bob.deleGator));
        address[] memory allowedRedeemers_ = redeemerEnforcer.getTermsInfo(terms_);
        assertEq(allowedRedeemers_[0], address(users.alice.deleGator));
        assertEq(allowedRedeemers_[1], address(users.bob.deleGator));
    }

    // should pass if called from a single valid redeemer
    function test_validSingleRedeemerCanExecute() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory terms_ = abi.encodePacked(address(users.bob.deleGator));
        vm.prank(address(delegationManager));
        redeemerEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(users.bob.deleGator)
        );
    }

    // should pass if called from multiple valid redeemers
    function test_validMultipleRedeemersCanExecute() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory terms_ = abi.encodePacked(address(users.alice.deleGator), address(users.bob.deleGator));
        vm.startPrank(address(delegationManager));
        redeemerEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(users.alice.deleGator)
        );
        redeemerEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(users.bob.deleGator)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to get terms info when passing an invalid terms length
    function test_getTermsInfoFailsForInvalidLength() public {
        vm.expectRevert("RedeemerEnforcer:invalid-terms-length");
        redeemerEnforcer.getTermsInfo(bytes("1"));
    }

    // should revert if called from an invalid redeemer
    function test_revertWithInvalidRedeemer() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory terms_ = abi.encodePacked(address(users.bob.deleGator));
        vm.prank(address(delegationManager));
        // Dave is not a valid redeemer
        vm.expectRevert("RedeemerEnforcer:unauthorized-redeemer");
        redeemerEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(users.dave.deleGator)
        );
    }

    // should revert with invalid terms length
    function test_revertWithInvalidTerms() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory invalidTerms_ = abi.encodePacked(uint8(1));
        vm.prank(address(delegationManager));
        vm.expectRevert("RedeemerEnforcer:invalid-terms-length");
        redeemerEnforcer.beforeHook(
            invalidTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(users.bob.deleGator)
        );
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        redeemerEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(redeemerEnforcer));
    }
}
