// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ExactCalldataEnforcer } from "../../src/enforcers/ExactCalldataEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ExactCalldataEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ExactCalldataEnforcer public exactCalldataEnforcer;
    BasicERC20 public basicCF20;

    ////////////////////////////// Setup //////////////////////////////
    function setUp() public override {
        super.setUp();
        exactCalldataEnforcer = new ExactCalldataEnforcer();
        vm.label(address(exactCalldataEnforcer), "Exact Calldata Enforcer");
        basicCF20 = new BasicERC20(address(users.alice.deleGator), "TestToken1", "TestToken1", 100 ether);
    }

    ////////////////////////////// Unit Tests //////////////////////////////

    /// @notice Test that the enforcer passes when the expected calldata exactly matches the executed calldata.
    function test_exactCalldataMatches() public {
        // Create an execution (for example, a mint on the ERC20 token)
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(100))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Use the exact callData as the expected terms
        bytes memory terms_ = execution_.callData;

        vm.prank(address(delegationManager));
        exactCalldataEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when the executed calldata does not exactly match the expected calldata.
    function test_exactCalldataFailsWhenMismatch() public {
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(100))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Terms to simulate a mismatch
        bytes memory terms_ = abi.encodeWithSelector(IERC20.transfer.selector, address(0), uint256(100));

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactCalldataEnforcer:invalid-calldata");
        exactCalldataEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer works correctly with a dynamic array parameter.
    function test_equalDynamicArrayParam() public {
        uint256[] memory param = new uint256[](2);
        param[0] = 1;
        param[1] = 2;
        Execution memory execution_ = Execution({
            target: address(0), // Dummy target for testing
            value: 0,
            callData: abi.encodeWithSelector(DummyContract.arrayFn.selector, param)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory terms_ = execution_.callData;

        vm.prank(address(delegationManager));
        exactCalldataEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer works correctly with a dynamic string parameter.
    function test_equalDynamicStringParam() public {
        string memory param_ = "Test string";
        Execution memory execution_ =
            Execution({ target: address(0), value: 0, callData: abi.encodeWithSelector(DummyContract.stringFn.selector, param_) });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory terms_ = execution_.callData;

        vm.prank(address(delegationManager));
        exactCalldataEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer passes when both expected and execution calldata are empty (ETH transfer).
    function test_emptyCalldataMatches() public {
        // Create an ETH transfer execution with empty calldata.
        Execution memory execution_ = Execution({ target: address(0x1234), value: 1 ether, callData: "" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        // Expected terms: empty calldata.
        bytes memory terms_ = "";

        vm.prank(address(delegationManager));
        exactCalldataEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when expected calldata is empty but execution calldata is non-empty.
    function test_emptyCalldataFailsWhenMismatch() public {
        // Create an ETH transfer execution with non-empty calldata.
        Execution memory execution_ = Execution({ target: address(0x1234), value: 1 ether, callData: hex"abcd" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        // Expected terms: empty calldata.
        bytes memory terms_ = "";

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactCalldataEnforcer:invalid-calldata");
        exactCalldataEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when batch-encoded execution calldata is provided.
    function test_batchEncodedExecutionReverts() public {
        // Batch encode the two executions.
        Execution[] memory executions_ = new Execution[](2);
        bytes memory batchEncodedCallData_ = ExecutionLib.encodeBatch(executions_);

        // Irrelevant because the batch decoding will fail)
        bytes memory terms_ = hex"";

        vm.prank(address(delegationManager));
        // Expect a revert because the enforcer calls decodeSingle() on batch encoded calldata.
        vm.expectRevert();
        exactCalldataEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, batchEncodedCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        exactCalldataEnforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        exactCalldataEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////////////// Integration Tests //////////////////////////////

    /// @notice Integration test: the enforcer allows a token transfer delegation when calldata matches exactly.
    function test_integration_AllowsTokenTransferWhenCalldataMatches() public {
        // Ensure Bob starts with a zero balance.
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(0));

        // Create an execution for a token transfer of 1 unit.
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether))
        });

        // Use the actual callData as the expected terms.
        bytes memory terms_ = execution_.callData;

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(exactCalldataEnforcer), terms: terms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Execute Bob's UserOp twice to demonstrate reusability.
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(1 ether));

        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(2 ether));
    }

    /// @notice Integration test: the enforcer blocks delegation execution when calldata does not match.
    function test_integration_BlocksTokenTransferWhenCalldataDiffers() public {
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(0));

        // Create an execution for a token transfer of 2 units.
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(2 ether))
        });

        // Use expected terms that differ (e.g. a valid callData for a transfer of 1 unit).
        bytes memory validCallData_ =
            abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether));
        bytes memory terms_ = validCallData_;

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(exactCalldataEnforcer), terms: terms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Verify that Bob's balance remains unchanged.
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(0));
    }

    /// @notice Integration test: ExactCalldataEnforcer allows ETH transfer when both expected and execution calldata are empty.
    function test_integration_AllowsETHTransferWhenEmptyCalldataMatches() public {
        // Record Carol's initial ETH balance.
        uint256 initialBalance = address(users.carol.deleGator).balance;

        // Create an execution for an ETH transfer with empty calldata and a non-zero value.
        Execution memory execution_ = Execution({
            target: address(users.carol.deleGator),
            value: 10 ether,
            callData: "" // Empty calldata for ETH transfer
         });
        // Expected terms: empty calldata.
        bytes memory terms_ = "";

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(exactCalldataEnforcer), terms: terms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Execute the delegation; Bob submits the UserOp.
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Verify that Carol's ETH balance increased by 10 ether.
        assertEq(address(users.carol.deleGator).balance, initialBalance + 10 ether);
    }

    /// @notice Integration test: ExactCalldataEnforcer blocks ETH transfer when expected calldata is empty but execution calldata
    /// is non-empty.
    function test_integration_BlocksETHTransferWhenEmptyCalldataDiffers() public {
        uint256 initialBalance_ = address(users.carol.deleGator).balance;

        // Create an execution for an ETH transfer with non-empty calldata.
        Execution memory execution_ = Execution({
            target: address(users.carol.deleGator),
            value: 1 ether,
            callData: hex"abcd" // Non-empty calldata
         });
        // Expected terms: empty calldata.
        bytes memory terms_ = "";

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(exactCalldataEnforcer), terms: terms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Expect the execution to revert due to calldata mismatch.
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Verify that Carol's ETH balance remains unchanged.
        assertEq(address(users.carol.deleGator).balance, initialBalance_);
    }

    ////////////////////////////// Internal Overrides //////////////////////////////
    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(exactCalldataEnforcer));
    }
}

/// @dev A dummy contract used for testing dynamic calldata parameters.
contract DummyContract {
    function arrayFn(uint256[] calldata _str) public { }
    function stringFn(string calldata _str) public { }
}
