// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ExactCalldataBatchEnforcer } from "../../src/enforcers/ExactCalldataBatchEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ExactCalldataBatchEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ExactCalldataBatchEnforcer public exactCalldataBatchEnforcer;
    BasicERC20 public basicCF20;

    ////////////////////////////// Setup //////////////////////////////
    function setUp() public override {
        super.setUp();
        exactCalldataBatchEnforcer = new ExactCalldataBatchEnforcer();
        vm.label(address(exactCalldataBatchEnforcer), "Exact Calldata Batch Enforcer");
        basicCF20 = new BasicERC20(address(users.alice.deleGator), "TestToken1", "TestToken1", 100 ether);
    }

    ////////////////////////////// Unit Tests //////////////////////////////

    /// @notice Test that the enforcer passes when all calldata in the batch matches exactly.
    function test_exactCalldataMatches() public {
        // Create a batch of executions
        Execution[] memory executions_ = new Execution[](2);

        // First execution: transfer tokens
        executions_[0] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether))
        });

        // Second execution: transfer more tokens
        executions_[1] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.carol.deleGator), uint256(2 ether))
        });

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        // Create terms that match exactly
        bytes memory terms_ = _encodeTerms(executions_);

        vm.prank(address(delegationManager));
        exactCalldataBatchEnforcer.beforeHook(
            terms_, hex"", batchDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when any calldata in the batch doesn't match.
    function test_exactCalldataFailsWhenMismatch() public {
        // Create a batch of executions
        Execution[] memory executions_ = new Execution[](2);

        // First execution: transfer tokens
        executions_[0] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether))
        });

        // Second execution: transfer more tokens
        executions_[1] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.carol.deleGator), uint256(2 ether))
        });

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        // Create terms with a mismatch in the second execution
        Execution[] memory termsExecutions_ = new Execution[](2);
        termsExecutions_[0] = executions_[0];
        termsExecutions_[1] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.carol.deleGator), uint256(3 ether))
        });

        bytes memory terms_ = _encodeTerms(termsExecutions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactCalldataBatchEnforcer:invalid-calldata");
        exactCalldataBatchEnforcer.beforeHook(
            terms_, hex"", batchDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when batch size doesn't match.
    function test_batchSizeMismatch() public {
        // Create a batch of executions
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether))
        });
        executions_[1] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.carol.deleGator), uint256(2 ether))
        });

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        // Create terms with only one execution
        Execution[] memory termsExecutions_ = new Execution[](1);
        termsExecutions_[0] = executions_[0];

        bytes memory terms_ = _encodeTerms(termsExecutions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactCalldataBatchEnforcer:invalid-batch-size");
        exactCalldataBatchEnforcer.beforeHook(
            terms_, hex"", batchDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when single mode is used.
    function test_singleModeReverts() public {
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether))
        });
        executions_[1] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.carol.deleGator), uint256(2 ether))
        });

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);
        bytes memory terms_ = _encodeTerms(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        exactCalldataBatchEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should fail with invalid call type mode (single mode instead of batch)
    function test_revertWithInvalidCallTypeMode() public {
        Execution[] memory executions_ = new Execution[](2);
        bytes memory terms_ = _encodeTerms(executions_);

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        exactCalldataBatchEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256("test"), address(0), address(0)
        );
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        Execution[] memory executions_ = new Execution[](2);
        bytes memory terms_ = _encodeTerms(executions_);

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        exactCalldataBatchEnforcer.beforeHook(
            terms_, hex"", batchTryMode, executionCallData_, keccak256("test"), address(0), address(0)
        );
    }

    ////////////////////////////// Integration Tests //////////////////////////////

    /// @notice Integration test: the enforcer allows a batch of token transfers when calldata matches exactly.
    function test_integration_AllowsBatchTokenTransfers() public {
        // Record initial balances
        uint256 bobInitialBalance_ = basicCF20.balanceOf(address(users.bob.deleGator));
        uint256 carolInitialBalance_ = basicCF20.balanceOf(address(users.carol.deleGator));

        // Create a batch of executions
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether))
        });
        executions_[1] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.carol.deleGator), uint256(2 ether))
        });

        // Create terms that match exactly
        bytes memory terms_ = _encodeTerms(executions_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(exactCalldataBatchEnforcer), terms: terms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        // Prepare delegation redemption parameters
        bytes[] memory permissionContexts_ = new bytes[](1);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeBatch(executions_);

        // Set up batch mode
        ModeCode[] memory oneBatchMode_ = new ModeCode[](1);
        oneBatchMode_[0] = batchDefaultMode;

        // Bob redeems the delegation to execute the batch
        vm.prank(address(users.bob.deleGator));
        delegationManager.redeemDelegations(permissionContexts_, oneBatchMode_, executionCallDatas_);

        // Verify balances changed correctly
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), bobInitialBalance_ + 1 ether);
        assertEq(basicCF20.balanceOf(address(users.carol.deleGator)), carolInitialBalance_ + 2 ether);
    }

    /// @notice Integration test: the enforcer blocks batch execution when any calldata doesn't match.
    function test_integration_BlocksBatchWhenCalldataDiffers() public {
        // Record initial balances
        uint256 bobInitialBalance_ = basicCF20.balanceOf(address(users.bob.deleGator));
        uint256 carolInitialBalance_ = basicCF20.balanceOf(address(users.carol.deleGator));

        // Create a batch of executions
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether))
        });
        executions_[1] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.carol.deleGator), uint256(2 ether))
        });

        // Create terms with a mismatch in the second execution
        Execution[] memory termsExecutions_ = new Execution[](2);
        termsExecutions_[0] = executions_[0];
        termsExecutions_[1] = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.carol.deleGator), uint256(3 ether))
        });

        bytes memory terms_ = _encodeTerms(termsExecutions_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(exactCalldataBatchEnforcer), terms: terms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        // Prepare delegation redemption parameters
        bytes[] memory permissionContexts_ = new bytes[](1);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeBatch(executions_);

        // Set up batch mode
        ModeCode[] memory oneBatchMode_ = new ModeCode[](1);
        oneBatchMode_[0] = batchDefaultMode;

        // Bob redeems the delegation to execute the batch
        vm.prank(address(users.bob.deleGator));
        vm.expectRevert("ExactCalldataBatchEnforcer:invalid-calldata");
        delegationManager.redeemDelegations(permissionContexts_, oneBatchMode_, executionCallDatas_);

        // Verify balances remain unchanged
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), bobInitialBalance_);
        assertEq(basicCF20.balanceOf(address(users.carol.deleGator)), carolInitialBalance_);
    }

    ////////////////////////////// Helper Functions //////////////////////////////

    /// @notice Helper function to encode terms for the batch enforcer
    function _encodeTerms(Execution[] memory _executions) internal pure returns (bytes memory) {
        return ExecutionLib.encodeBatch(_executions);
    }

    ////////////////////////////// Internal Overrides //////////////////////////////
    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(exactCalldataBatchEnforcer));
    }
}
