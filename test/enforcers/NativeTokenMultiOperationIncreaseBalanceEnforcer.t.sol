// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { NativeTokenMultiOperationIncreaseBalanceEnforcer } from
    "../../src/enforcers/NativeTokenMultiOperationIncreaseBalanceEnforcer.sol";
import { NativeTokenPaymentEnforcer } from "../../src/enforcers/NativeTokenPaymentEnforcer.sol";
import { NativeTokenTransferAmountEnforcer } from "../../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { ArgsEqualityCheckEnforcer } from "../../src/enforcers/ArgsEqualityCheckEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { Counter } from "../utils/Counter.t.sol";

import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

contract NativeTokenMultiOperationIncreaseBalanceEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    NativeTokenMultiOperationIncreaseBalanceEnforcer public enforcer;
    NativeTokenPaymentEnforcer public nativeTokenPaymentEnforcer;
    NativeTokenTransferAmountEnforcer public nativeTokenTransferAmountEnforcer;
    ArgsEqualityCheckEnforcer public argsEqualityCheckEnforcer;
    address delegator;
    address delegate;
    address dm;
    Execution noExecution;
    bytes executionCallData = abi.encode(noExecution);

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        dm = address(delegationManager);
        enforcer = new NativeTokenMultiOperationIncreaseBalanceEnforcer();
        vm.label(address(enforcer), "Native Balance Change Enforcer");
        noExecution = Execution(address(0), 0, hex"");

        // Initialize payment-related enforcers
        nativeTokenTransferAmountEnforcer = new NativeTokenTransferAmountEnforcer();
        vm.label(address(nativeTokenTransferAmountEnforcer), "Native Token Transfer Amount Enforcer");
        argsEqualityCheckEnforcer = new ArgsEqualityCheckEnforcer();
        vm.label(address(argsEqualityCheckEnforcer), "Args Equality Check Enforcer");
        nativeTokenPaymentEnforcer =
            new NativeTokenPaymentEnforcer(IDelegationManager(address(delegationManager)), address(argsEqualityCheckEnforcer));
        vm.label(address(nativeTokenPaymentEnforcer), "Native Payment Enforcer");
    }

    ////////////////////// Basic Functionality //////////////////////

    // Validates the terms get decoded correctly
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(address(users.carol.deleGator), uint256(100));
        address recipient_;
        uint256 amount_;
        (recipient_, amount_) = enforcer.getTermsInfo(terms_);
        assertEq(recipient_, address(users.carol.deleGator));
        assertEq(amount_, 100);
    }

    // Validates that getHashKey function returns the correct hash
    function test_getHashKey() public {
        address caller_ = address(dm);
        address recipient_ = address(delegator);

        bytes32 expectedHash_ = keccak256(abi.encode(caller_, recipient_));
        bytes32 actualHash_ = enforcer.getHashKey(caller_, recipient_);

        assertEq(actualHash_, expectedHash_, "getHashKey should return correct hash");
    }

    // Validates that a balance has increased at least the expected amount
    function test_allow_ifBalanceIncreases() public {
        address recipient_ = delegator;
        // Expect it to increase by at least 100
        bytes memory terms_ = abi.encodePacked(recipient_, uint256(100));

        // Increase by 100
        vm.startPrank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        _increaseBalance(delegator, 100);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Increase by 1000
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        _increaseBalance(delegator, 1000);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////// Errors //////////////////////

    // Reverts if a balance hasn't increased by the specified amount
    function test_notAllow_insufficientIncrease() public {
        address recipient_ = delegator;
        // Expect it to increase by at least 100
        bytes memory terms_ = abi.encodePacked(recipient_, uint256(100));

        // Increase by 10, expect revert
        vm.startPrank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        _increaseBalance(delegator, 10);
        vm.expectRevert(bytes("NativeTokenMultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    // Validates the terms are well formed
    function test_invalid_decodedTheTerms() public {
        address recipient_ = delegator;
        bytes memory terms_;

        // Too small
        terms_ = abi.encodePacked(recipient_, uint8(100));
        vm.expectRevert(bytes("NativeTokenMultiOperationIncreaseBalanceEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large
        terms_ = abi.encodePacked(recipient_, uint256(100), uint256(100));
        vm.expectRevert(bytes("NativeTokenMultiOperationIncreaseBalanceEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Reverts when the balance increase triggers an overflow.
    function test_notAllow_expectingOverflow() public {
        bytes memory terms_ = abi.encodePacked(address(delegator), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        vm.expectRevert();

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that balance changes between beforeAllHook calls are allowed and validated in the last afterAllHook call
    function test_allow_balanceChangedBetweenBeforeAllHookCalls() public {
        bytes memory terms_ = abi.encodePacked(address(delegator), uint256(100));

        // First beforeAllHook call - caches the initial balance - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Modify the recipient's balance between beforeAllHook calls - this should be allowed
        _increaseBalance(delegator, 50);

        // Second beforeAllHook call - should now succeed and track the new balance (delegator == recipient for aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Verify that the balance tracker is properly updated
        bytes32 hashKey_ = keccak256(abi.encode(address(dm), address(delegator)));
        (uint256 balanceBefore_, uint256 expectedIncrease_, uint256 validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 100000000000000000000, "balanceBefore should be same as initial balance");
        assertEq(expectedIncrease_, 200, "expectedIncrease should be 200 (100 + 100)");
        assertEq(validationRemaining_, 2, "validationRemaining should be 2");

        // Mint additional tokens to satisfy the total requirement (2 * 100 = 200, already have 50, need 150 more)
        _increaseBalance(delegator, 150);

        // First afterAllHook call - should not trigger balance check yet
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Second afterAllHook call - should trigger balance check and cleanup
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that balance check happens in the last afterAllHook call
    function test_balanceCheck_lastAfterAllHook() public {
        // Terms: [recipient, amount=100] - expecting balance increase
        bytes memory terms_ = abi.encodePacked(address(delegator), uint256(100));
        bytes32 hashKey_ = keccak256(abi.encode(address(dm), address(delegator)));

        // First beforeAllHook call
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Check validationRemaining after first beforeAllHook
        (,, uint256 validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 1, "validationRemaining should be 1 after first beforeAllHook");

        // Second beforeAllHook call
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Check validationRemaining after second beforeAllHook
        (,, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 2, "validationRemaining should be 2 after second beforeAllHook");

        // Mint tokens to recipient to satisfy the balance requirement (2 * 100 = 200)
        _increaseBalance(delegator, 200);

        // First afterAllHook call - should not trigger balance check yet
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Check validationRemaining after first afterAllHook
        (,, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 1, "validationRemaining should be 1 after first afterAllHook");

        // Verify balance tracker still exists (not cleaned up yet)
        (uint256 balanceBefore_, uint256 expectedIncrease_,) = enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 100000000000000000000, "balanceBefore should still be tracked");
        assertEq(expectedIncrease_, 200, "expectedIncrease should be 200 (100 + 100)");

        // Second afterAllHook call - should trigger balance check and cleanup
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Verify balance tracker is cleaned up (deleted)
        (balanceBefore_, expectedIncrease_, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 0, "balanceBefore should be 0 after cleanup");
        assertEq(expectedIncrease_, 0, "expectedIncrease should be 0 after cleanup");
        assertEq(validationRemaining_, 0, "validationRemaining should be 0 after cleanup");
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeAllHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    // Reverts if amount is 0
    function test_revertWithZeroAmount() public {
        address recipient_ = delegator;
        bytes memory terms_ = abi.encodePacked(recipient_, uint256(0));
        vm.prank(address(dm));
        vm.expectRevert("NativeTokenMultiOperationIncreaseBalanceEnforcer:zero-expected-change-amount");
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////////////// Multiple Enforcers //////////////////////////////

    // Reverts if the total balance increase is insufficient with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: both increasing by 100. Total expected balance change is an
    // increase of at least 200.
    function test_multiple_enforcers_insufficient_increase() public {
        address recipient_ = delegator;
        // increase by at least 100
        bytes memory terms_ = abi.encodePacked(recipient_, uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        _increaseBalance(delegator, 199);

        // First afterAllHook call - should not trigger validation yet (validationRemaining = 2)
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Second afterAllHook call - should trigger validation and revert (validationRemaining = 0)
        vm.expectRevert(bytes("NativeTokenMultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase"));
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////////////// Check events //////////////////////////////

    // Validates that the events are emitted correctly for an increase scenario.
    function test_events_emitted_correctly() public {
        address recipient_ = delegator;
        // Increase by 100
        bytes memory terms_ = abi.encodePacked(recipient_, uint256(100));

        // First beforeAllHook - should emit TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit NativeTokenMultiOperationIncreaseBalanceEnforcer.TrackedBalance(dm, recipient_, 100000000000000000000);
        vm.expectEmit(true, true, true, true);
        emit NativeTokenMultiOperationIncreaseBalanceEnforcer.UpdatedExpectedBalance(dm, recipient_, 100);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient_, delegate);

        // Second beforeAllHook should ONLY emit UpdatedExpectedBalance
        vm.recordLogs();
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient_, delegate);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "Should only emit one event");

        // Verify it's the UpdatedExpectedBalance event
        assertEq(logs[0].topics[0], keccak256("UpdatedExpectedBalance(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(dm)))); // delegationManager
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(recipient_))))); // recipient

        _increaseBalance(recipient_, 200);

        // First afterAllHook - should not emit any events (validationRemaining = 1)
        vm.recordLogs();
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        Vm.Log[] memory afterAllLogs = vm.getRecordedLogs();
        assertEq(afterAllLogs.length, 0, "Should not emit any events");

        // Second afterAllHook - should emit ValidatedBalance (validationRemaining = 0)
        vm.prank(dm);
        vm.expectEmit(true, true, true, true);
        emit NativeTokenMultiOperationIncreaseBalanceEnforcer.ValidatedBalance(dm, delegator, 200);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that delegation can be reused with different recipients without interference
    function test_allow_reuseDelegationWithDifferentRecipients() public {
        address recipient1_ = delegator;
        address recipient2_ = address(users.carol.deleGator);

        // Terms for two different recipients
        bytes memory terms1_ = abi.encodePacked(recipient1_, uint256(100));
        bytes memory terms2_ = abi.encodePacked(recipient2_, uint256(100));

        // Increase for recipient1 - First delegation
        vm.prank(dm);
        enforcer.beforeAllHook(terms1_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient1_, delegate);
        _increaseBalance(recipient1_, 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms1_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient1_, delegate);

        // Increase for recipient2 - First delegation (aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms2_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient2_, delegate);
        _increaseBalance(recipient2_, 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient2_, delegate);
    }

    // Validates that different delegation hashes with different recipients are handled separately
    function test_differentiateDelegationHashWithRecipient() public {
        bytes32 delegationHash1_ = bytes32(uint256(99999999));
        bytes32 delegationHash2_ = bytes32(uint256(88888888));

        address recipient1_ = delegator;
        address recipient2_ = address(users.carol.deleGator);

        // Terms for two different recipients
        bytes memory terms1_ = abi.encodePacked(recipient1_, uint256(100));
        bytes memory terms2_ = abi.encodePacked(recipient2_, uint256(100));

        // First delegation for recipient1
        vm.prank(dm);
        enforcer.beforeAllHook(terms1_, hex"", singleDefaultMode, executionCallData, delegationHash1_, recipient1_, delegate);

        // First delegation for recipient2
        vm.prank(dm);
        enforcer.beforeAllHook(terms2_, hex"", singleDefaultMode, executionCallData, delegationHash2_, recipient2_, delegate);

        // Increase balance by 100 only for recipient1
        _increaseBalance(recipient1_, 100);

        // Recipient1 passes
        vm.prank(dm);
        enforcer.afterAllHook(terms1_, hex"", singleDefaultMode, executionCallData, delegationHash1_, recipient1_, delegate);

        // Recipient2 did not receive tokens, so it should revert
        vm.prank(dm);
        vm.expectRevert(bytes("NativeTokenMultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, executionCallData, delegationHash2_, recipient2_, delegate);

        // Increase balance for recipient2
        _increaseBalance(recipient2_, 100);

        // Recipient2 now passes
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, executionCallData, delegationHash2_, recipient2_, delegate);
    }

    // Validates that balance tracker is properly cleaned up after validation
    function test_balanceTracker_clean() public {
        bytes memory terms_ = abi.encodePacked(address(delegator), uint256(100));
        bytes32 hash_ = keccak256(abi.encode(address(dm), address(delegator)));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        (, uint256 expectedIncrease_,) = enforcer.balanceTracker(hash_);
        assertEq(expectedIncrease_, 100);

        _increaseBalance(delegator, 100);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        (, expectedIncrease_,) = enforcer.balanceTracker(hash_);
        assertEq(expectedIncrease_, 0);
    }

    ////////////////////////////// Integration tests //////////////////////////////

    /**
     * @notice Tests that balance change enforcers work correctly without payment requirements.
     * @dev This test creates 3 delegations in a single chain: 2 balance change enforcers expecting 2 ETH total increase,
     * with an empty delegation transfer of 2.4 ETH to Alice in the middle. This should pass because Alice receives 2.4 ETH.
     */
    function test_combination_without_payment_enforcer() public {
        // Set up initial balances
        vm.deal(address(users.bob.deleGator), 10 ether); // Give Bob some ETH for payments
        vm.deal(address(users.alice.deleGator), 100 ether); // Give Alice 100 ETH for balance tracking

        // Create batch delegations with balance change enforcers only
        // 1. First delegation: NativeTokenMultiOperationIncreaseBalanceEnforcer expecting balance increase up to 1 ETH
        bytes memory balanceTerms_ = abi.encodePacked(address(delegator), uint256(1 ether));

        Caveat[] memory caveats1_ = new Caveat[](1);
        caveats1_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: balanceTerms_ });

        Delegation memory delegation1_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats1_,
            salt: 0,
            signature: hex""
        });

        delegation1_ = signDelegation(users.alice, delegation1_);

        // 2. Second delegation: Empty delegation (self-execution) where Bob transfers 2.4 ETH to Alice
        // This is represented as an empty delegation array in the permission context
        bytes memory emptyDelegationContext_ = abi.encode(new Delegation[](0));

        // 3. Third delegation: NativeTokenMultiOperationIncreaseBalanceEnforcer expecting balance increase up to 1 ETH
        Caveat[] memory caveats3_ = new Caveat[](1);
        caveats3_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: balanceTerms_ });

        Delegation memory delegation3_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats3_,
            salt: 2,
            signature: hex""
        });

        delegation3_ = signDelegation(users.alice, delegation3_);

        // Create the delegation chain for batch processing
        bytes[] memory permissionContexts_ = new bytes[](3);

        // First delegation
        Delegation[] memory delegations1_ = new Delegation[](1);
        delegations1_[0] = delegation1_;
        permissionContexts_[0] = abi.encode(delegations1_);

        // Second - empty delegation for self-execution
        permissionContexts_[1] = emptyDelegationContext_;

        // Third delegation
        Delegation[] memory delegations3_ = new Delegation[](1);
        delegations3_[0] = delegation3_;
        permissionContexts_[2] = abi.encode(delegations3_);

        ModeCode[] memory encodedModes_ = new ModeCode[](3);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();
        encodedModes_[1] = ModeLib.encodeSimpleSingle();
        encodedModes_[2] = ModeLib.encodeSimpleSingle();

        // Create executions: first and third are 0 value, second is the transfer
        bytes[] memory executionCallDatas_ = new bytes[](3);

        // First execution: 0 value (no balance changes)
        Execution memory executionNoValue_ = Execution({
            target: address(0xBEEF), // Target some external address
            value: 0, // No ETH transfer
            callData: hex""
        });
        executionCallDatas_[0] =
            ExecutionLib.encodeSingle(executionNoValue_.target, executionNoValue_.value, executionNoValue_.callData);

        // Second execution: Transfer 2.4 ETH to Alice
        Execution memory executionTransfer_ = Execution({
            target: address(users.alice.deleGator), // Target Alice's address
            value: uint256(2.4 ether), // Transfer 2.4 ETH
            callData: hex""
        });
        executionCallDatas_[1] =
            ExecutionLib.encodeSingle(executionTransfer_.target, executionTransfer_.value, executionTransfer_.callData);

        // Third execution: 0 value (no balance changes)
        executionCallDatas_[2] =
            ExecutionLib.encodeSingle(executionNoValue_.target, executionNoValue_.value, executionNoValue_.callData);

        // Execute all delegations in a single chain
        // This should succeed because Alice's balance change enforcers expect 2 ETH increase
        // and she receives 2.4 ETH, which is sufficient
        vm.prank(address(users.bob.deleGator));
        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);
    }

    /**
     * @notice Tests that balance change enforcers fail when payment requirements reduce the net balance increase.
     * @dev This test creates 4 delegations in a single chain: 2 balance change enforcers expecting 2 ETH total increase,
     * 1 NativeTokenPaymentEnforcer requiring 1 ETH payment, with an empty delegation transfer of 2.4 ETH to Alice in the second
     * position.
     * This should fail because the net increase is only 1.4 ETH (2.4 - 1.0).
     */
    function test_combination_with_payment_enforcer() public {
        // Set up initial balances
        vm.deal(address(users.bob.deleGator), 10 ether); // Give Bob some ETH for payments
        vm.deal(address(users.alice.deleGator), 100 ether); // Give Alice 100 ETH for balance tracking

        // Create batch delegations with multiple enforcers
        // 1. First delegation: NativeTokenMultiOperationIncreaseBalanceEnforcer expecting balance increase up to 1 ETH
        bytes memory balanceTerms_ = abi.encodePacked(address(delegator), uint256(1 ether));

        Caveat[] memory caveats1_ = new Caveat[](1);
        caveats1_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: balanceTerms_ });

        Delegation memory delegation1_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats1_,
            salt: 0,
            signature: hex""
        });

        delegation1_ = signDelegation(users.alice, delegation1_);

        // 2. Second delegation: Empty delegation (self-execution) where Bob transfers 2.4 ETH to Alice
        // This is represented as an empty delegation array in the permission context
        bytes memory emptyDelegationContext_ = abi.encode(new Delegation[](0));

        // 3. Third delegation: NativeTokenPaymentEnforcer requiring 1 ETH payment
        bytes memory paymentTerms_ = abi.encodePacked(address(0x1337), uint256(1 ether)); // Payment goes to 0x1337, not to Alice

        Caveat[] memory caveats3_ = new Caveat[](1);
        caveats3_[0] = Caveat({ args: hex"", enforcer: address(nativeTokenPaymentEnforcer), terms: paymentTerms_ });

        Delegation memory delegation3_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats3_,
            salt: 2,
            signature: hex""
        });

        delegation3_ = signDelegation(users.alice, delegation3_);
        bytes32 delegationHash3_ = EncoderLib._getDelegationHash(delegation3_);

        // Create allowance delegation for the payment (following the working example pattern)
        bytes memory argsEnforcerTerms_ = abi.encodePacked(delegationHash3_, address(users.bob.deleGator));

        Caveat[] memory allowanceCaveats_ = new Caveat[](2);
        allowanceCaveats_[0] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsEnforcerTerms_ });
        allowanceCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: abi.encode(uint256(1 ether)) });

        Delegation memory allowanceDelegation_ = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.alice.deleGator), // Alice delegates payment authority from her balance
            authority: ROOT_AUTHORITY,
            caveats: allowanceCaveats_,
            salt: 1,
            signature: hex""
        });

        allowanceDelegation_ = signDelegation(users.alice, allowanceDelegation_);

        // Set the args for the payment delegation - encode the allowance delegation array
        Delegation[] memory allowanceDelegations_ = new Delegation[](1);
        allowanceDelegations_[0] = allowanceDelegation_;
        delegation3_.caveats[0].args = abi.encode(allowanceDelegations_);

        // 4. Fourth delegation: NativeTokenMultiOperationIncreaseBalanceEnforcer expecting balance increase up to 1 ETH
        Caveat[] memory caveats4_ = new Caveat[](1);
        caveats4_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: balanceTerms_ });

        Delegation memory delegation4_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats4_,
            salt: 3,
            signature: hex""
        });

        delegation4_ = signDelegation(users.alice, delegation4_);

        // Create the delegation chain for batch processing
        bytes[] memory permissionContexts_ = new bytes[](4);

        // First delegation
        Delegation[] memory delegations1_ = new Delegation[](1);
        delegations1_[0] = delegation1_;
        permissionContexts_[0] = abi.encode(delegations1_);

        // Second - empty delegation for self-execution
        permissionContexts_[1] = emptyDelegationContext_;

        // Third delegation
        Delegation[] memory delegations3_ = new Delegation[](1);
        delegations3_[0] = delegation3_;
        permissionContexts_[2] = abi.encode(delegations3_);

        // Fourth delegation
        Delegation[] memory delegations4_ = new Delegation[](1);
        delegations4_[0] = delegation4_;
        permissionContexts_[3] = abi.encode(delegations4_);

        ModeCode[] memory encodedModes_ = new ModeCode[](4);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();
        encodedModes_[1] = ModeLib.encodeSimpleSingle();
        encodedModes_[2] = ModeLib.encodeSimpleSingle();
        encodedModes_[3] = ModeLib.encodeSimpleSingle();

        // Create executions: first, third, and fourth are 0 value, second is the transfer
        bytes[] memory executionCallDatas_ = new bytes[](4);

        // First execution: 0 value (no balance changes)
        Execution memory executionNoValue_ = Execution({
            target: address(0xBEEF), // Target some external address
            value: 0, // No ETH transfer
            callData: hex""
        });
        executionCallDatas_[0] =
            ExecutionLib.encodeSingle(executionNoValue_.target, executionNoValue_.value, executionNoValue_.callData);

        // Second execution: Transfer 2.4 ETH to Alice
        Execution memory executionTransfer_ = Execution({
            target: address(users.alice.deleGator), // Target Alice's address
            value: uint256(2.4 ether), // Transfer 2.4 ETH
            callData: hex""
        });
        executionCallDatas_[1] =
            ExecutionLib.encodeSingle(executionTransfer_.target, executionTransfer_.value, executionTransfer_.callData);

        // Third execution: 0 value (no balance changes)
        executionCallDatas_[2] =
            ExecutionLib.encodeSingle(executionNoValue_.target, executionNoValue_.value, executionNoValue_.callData);

        // Fourth execution: 0 value (no balance changes)
        executionCallDatas_[3] =
            ExecutionLib.encodeSingle(executionNoValue_.target, executionNoValue_.value, executionNoValue_.callData);

        // Execute all delegations in a single chain
        // This should revert because:
        // 1. Alice's balance change enforcers expect 2 ETH increase (1 + 1)
        // 2. But she also has to pay 1 ETH from the NativeTokenPaymentEnforcer
        // 3. So her net balance change would be 2.4 ETH (from Bob) - 1 ETH (payment) = 1.4 ETH
        // 4. But the enforcers expect at least 2 ETH increase
        vm.expectRevert("NativeTokenMultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase");
        vm.prank(address(users.bob.deleGator));
        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);
    }

    ////////////////////////////// Helper functions //////////////////////////////

    function _increaseBalance(address _recipient, uint256 _amount) internal {
        vm.deal(_recipient, _recipient.balance + _amount);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
