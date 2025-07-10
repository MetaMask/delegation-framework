// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ExactExecutionEnforcer } from "../../src/enforcers/ExactExecutionEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

contract ExactExecutionEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ExactExecutionEnforcer public exactExecutionEnforcer;
    BasicERC20 public basicCF20;

    ////////////////////////////// Setup //////////////////////////////
    function setUp() public override {
        super.setUp();
        exactExecutionEnforcer = new ExactExecutionEnforcer();
        vm.label(address(exactExecutionEnforcer), "Exact Execution Enforcer");
        basicCF20 = new BasicERC20(address(users.alice.deleGator), "TestToken1", "TestToken1", 100 ether);
    }

    ////////////////////////////// Unit Tests //////////////////////////////

    /// @notice Test that the enforcer passes when the execution matches exactly.
    function test_exactExecutionMatches() public {
        // Create an execution
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 1 ether,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(10 ether))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Use the exact execution as terms
        bytes memory terms_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        exactExecutionEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when the target doesn't match.
    function test_exactExecutionFailsWhenTargetDiffers() public {
        // Create an execution
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 1 ether,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(10 ether))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create terms with a different target
        bytes memory terms_ = ExecutionLib.encodeSingle(address(users.bob.deleGator), execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactExecutionEnforcer:invalid-execution");
        exactExecutionEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when the value doesn't match.
    function test_exactExecutionFailsWhenValueDiffers() public {
        // Create an execution
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 1 ether,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(10 ether))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create terms with a different value
        bytes memory terms_ = ExecutionLib.encodeSingle(execution_.target, 2 ether, execution_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactExecutionEnforcer:invalid-execution");
        exactExecutionEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when the calldata doesn't match.
    function test_exactExecutionFailsWhenCalldataDiffers() public {
        // Create an execution
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 1 ether,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(10 ether))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create terms with different calldata
        bytes memory differentCalldata_ =
            abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(20 ether));
        bytes memory terms_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, differentCalldata_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactExecutionEnforcer:invalid-execution");
        exactExecutionEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when batch mode is used.
    function test_batchModeReverts() public {
        // Create an execution
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 1 ether,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(10 ether))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory terms_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        exactExecutionEnforcer.beforeHook(
            terms_, hex"", batchDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        exactExecutionEnforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        exactExecutionEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////////////// Integration Tests //////////////////////////////

    /// @notice Integration test: the enforcer allows a token transfer when execution matches exactly.
    function test_integration_AllowsTokenTransferWhenExecutionMatches() public {
        // Ensure Bob starts with a zero balance
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(0));

        // Create an execution for a token transfer
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether))
        });

        // Use the exact execution as terms
        bytes memory terms_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(exactExecutionEnforcer), terms: terms_ });
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

        // Execute Bob's UserOp
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Verify Bob's balance increased
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(1 ether));
    }

    /// @notice Integration test: the enforcer blocks token transfer when execution doesn't match.
    function test_integration_BlocksTokenTransferWhenExecutionDiffers() public {
        // Ensure Bob starts with a zero balance
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(0));

        // Create an execution with value=1 ether
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 1 ether, // Non-zero value
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether))
        });

        // Create terms with value=0
        bytes memory terms_ = ExecutionLib.encodeSingle(execution_.target, 0, execution_.callData);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(exactExecutionEnforcer), terms: terms_ });
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

        // Execute Bob's UserOp
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Verify Bob's balance remains unchanged
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(0));
    }

    /// @notice Integration test: the enforcer allows ETH transfer when execution matches exactly.
    function test_integration_AllowsETHTransferWhenExecutionMatches() public {
        // Record Carol's initial ETH balance
        uint256 initialBalance_ = address(users.carol.deleGator).balance;

        // Create an execution for an ETH transfer
        Execution memory execution_ = Execution({
            target: address(users.carol.deleGator),
            value: 1 ether,
            callData: "" // Empty calldata for ETH transfer
         });

        // Use the exact execution as terms
        bytes memory terms_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(exactExecutionEnforcer), terms: terms_ });
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

        // Execute Bob's UserOp
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Verify Carol's ETH balance increased
        assertEq(address(users.carol.deleGator).balance, initialBalance_ + 1 ether);
    }

    ////////////////////////////// Internal Overrides //////////////////////////////
    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(exactExecutionEnforcer));
    }
}
