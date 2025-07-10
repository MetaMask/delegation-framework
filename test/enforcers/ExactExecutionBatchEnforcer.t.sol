// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ExactExecutionBatchEnforcer } from "../../src/enforcers/ExactExecutionBatchEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

contract ExactExecutionBatchEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////

    ExactExecutionBatchEnforcer public exactExecutionBatchEnforcer;
    BasicERC20 public basicCF20;

    ////////////////////////////// Set up //////////////////////////////

    function setUp() public override {
        super.setUp();
        exactExecutionBatchEnforcer = new ExactExecutionBatchEnforcer();
        vm.label(address(exactExecutionBatchEnforcer), "Exact Execution Batch Enforcer");
        basicCF20 = new BasicERC20(address(users.alice.deleGator), "TestToken1", "TestToken1", 100 ether);
    }

    ////////////////////////////// Valid cases //////////////////////////////

    /// @notice Test that the enforcer passes when all executions match exactly.
    function test_exactExecutionMatches() public {
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
        exactExecutionBatchEnforcer.beforeHook(
            terms_, hex"", batchDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    ////////////////////////////// Invalid cases //////////////////////////////

    /// @notice Test that the enforcer reverts when target doesn't match.
    function test_exactExecutionFailsWhenTargetDiffers() public {
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

        // Create terms with a different target for the second execution
        Execution[] memory termsExecutions_ = new Execution[](2);
        termsExecutions_[0] = executions_[0];
        termsExecutions_[1] = Execution({
            target: address(users.bob.deleGator), // Different target
            value: 0,
            callData: executions_[1].callData
        });

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);
        bytes memory terms_ = _encodeTerms(termsExecutions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactExecutionBatchEnforcer:invalid-execution");
        exactExecutionBatchEnforcer.beforeHook(
            terms_, hex"", batchDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when value doesn't match.
    function test_exactExecutionFailsWhenValueDiffers() public {
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

        // Create terms with a different value for the second execution
        Execution[] memory termsExecutions_ = new Execution[](2);
        termsExecutions_[0] = executions_[0];
        termsExecutions_[1] = Execution({
            target: executions_[1].target,
            value: 1 ether, // Different value
            callData: executions_[1].callData
        });

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);
        bytes memory terms_ = _encodeTerms(termsExecutions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactExecutionBatchEnforcer:invalid-execution");
        exactExecutionBatchEnforcer.beforeHook(
            terms_, hex"", batchDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when calldata doesn't match.
    function test_exactExecutionFailsWhenCalldataDiffers() public {
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

        // Create terms with different calldata for the second execution
        Execution[] memory termsExecutions_ = new Execution[](2);
        termsExecutions_[0] = executions_[0];
        termsExecutions_[1] = Execution({
            target: executions_[1].target,
            value: executions_[1].value,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.carol.deleGator), uint256(3 ether))
        });

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);
        bytes memory terms_ = _encodeTerms(termsExecutions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactExecutionBatchEnforcer:invalid-execution");
        exactExecutionBatchEnforcer.beforeHook(
            terms_, hex"", batchDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when batch size doesn't match.
    function test_batchSizeMismatch() public {
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

        // Create terms with only one execution
        Execution[] memory termsExecutions_ = new Execution[](1);
        termsExecutions_[0] = executions_[0];

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);
        bytes memory terms_ = _encodeTerms(termsExecutions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactExecutionBatchEnforcer:invalid-batch-size");
        exactExecutionBatchEnforcer.beforeHook(
            terms_, hex"", batchDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    /// @notice Test that the enforcer reverts when single mode is used.
    function test_singleDefaultModeReverts() public {
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
        exactExecutionBatchEnforcer.beforeHook(
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
        exactExecutionBatchEnforcer.beforeHook(
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
        exactExecutionBatchEnforcer.beforeHook(
            terms_, hex"", batchTryMode, executionCallData_, keccak256("test"), address(0), address(0)
        );
    }

    ////////////////////////////// Integration Tests //////////////////////////////

    /// @notice Integration test: the enforcer allows a batch of token transfers when executions match exactly.
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
        caveats_[0] = Caveat({ args: hex"", enforcer: address(exactExecutionBatchEnforcer), terms: terms_ });
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
        ModeCode[] memory onebatchDefaultMode_ = new ModeCode[](1);
        onebatchDefaultMode_[0] = batchDefaultMode;

        // Bob redeems the delegation to execute the batch
        vm.prank(address(users.bob.deleGator));
        delegationManager.redeemDelegations(permissionContexts_, onebatchDefaultMode_, executionCallDatas_);

        // Verify balances changed correctly
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), bobInitialBalance_ + 1 ether);
        assertEq(basicCF20.balanceOf(address(users.carol.deleGator)), carolInitialBalance_ + 2 ether);
    }

    /// @notice Integration test: the enforcer blocks batch execution when any execution doesn't match.
    function test_integration_BlocksBatchWhenExecutionDiffers() public {
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
            value: 1 ether, // Different value
            callData: executions_[1].callData
        });

        bytes memory terms_ = _encodeTerms(termsExecutions_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(exactExecutionBatchEnforcer), terms: terms_ });
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
        ModeCode[] memory onebatchDefaultMode_ = new ModeCode[](1);
        onebatchDefaultMode_[0] = batchDefaultMode;

        // Bob redeems the delegation to execute the batch
        vm.prank(address(users.bob.deleGator));
        vm.expectRevert("ExactExecutionBatchEnforcer:invalid-execution");
        delegationManager.redeemDelegations(permissionContexts_, onebatchDefaultMode_, executionCallDatas_);

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
        return ICaveatEnforcer(address(exactExecutionBatchEnforcer));
    }
}
