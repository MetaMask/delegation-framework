// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { BlockNumberEnforcer } from "../../src/enforcers/BlockNumberEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract BlockNumberEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////

    BlockNumberEnforcer public blockNumberEnforcer;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        blockNumberEnforcer = new BlockNumberEnforcer();
        vm.label(address(blockNumberEnforcer), "Block Number Enforcer");
    }

    ////////////////////// Valid cases //////////////////////

    // should SUCCEED to INVOKE method AFTER blockNumber reached
    function test_methodCanBeCalledAfterBlockNumber() public {
        // Create the execution_ that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.roll(10000);
        uint128 blockAfterThreshold_ = 1;
        uint128 blockBeforeThreshold_ = 0; // Not using before threshold
        bytes memory inputTerms_ = abi.encodePacked(blockAfterThreshold_, blockBeforeThreshold_);
        vm.prank(address(delegationManager));
        blockNumberEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    //should SUCCEED to INVOKE method BEFORE blockNumber reached
    function test_methodCanBeCalledBeforeBlockNumber() public {
        // Create the execution_ that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 blockAfterThreshold_ = 0; //  Not using after threshold
        uint128 blockBeforeThreshold_ = uint128(block.number + 10000);
        bytes memory inputTerms_ = abi.encodePacked(blockAfterThreshold_, blockBeforeThreshold_);
        vm.prank(address(delegationManager));
        blockNumberEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should SUCCEED to INVOKE method inside blockNumber RANGE
    function test_methodCanBeCalledInsideBlockNumberRange() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 blockAfterThreshold_ = 1;
        uint128 blockBeforeThreshold_ = uint128(block.number + 10000);
        vm.roll(1000); // making block number between 1 and 10001
        bytes memory inputTerms_ = abi.encodePacked(blockAfterThreshold_, blockBeforeThreshold_);
        vm.prank(address(delegationManager));
        blockNumberEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to get terms info when passing an invalid terms length
    function test_getTermsInfoFailsForInvalidLength() public {
        vm.expectRevert("BlockNumberEnforcer:invalid-terms-length");
        blockNumberEnforcer.getTermsInfo(hex"");
    }

    // should FAIL to INVOKE method BEFORE blockNumber reached
    function test_methodFailsIfCalledBeforeBlockNumber() public {
        // Create the execution_ that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 blockAfterThreshold_ = uint128(block.number + 10000);
        uint128 blockBeforeThreshold_ = 0; // Not using before threshold
        bytes memory inputTerms_ = abi.encodePacked(blockAfterThreshold_, blockBeforeThreshold_);
        vm.prank(address(delegationManager));
        vm.expectRevert("BlockNumberEnforcer:early-delegation");

        blockNumberEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should FAIL to INVOKE method AFTER blockNumber reached
    function test_methodFailsIfCalledAfterBlockNumber() public {
        // Create the execution_ that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 blockAfterThreshold_ = 0; //  Not using after threshold
        uint128 blockBeforeThreshold_ = uint128(block.number);
        vm.roll(10000);
        bytes memory inputTerms_ = abi.encodePacked(blockAfterThreshold_, blockBeforeThreshold_);
        vm.prank(address(delegationManager));
        vm.expectRevert("BlockNumberEnforcer:expired-delegation");

        blockNumberEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should FAIL to INVOKE method BEFORE blocknumber RANGE
    function test_methodFailsIfCalledBeforeBlockNumberRange() public {
        // Create the execution_ that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 blockAfterThreshold_ = uint128(block.number + 10000);
        uint128 blockBeforeThreshold_ = uint128(block.number + 20000);
        bytes memory inputTerms_ = abi.encodePacked(blockAfterThreshold_, blockBeforeThreshold_);
        vm.prank(address(delegationManager));
        vm.expectRevert("BlockNumberEnforcer:early-delegation");

        blockNumberEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should FAIL to INVOKE method AFTER blocknumber RANGE"
    function test_methodFailsIfCalledAfterBlockNumberRange() public {
        // Create the execution_ that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 blockAfterThreshold_ = uint128(block.number + 10000);
        uint128 blockBeforeThreshold_ = uint128(block.number + 20000);
        vm.roll(30000);
        bytes memory inputTerms_ = abi.encodePacked(blockAfterThreshold_, blockBeforeThreshold_);
        vm.prank(address(delegationManager));
        vm.expectRevert("BlockNumberEnforcer:expired-delegation");

        blockNumberEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        blockNumberEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    // should SUCCEED to INVOKE until reaching blockNumber
    function test_methodCanBeCalledAfterBlockNumberIntegration() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();
        // Create the execution_ that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        vm.roll(10);
        // Not using before threshold (blockAfterThreshold_ = 1, blockBeforeThreshold_ = 100)
        bytes memory inputTerms_ = abi.encodePacked(uint128(1), uint128(100));

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(blockNumberEnforcer), terms: inputTerms_ });
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
        vm.roll(100);
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();
        // Validate that the count has not increased by 1
        assertEq(finalValue_, initialValue_ + 1);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(blockNumberEnforcer));
    }
}
