// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { SpecificActionERC20TransferBatchEnforcer } from "../../src/enforcers/SpecificActionERC20TransferBatchEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";

contract SpecificActionERC20TransferBatchEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    ////////////////////// State //////////////////////

    SpecificActionERC20TransferBatchEnforcer public batchEnforcer;
    BasicERC20 public token;
    ModeCode public batchMode = ModeLib.encodeSimpleBatch();
    ModeCode public singleMode = ModeLib.encodeSimpleSingle();
    uint256 public constant TRANSFER_AMOUNT = 10 ether;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        batchEnforcer = new SpecificActionERC20TransferBatchEnforcer();
        token = new BasicERC20(address(users.alice.deleGator), "Test", "TST", 100 ether);
        vm.label(address(batchEnforcer), "Specific Action ERC20 Transfer Batch Enforcer");
    }

    ////////////////////// Valid cases //////////////////////

    // should allow a valid batch execution with correct parameters
    function test_validBatchExecution() public {
        (Execution[] memory executions, bytes memory terms) = _setupValidBatchAndTerms();
        bytes memory executionCallData = ExecutionLib.encodeBatch(executions);

        vm.prank(address(delegationManager));
        batchEnforcer.beforeHook(terms, hex"", batchMode, executionCallData, keccak256("test"), address(0), address(0));
    }

    // should allow multiple different delegations with same parameters
    function test_multipleDelegationsAllowed() public {
        (Execution[] memory executions, bytes memory terms) = _setupValidBatchAndTerms();
        bytes memory executionCallData = ExecutionLib.encodeBatch(executions);

        vm.startPrank(address(delegationManager));

        // First delegation
        batchEnforcer.beforeHook(terms, hex"", batchMode, executionCallData, keccak256("delegation1"), address(0), address(0));

        // Second delegation with different hash
        batchEnforcer.beforeHook(terms, hex"", batchMode, executionCallData, keccak256("delegation2"), address(0), address(0));

        vm.stopPrank();
    }

    ////////////////////// Invalid cases //////////////////////

    // should fail with invalid mode (single mode instead of batch)
    function test_revertWithInvalidMode() public {
        (Execution[] memory executions, bytes memory terms) = _setupValidBatchAndTerms();
        bytes memory executionCallData = ExecutionLib.encodeBatch(executions);

        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        batchEnforcer.beforeHook(terms, hex"", singleMode, executionCallData, keccak256("test"), address(0), address(0));
    }

    // should fail when trying to reuse a delegation
    function test_revertOnDelegationReuse() public {
        (Execution[] memory executions, bytes memory terms) = _setupValidBatchAndTerms();
        bytes memory executionCallData = ExecutionLib.encodeBatch(executions);
        bytes32 delegationHash = keccak256("test");

        vm.startPrank(address(delegationManager));

        // First use
        batchEnforcer.beforeHook(terms, hex"", batchMode, executionCallData, delegationHash, address(0), address(0));

        // Attempt reuse
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:delegation-already-used");
        batchEnforcer.beforeHook(terms, hex"", batchMode, executionCallData, delegationHash, address(0), address(0));

        vm.stopPrank();
    }

    // should fail with invalid batch size
    function test_revertWithInvalidBatchSize() public {
        Execution[] memory executions = new Execution[](1);
        executions[0] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        (, bytes memory terms) = _setupValidBatchAndTerms();
        bytes memory executionCallData = ExecutionLib.encodeBatch(executions);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-batch-size");
        batchEnforcer.beforeHook(terms, hex"", batchMode, executionCallData, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid first transaction
    function test_revertWithInvalidFirstTransaction() public {
        (Execution[] memory executions, bytes memory terms) = _setupValidBatchAndTerms();
        // Modify first transaction
        executions[0].target = address(token);
        bytes memory executionCallData = ExecutionLib.encodeBatch(executions);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-first-transaction");
        batchEnforcer.beforeHook(terms, hex"", batchMode, executionCallData, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid second transaction
    function test_revertWithInvalidSecondTransaction() public {
        (Execution[] memory executions, bytes memory terms) = _setupValidBatchAndTerms();
        // Modify second transaction amount
        executions[1].callData = abi.encodeWithSelector(IERC20.transfer.selector, users.bob.addr, TRANSFER_AMOUNT + 1);
        bytes memory executionCallData = ExecutionLib.encodeBatch(executions);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-second-transaction");
        batchEnforcer.beforeHook(terms, hex"", batchMode, executionCallData, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid terms length
    function test_revertWithInvalidTermsLength() public {
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-terms-length");
        batchEnforcer.getTermsInfo(new bytes(91)); // Minimum required is 92 bytes
    }

    ////////////////////// Helper functions //////////////////////

    function _setupValidBatchAndTerms() internal view returns (Execution[] memory executions, bytes memory terms) {
        // Create valid batch of executions
        executions = new Execution[](2);

        // First execution: increment counter
        bytes memory incrementCalldata = abi.encodeWithSelector(Counter.increment.selector);
        executions[0] = Execution({ target: address(aliceDeleGatorCounter), value: 0, callData: incrementCalldata });

        // Second execution: transfer tokens
        executions[1] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, users.bob.addr, TRANSFER_AMOUNT)
        });

        // Create matching terms
        terms = abi.encodePacked(
            address(token), // tokenAddress
            users.bob.addr, // recipient
            TRANSFER_AMOUNT, // amount
            address(aliceDeleGatorCounter), // firstTarget
            incrementCalldata // firstCalldata
        );
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(batchEnforcer));
    }
}
