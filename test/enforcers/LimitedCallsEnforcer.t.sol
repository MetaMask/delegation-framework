// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import "../../src/utils/Types.sol";
import { Execution } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { LimitedCallsEnforcer } from "../../src/enforcers/LimitedCallsEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract LimitedCallsEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// Events //////////////////////////////
    event IncreasedCount(
        address indexed sender, address indexed redeemer, bytes32 indexed delegationHash, uint256 limit, uint256 callCount
    );

    ////////////////////// State //////////////////////

    LimitedCallsEnforcer public limitedCallsEnforcer;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        vm.label(address(limitedCallsEnforcer), "Limited Calls Enforcer");
    }

    ////////////////////// Valid cases //////////////////////

    // should SUCCEED to INVOKE method BELOW limit number
    function test_methodCanBeCalledBelowLimitNumber() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint256 transactionsLimit_ = 1;
        bytes memory inputTerms_ = abi.encodePacked(transactionsLimit_);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(limitedCallsEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(limitedCallsEnforcer.callCounts(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(limitedCallsEnforcer));
        emit IncreasedCount(address(delegationManager), address(0), delegationHash_, 1, 1);
        limitedCallsEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(limitedCallsEnforcer.callCounts(address(delegationManager), delegationHash_), transactionsLimit_);
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to INVOKE method ABOVE limit number
    function test_methodFailsIfCalledAboveLimitNumber() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint256 transactionsLimit_ = 1;
        bytes memory inputTerms_ = abi.encodePacked(transactionsLimit_);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(limitedCallsEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(limitedCallsEnforcer.callCounts(address(delegationManager), delegationHash_), 0);
        vm.startPrank(address(delegationManager));
        limitedCallsEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        vm.expectRevert("LimitedCallsEnforcer:limit-exceeded");
        limitedCallsEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(limitedCallsEnforcer.callCounts(address(delegationManager), delegationHash_), transactionsLimit_);
    }

    // should FAIL to INVOKE with invalid input terms
    function test_methodFailsIfCalledWithInvalidInputTerms() public {
        Execution memory execution_;
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory terms_ = abi.encodePacked(uint32(1));
        vm.expectRevert("LimitedCallsEnforcer:invalid-terms-length");
        limitedCallsEnforcer.beforeHook(terms_, hex"", singleDefaultMode, executionCallData_, bytes32(0), address(0), address(0));

        terms_ = abi.encodePacked(uint256(1), uint256(1));
        vm.expectRevert("LimitedCallsEnforcer:invalid-terms-length");
        limitedCallsEnforcer.beforeHook(terms_, hex"", singleDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        limitedCallsEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    // should FAIL to increment counter ABOVE limit number Integration
    function test_methodFailsAboveLimitIntegration() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory inputTerms_ = abi.encodePacked(uint256(1));
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(limitedCallsEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(limitedCallsEnforcer.callCounts(address(delegationManager), delegationHash_), 0);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Validate that the count has increased by 1
        uint256 valueAfter_ = aliceDeleGatorCounter.count();
        assertEq(valueAfter_, initialValue_ + 1);

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Validate that the count has not increased
        assertEq(aliceDeleGatorCounter.count(), valueAfter_);
        assertEq(limitedCallsEnforcer.callCounts(address(delegationManager), delegationHash_), 1);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(limitedCallsEnforcer));
    }
}
