// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
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
    ////////////////////// State //////////////////////

    SpecificActionERC20TransferBatchEnforcer public batchEnforcer;
    BasicERC20 public token;
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
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);
        bytes32 delegationHash_ = keccak256("test");
        address delegator_ = address(users.alice.deleGator);

        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(batchEnforcer));
        emit SpecificActionERC20TransferBatchEnforcer.DelegationExecuted(
            address(delegationManager),
            delegationHash_,
            delegator_ // delegator
        );
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, delegationHash_, delegator_, address(0));
    }

    // should allow multiple different delegations with same parameters
    function test_multipleDelegationsAllowed() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.startPrank(address(delegationManager));

        // First delegation
        batchEnforcer.beforeHook(
            terms_, hex"", batchDefaultMode, executionCallData_, keccak256("delegation1"), address(0), address(0)
        );

        // Second delegation with different hash
        batchEnforcer.beforeHook(
            terms_, hex"", batchDefaultMode, executionCallData_, keccak256("delegation2"), address(0), address(0)
        );

        vm.stopPrank();
    }

    ////////////////////// Invalid cases //////////////////////

    // should fail with invalid call type mode (single mode instead of batch)
    function test_revertWithInvalidCallTypeMode() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        batchEnforcer.beforeHook(terms_, hex"", singleDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        batchEnforcer.beforeHook(hex"", hex"", batchTryMode, hex"", bytes32(0), address(0), address(0));
    }

    // should fail when trying to reuse a delegation
    function test_revertOnDelegationReuse() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);
        bytes32 delegationHash_ = keccak256("test");

        vm.startPrank(address(delegationManager));

        // First use
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, delegationHash_, address(0), address(0));

        // Attempt reuse
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:delegation-already-used");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, delegationHash_, address(0), address(0));

        vm.stopPrank();
    }

    // should fail with invalid batch size
    function test_revertWithInvalidBatchSize() public {
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        (, bytes memory terms_) = _setupValidBatchAndTerms();
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-batch-size");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid first transaction target
    function test_revertWithInvalidFirstTransactionTarget() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        executions_[0].target = address(token); // Change target to something invalid
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-first-transaction");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid first transaction value
    function test_revertWithInvalidFirstTransactionValue() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        executions_[0].value = 1 ether; // Add non-zero value
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-first-transaction");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid first transaction calldata
    function test_revertWithInvalidFirstTransactionCalldata() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        executions_[0].callData = abi.encodeWithSelector(Counter.setCount.selector, 42); // Different calldata
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-first-transaction");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid second transaction target
    function test_revertWithInvalidSecondTransactionTarget() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        executions_[1].target = address(aliceDeleGatorCounter); // Wrong target
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-second-transaction");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid second transaction value
    function test_revertWithInvalidSecondTransactionValue() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        executions_[1].value = 1 ether; // Non-zero value
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-second-transaction");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid second transaction calldata length
    function test_revertWithInvalidSecondTransactionCalldataLength() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        executions_[1].callData = abi.encodeWithSelector(IERC20.transfer.selector, users.bob.addr); // Missing amount parameter
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-second-transaction");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid second transaction selector
    function test_revertWithInvalidSecondTransactionSelector() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        executions_[1].callData = abi.encodeWithSelector(IERC20.approve.selector, users.bob.addr, TRANSFER_AMOUNT); // Wrong
            // function
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-second-transaction");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid second transaction recipient
    function test_revertWithInvalidSecondTransactionRecipient() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        executions_[1].callData = abi.encodeWithSelector(IERC20.transfer.selector, address(this), TRANSFER_AMOUNT); // Wrong
            // recipient
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-second-transaction");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid second transaction amount
    function test_revertWithInvalidSecondTransactionAmount() public {
        (Execution[] memory executions_, bytes memory terms_) = _setupValidBatchAndTerms();
        executions_[1].callData = abi.encodeWithSelector(IERC20.transfer.selector, users.bob.addr, TRANSFER_AMOUNT + 1); // Wrong
            // amount
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-second-transaction");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should fail with invalid terms length
    function test_revertWithInvalidTermsLength() public {
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-terms-length");
        batchEnforcer.getTermsInfo(new bytes(123)); // Minimum required is 124 bytes
    }

    // should allow execution with non-zero firstValue
    function test_validBatchExecutionWithNonZeroFirstValue() public {
        uint256 firstValue = 1 ether;

        // Create executions with non-zero value for first transaction
        Execution[] memory executions_ = new Execution[](2);
        bytes memory incrementCalldata_ = abi.encodeWithSelector(Counter.increment.selector);
        executions_[0] = Execution({ target: address(aliceDeleGatorCounter), value: firstValue, callData: incrementCalldata_ });
        executions_[1] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, users.bob.addr, TRANSFER_AMOUNT)
        });

        // Create matching terms with non-zero firstValue
        bytes memory terms_ = abi.encodePacked(
            address(token), // tokenAddress
            users.bob.addr, // recipient
            TRANSFER_AMOUNT, // amount
            address(aliceDeleGatorCounter), // firstTarget
            firstValue, // firstValue
            incrementCalldata_ // firstCalldata
        );

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);
        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, delegationHash_, address(0), address(0));

        // Verify delegation was marked as used
        assertTrue(batchEnforcer.usedDelegations(address(delegationManager), delegationHash_));
    }

    // should fail when execution firstValue doesn't match terms firstValue
    function test_revertWithMismatchedFirstValue() public {
        uint256 termsFirstValue = 1 ether;
        uint256 executionFirstValue = 2 ether;

        // Create executions with different firstValue than terms
        Execution[] memory executions_ = new Execution[](2);
        bytes memory incrementCalldata_ = abi.encodeWithSelector(Counter.increment.selector);
        executions_[0] = Execution({
            target: address(aliceDeleGatorCounter),
            value: executionFirstValue, // Different from terms
            callData: incrementCalldata_
        });
        executions_[1] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, users.bob.addr, TRANSFER_AMOUNT)
        });

        // Create terms with different firstValue than execution
        bytes memory terms_ = abi.encodePacked(
            address(token), // tokenAddress
            users.bob.addr, // recipient
            TRANSFER_AMOUNT, // amount
            address(aliceDeleGatorCounter), // firstTarget
            termsFirstValue, // firstValue
            incrementCalldata_ // firstCalldata
        );

        bytes memory executionCallData_ = ExecutionLib.encodeBatch(executions_);

        vm.prank(address(delegationManager));
        vm.expectRevert("SpecificActionERC20TransferBatchEnforcer:invalid-first-transaction");
        batchEnforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    // should correctly decode terms including firstValue
    function test_getTermsInfo() public {
        address expectedToken = address(token);
        address expectedRecipient = users.bob.addr;
        uint256 expectedAmount = TRANSFER_AMOUNT;
        address expectedFirstTarget = address(aliceDeleGatorCounter);
        uint256 expectedFirstValue = 1.5 ether;
        bytes memory expectedFirstCalldata = abi.encodeWithSelector(Counter.increment.selector);

        bytes memory terms_ = abi.encodePacked(
            expectedToken, expectedRecipient, expectedAmount, expectedFirstTarget, expectedFirstValue, expectedFirstCalldata
        );

        SpecificActionERC20TransferBatchEnforcer.TermsData memory decoded_ = batchEnforcer.getTermsInfo(terms_);

        assertEq(decoded_.tokenAddress, expectedToken);
        assertEq(decoded_.recipient, expectedRecipient);
        assertEq(decoded_.amount, expectedAmount);
        assertEq(decoded_.firstTarget, expectedFirstTarget);
        assertEq(decoded_.firstValue, expectedFirstValue);
        assertEq(keccak256(decoded_.firstCalldata), keccak256(expectedFirstCalldata));
    }

    ////////////////////// Integration //////////////////////

    // should allow a specific action ERC20 transfer batch through delegation
    function test_allow_specificActionERC20TransferBatch() public {
        // Create batch of executions
        Execution[] memory executions_ = new Execution[](2);

        // First execution: increment counter
        bytes memory incrementCalldata_ = abi.encodeWithSelector(Counter.increment.selector);
        executions_[0] = Execution({ target: address(aliceDeleGatorCounter), value: 0, callData: incrementCalldata_ });

        // Second execution: transfer tokens
        executions_[1] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, users.bob.addr, TRANSFER_AMOUNT)
        });

        // Create matching terms
        bytes memory terms_ = abi.encodePacked(
            address(token), // tokenAddress
            users.bob.addr, // recipient
            TRANSFER_AMOUNT, // amount
            address(aliceDeleGatorCounter), // firstTarget
            uint256(0), // firstValue
            incrementCalldata_ // firstCalldata
        );

        // Create delegation from Alice to Bob with the SpecificActionERC20TransferBatchEnforcer caveat
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(batchEnforcer), terms: terms_, args: hex"" });

        Delegation memory delegation_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Record initial states
        uint256 initialCount_ = aliceDeleGatorCounter.count();
        uint256 initialBalance_ = token.balanceOf(users.bob.addr);

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
        vm.prank(users.bob.addr);
        delegationManager.redeemDelegations(permissionContexts_, oneBatchMode_, executionCallDatas_);

        // Verify states changed correctly
        assertEq(aliceDeleGatorCounter.count(), initialCount_ + 1);
        assertEq(token.balanceOf(users.bob.addr), initialBalance_ + TRANSFER_AMOUNT);
    }

    // should allow integration test with non-zero firstValue
    function test_allow_specificActionERC20TransferBatchWithNonZeroValue() public {
        uint256 firstValue = 0.5 ether;

        // Fund Alice's DeleGator with ETH for the first transaction
        vm.deal(address(users.alice.deleGator), firstValue);

        // Create batch of executions with non-zero value
        Execution[] memory executions_ = new Execution[](2);

        // First execution: send ETH to Bob (simple transfer)
        executions_[0] = Execution({
            target: users.bob.addr,
            value: firstValue,
            callData: hex"" // Empty calldata for simple transfer
         });

        // Second execution: transfer tokens
        executions_[1] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, users.bob.addr, TRANSFER_AMOUNT)
        });

        // Create matching terms with non-zero firstValue
        bytes memory terms_ = abi.encodePacked(
            address(token), // tokenAddress
            users.bob.addr, // recipient
            TRANSFER_AMOUNT, // amount
            users.bob.addr, // firstTarget (Bob's address for ETH transfer)
            firstValue, // firstValue
            hex"" // firstCalldata (empty for simple transfer)
        );

        // Create delegation from Alice to Bob with the SpecificActionERC20TransferBatchEnforcer caveat
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(batchEnforcer), terms: terms_, args: hex"" });

        Delegation memory delegation_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Record initial states
        uint256 initialBalance_ = token.balanceOf(users.bob.addr);
        uint256 initialBobEthBalance_ = users.bob.addr.balance;

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
        vm.prank(users.bob.addr);
        delegationManager.redeemDelegations(permissionContexts_, oneBatchMode_, executionCallDatas_);

        // Verify states changed correctly
        assertEq(token.balanceOf(users.bob.addr), initialBalance_ + TRANSFER_AMOUNT);
        assertEq(users.bob.addr.balance, initialBobEthBalance_ + firstValue);
    }

    ////////////////////// Helper functions //////////////////////

    function _setupValidBatchAndTerms() internal view returns (Execution[] memory executions_, bytes memory terms_) {
        // Create valid batch of executions
        executions_ = new Execution[](2);

        // First execution: increment counter
        bytes memory incrementCalldata_ = abi.encodeWithSelector(Counter.increment.selector);
        executions_[0] = Execution({ target: address(aliceDeleGatorCounter), value: 0, callData: incrementCalldata_ });

        // Second execution: transfer tokens
        executions_[1] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, users.bob.addr, TRANSFER_AMOUNT)
        });

        // Create matching terms
        terms_ = abi.encodePacked(
            address(token), // tokenAddress
            users.bob.addr, // recipient
            TRANSFER_AMOUNT, // amount
            address(aliceDeleGatorCounter), // firstTarget
            uint256(0), // firstValue
            incrementCalldata_ // firstCalldata
        );

        return (executions_, terms_);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(batchEnforcer));
    }
}
