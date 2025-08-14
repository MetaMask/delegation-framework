// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { NativeTokenTotalBalanceChangeEnforcer } from "../../src/enforcers/NativeTokenTotalBalanceChangeEnforcer.sol";
import { NativeTokenPaymentEnforcer } from "../../src/enforcers/NativeTokenPaymentEnforcer.sol";
import { NativeTokenTransferAmountEnforcer } from "../../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { ArgsEqualityCheckEnforcer } from "../../src/enforcers/ArgsEqualityCheckEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { Counter } from "../utils/Counter.t.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

contract NativeTokenTotalBalanceChangeEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    NativeTokenTotalBalanceChangeEnforcer public enforcer;
    NativeTokenPaymentEnforcer public nativeTokenPaymentEnforcer;
    NativeTokenTransferAmountEnforcer public nativeTokenTransferAmountEnforcer;
    ArgsEqualityCheckEnforcer public argsEqualityCheckEnforcer;
    address delegator;
    address delegate;
    address recipient;
    address someUser;
    address dm;
    address delegatorIntegration;
    Execution noExecution;
    bytes executionCallData = abi.encode(noExecution);

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        recipient = address(users.carol.deleGator);
        someUser = address(users.dave.deleGator);
        dm = address(delegationManager);
        delegatorIntegration = address(users.alice.deleGator);
        enforcer = new NativeTokenTotalBalanceChangeEnforcer();
        vm.label(address(enforcer), "Native Balance Change Enforcer");
        
        // Initialize payment-related enforcers
        nativeTokenTransferAmountEnforcer = new NativeTokenTransferAmountEnforcer();
        vm.label(address(nativeTokenTransferAmountEnforcer), "Native Token Transfer Amount Enforcer");
        argsEqualityCheckEnforcer = new ArgsEqualityCheckEnforcer();
        vm.label(address(argsEqualityCheckEnforcer), "Args Equality Check Enforcer");
        nativeTokenPaymentEnforcer = new NativeTokenPaymentEnforcer(
            IDelegationManager(address(delegationManager)), 
            address(argsEqualityCheckEnforcer)
        );
        vm.label(address(nativeTokenPaymentEnforcer), "Native Payment Enforcer");
        
        noExecution = Execution(address(0), 0, hex"");
    }

    ////////////////////// Basic Functionality //////////////////////

    // Validates the terms get decoded correctly
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(false, address(users.carol.deleGator), uint256(100));
        bool enforceDecrease_;
        uint256 amount_;
        address recipient_;
        (enforceDecrease_, recipient_, amount_) = enforcer.getTermsInfo(terms_);
        assertFalse(enforceDecrease_);
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
        // Terms: [flag=false, recipient, amount=100]
        bytes memory terms_ = abi.encodePacked(false, address(recipient), uint256(100));

        // Increase by 100 - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        _increaseBalance(recipient, 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Increase by 1000 - Subsequent delegation: delegator == recipient (aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        _increaseBalance(recipient, 1000);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    // Validates that a delegation can be reused with different recipients (for increase) without interference
    function test_allow_reuseDelegationWithDifferentRecipients() public {
        // Terms for two different recipients (flag=false indicates increase expected)
        bytes memory terms1_ = abi.encodePacked(false, address(recipient), uint256(100));
        bytes memory terms2_ = abi.encodePacked(false, address(delegator), uint256(100));

        // Increase for recipient - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms1_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        _increaseBalance(recipient, 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms1_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Increase for delegator as recipient - First delegation: delegator == delegator (aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms2_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        _increaseBalance(delegator, 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that a balance decrease within the allowed range passes.
    // For decreases (flag = true), the enforcer now checks that the final balance is not below the cached balance minus the
    // allowed amount.
    // Example: if the cached balance is 100 and the allowed decrease is 10, the final balance must be at least 90.
    function test_allow_ifBalanceDoesNotDecreaseTooMuch() public {
        // Set an initial balance for the recipient.
        uint256 initialBalance_ = 100;
        vm.deal(recipient, initialBalance_);

        // Terms: flag=true (decrease expected), recipient, allowed decrease amount = 10.
        bytes memory terms_ = abi.encodePacked(true, address(recipient), uint256(10));

        // Cache the initial balance via beforeAllHook - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Simulate a decrease by transferring out 5 tokens (final balance becomes 95, which is >= 100 - 10)
        _decreaseBalance(recipient, 5);

        // afterAllHook should pass since 95 >= 90.
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    ////////////////////// Errors //////////////////////

    // Reverts if an increase hasn't been sufficient
    function test_notAllow_insufficientIncrease() public {
        // Terms: flag=false (increase expected), required increase of 100 tokens.
        bytes memory terms_ = abi.encodePacked(false, address(recipient), uint256(100));

        // Mint only 10 tokens (insufficient increase) - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        _increaseBalance(recipient, 10);
        vm.prank(dm);
        vm.expectRevert(bytes("NativeTokenTotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    // New Test: Reverts if the balance decreases too much (i.e. final balance falls below cached balance - allowed amount)
    function test_notAllow_excessiveDecrease() public {
        uint256 initialBalance_ = 100;
        vm.deal(recipient, initialBalance_);

        // Terms: flag=true (decrease expected), recipient, allowed maximum decrease = 10.
        bytes memory terms_ = abi.encodePacked(true, address(recipient), uint256(10));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Simulate an excessive decrease: transfer out 20 tokens (final balance becomes 80, which is below 100 - 10).
        _decreaseBalance(recipient, 20);

        vm.prank(dm);
        vm.expectRevert(bytes("NativeTokenTotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    // Reverts if no increase happens when one is expected
    function test_notAllow_noIncreaseToRecipient() public {
        bytes memory terms_ = abi.encodePacked(false, address(recipient), uint256(100));

        // Cache the initial balance - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Do not modify recipient's balance.
        vm.prank(dm);
        vm.expectRevert(bytes("NativeTokenTotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    // Validates the terms are well formed (exactly 53 bytes)
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small: missing required bytes (should be 53 bytes)
        terms_ = abi.encodePacked(false, address(recipient), uint8(100));
        vm.expectRevert(bytes("NativeTokenTotalBalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large: extra bytes beyond 53.
        terms_ = abi.encodePacked(false, address(recipient), uint256(100), uint256(100));
        vm.expectRevert(bytes("NativeTokenTotalBalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Reverts when the balance increase triggers an overflow.
    function test_notAllow_expectingOverflow() public {
        bytes memory terms_ = abi.encodePacked(false, address(recipient), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.expectRevert();

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    // Reverts when the balance increase triggers an overflow.
    function test_balanceTracker_clean() public {
        bytes memory terms_ = abi.encodePacked(false, address(recipient), uint256(100));
        bytes32 hash_ = keccak256(abi.encode(address(dm), address(recipient)));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        (, uint256 expectedIncrease_,,) = enforcer.balanceTracker(hash_);
        assertEq(expectedIncrease_, 100);

        _increaseBalance(recipient, 100);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        (, expectedIncrease_,,) = enforcer.balanceTracker(hash_);
        assertEq(expectedIncrease_, 0);
    }

    // Validates that balance changes between beforeAllHook calls are allowed and validated in the last afterAllHook call
    function test_allow_balanceChangedBetweenBeforeAllHookCalls() public {
        bytes memory terms_ = abi.encodePacked(false, address(recipient), uint256(100));

        // First beforeAllHook call - caches the initial balance - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Modify the recipient's balance between beforeAllHook calls - this should be allowed
        _increaseBalance(recipient, 50);

        // Second beforeAllHook call - should now succeed and track the new balance (delegator == recipient for aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Verify that the balance tracker is properly updated
        bytes32 hashKey_ = keccak256(abi.encode(address(dm), address(recipient)));
        (uint256 balanceBefore_, uint256 expectedIncrease_, uint256 expectedDecrease_, uint256 validationRemaining_) =
            enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 100000000000000000000, "balanceBefore should be same as initial balance");
        assertEq(expectedIncrease_, 200, "expectedIncrease should be 200 (100 + 100)");
        assertEq(expectedDecrease_, 0, "expectedDecrease should be 0");
        assertEq(validationRemaining_, 2, "validationRemaining should be 2");

        // Mint additional tokens to satisfy the total requirement (2 * 100 = 200, already have 50, need 150 more)
        _increaseBalance(recipient, 150);

        // First afterAllHook call - should not trigger balance check yet
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Second afterAllHook call - should trigger balance check and cleanup
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    // Validates that balance check happens in the last afterAllHook call
    function test_balanceCheck_lastAfterAllHook() public {
        // Terms: [flag=false, recipient, amount=100] - expecting balance increase
        bytes memory terms_ = abi.encodePacked(false, address(recipient), uint256(100));
        bytes32 hashKey_ = keccak256(abi.encode(address(dm), address(recipient)));

        // First beforeAllHook call
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Check validationRemaining after first beforeAllHook
        (,,, uint256 validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 1, "validationRemaining should be 1 after first beforeAllHook");

        // Second beforeAllHook call (delegator == recipient for aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Check validationRemaining after second beforeAllHook
        (,,, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 2, "validationRemaining should be 2 after second beforeAllHook");

        // Mint tokens to recipient to satisfy the balance requirement (2 * 100 = 200)
        _increaseBalance(recipient, 200);

        // First afterAllHook call - should not trigger balance check yet
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Check validationRemaining after first afterAllHook
        (,,, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 1, "validationRemaining should be 1 after first afterAllHook");

        // Verify balance tracker still exists (not cleaned up yet)
        (uint256 balanceBefore_, uint256 expectedIncrease_, uint256 expectedDecrease_,) = enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 100000000000000000000, "balanceBefore should still be tracked");
        assertEq(expectedIncrease_, 200, "expectedIncrease should be 200 (100 + 100)");
        assertEq(expectedDecrease_, 0, "expectedDecrease should be 0");

        // Second afterAllHook call - should trigger balance check and cleanup
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);

        // Verify balance tracker is cleaned up (deleted)
        (balanceBefore_, expectedIncrease_, expectedDecrease_, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 0, "balanceBefore should be 0 after cleanup");
        assertEq(expectedIncrease_, 0, "expectedIncrease should be 0 after cleanup");
        assertEq(expectedDecrease_, 0, "expectedDecrease should be 0 after cleanup");
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
        bytes memory terms_ = abi.encodePacked(false, recipient_, uint256(0));
        vm.prank(address(dm));
        vm.expectRevert("NativeTokenTotalBalanceChangeEnforcer:zero-expected-change-amount");
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////////////// Multiple Enforcers //////////////////////////////

    // Reverts if the total balance increase is insufficient.
    // We are running 3 enforcers in the delegation chain: all increasing by 100. Total expected balance change is an
    // increase of at least 300.
    function test_multiple_enforcers_insufficient_increase() public {
        // Terms: [flag=false, recipient, amount=100]
        bytes memory terms_ = abi.encodePacked(false, address(recipient), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        _increaseBalance(recipient, 299);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        vm.expectRevert("NativeTokenTotalBalanceChangeEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    // Reverts if the total balance decrease is excessive with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: both decreasing by 100. Total expected balance change is an
    // decrease of at most 200.
    function test_multiple_enforcers_decrease() public {
        uint256 initialBalance_ = 100;
        vm.deal(recipient, initialBalance_);

        // Terms: [flag=true, recipient, amount=10]
        bytes memory terms_ = abi.encodePacked(true, address(recipient), uint256(10));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        _decreaseBalance(recipient, 20);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        // calling afterAllHook for each beforeAllHook
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    function test_multiple_enforcers_excessiveDecrease() public {
        uint256 initialBalance_ = 100;
        vm.deal(recipient, initialBalance_);

        // Terms: [flag=true, recipient, amount=10]
        bytes memory terms_ = abi.encodePacked(true, address(recipient), uint256(10));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        _decreaseBalance(recipient, 21);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        vm.expectRevert("NativeTokenTotalBalanceChangeEnforcer:exceeded-balance-decrease");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    // Validates that the total balance increase is correct with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 100 and one decreasing by 10. Total expected
    // balance change is an increase of at least 90.
    function test_mixed_enforcers_overall_increase() public {
        // Terms: [flag=false, recipient, amount=100]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(recipient), uint256(100));
        // Terms: [flag=true, recipient, amount=10]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(recipient), uint256(10));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        _increaseBalance(recipient, 90);
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    // Validates that the total balance decrease is correct with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 10 and one decreasing by 100. Total expected
    // balance change is a decrease of at most 90.
    function test_mixed_enforcers_overall_decrease() public {
        uint256 initialBalance_ = 100;
        vm.deal(recipient, initialBalance_);

        // Terms: [flag=false, recipient, amount=10]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(recipient), uint256(10));
        // Terms: [flag=true, recipient, amount=100]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(recipient), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        _decreaseBalance(recipient, 90);
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    // Reverts if the total balance increase is insufficient with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 100 and one decreasing by 10. Total expected
    // balance change is an increase of at least 90.
    function test_mixed_enforcers_insufficientIncrease() public {
        // Terms: [flag=false, recipient, amount=100]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(recipient), uint256(100));
        // Terms: [flag=true, recipient, amount=10]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(recipient), uint256(10));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        _increaseBalance(recipient, 89);
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        vm.expectRevert("NativeTokenTotalBalanceChangeEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    // Reverts if the total balance decrease is excessive with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 10 and one decreasing by 100. Total expected
    // balance change is a decrease of at most 90.
    function test_mixed_enforcers_excessiveDecrease() public {
        uint256 initialBalance_ = 100;
        vm.deal(recipient, initialBalance_);

        // Terms: [flag=false, recipient, amount=10]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(recipient), uint256(10));
        // Terms: [flag=true, recipient, amount=100]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(recipient), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        _decreaseBalance(recipient, 91);
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        vm.expectRevert("NativeTokenTotalBalanceChangeEnforcer:exceeded-balance-decrease");
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient, delegate);
    }

    ////////////////////////////// Redelegation Tests //////////////////////////////

    /**
     * @notice Test that redelegations with same type (decrease) are always more restrictive
     * @dev Verifies that each redelegation must have amount <= previous amount
     */
    function test_redelegation_decreaseType_alwaysMoreRestrictive() public {
        // Alice creates initial delegation allowing decrease by 1000
        bytes memory initialTerms = abi.encodePacked(true, address(delegator), uint256(1000));

        // Ensure initial balance is sufficient to avoid underflow when validating decrease
        vm.deal(delegator, 1000);

        // Simulate Alice's initial delegation (delegator must equal recipient for first delegation)
        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob tries to redelegate with same type but larger amount (should fail)
        bytes memory bobTerms = abi.encodePacked(true, address(delegator), uint256(1200));
        vm.prank(dm);
        vm.expectRevert("NativeTokenTotalBalanceChangeEnforcer:decrease-must-be-more-restrictive");
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Bob tries to redelegate with same type and smaller amount (should pass)
        bytes memory bobTermsRestrictive = abi.encodePacked(true, address(delegator), uint256(800));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTermsRestrictive, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Charlie tries to redelegate with even smaller amount (should pass)
        bytes memory charlieTerms = abi.encodePacked(true, address(delegator), uint256(500));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Verify final state: expectedDecrease should be 500 (most restrictive)
        bytes32 hashKey = enforcer.getHashKey(dm, address(delegator));
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedDecrease, 500, "Expected decrease should be most restrictive amount");
        assertEq(expectedIncrease, 0, "Expected increase should remain 0");

        // Clean up: run afterAll for each successful beforeAll
        vm.prank(dm);
        enforcer.afterAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));
        vm.prank(dm);
        enforcer.afterAllHook(bobTermsRestrictive, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));
        vm.prank(dm);
        enforcer.afterAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));
    }

    /**
     * @notice Test that redelegations with same type (increase) are always more restrictive
     * @dev Verifies that each redelegation must have amount >= previous amount
     */
    function test_redelegation_increaseType_alwaysMoreRestrictive() public {
        // Alice creates initial delegation requiring increase by 500
        bytes memory initialTerms = abi.encodePacked(false, address(delegator), uint256(500));

        // Simulate Alice's initial delegation
        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob tries to redelegate with same type but smaller amount (should fail)
        bytes memory bobTerms = abi.encodePacked(false, address(delegator), uint256(300));
        vm.prank(dm);
        vm.expectRevert("NativeTokenTotalBalanceChangeEnforcer:increase-must-be-more-restrictive");
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Bob tries to redelegate with same type and larger amount (should pass)
        bytes memory bobTermsRestrictive = abi.encodePacked(false, address(delegator), uint256(800));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTermsRestrictive, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Charlie tries to redelegate with even larger amount (should pass)
        bytes memory charlieTerms = abi.encodePacked(false, address(delegator), uint256(1200));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Verify final state: expectedIncrease should be 1200 (most restrictive)
        bytes32 hashKey = enforcer.getHashKey(dm, address(delegator));
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 1200, "Expected increase should be most restrictive amount");
        assertEq(expectedDecrease, 0, "Expected decrease should remain 0");

        // Satisfy net expected increase and clean up
        _increaseBalance(delegator, 1200);
        vm.prank(dm);
        enforcer.afterAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));
        vm.prank(dm);
        enforcer.afterAllHook(bobTermsRestrictive, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));
        vm.prank(dm);
        enforcer.afterAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));
    }

    /**
     * @notice Test that redelegations with type switching are always more restrictive
     * @dev Verifies that switching from decrease to increase or vice versa maintains restrictiveness
     */
    function test_redelegation_typeSwitching_alwaysMoreRestrictive() public {
        // Alice creates initial delegation allowing decrease by 1000
        bytes memory initialTerms = abi.encodePacked(true, address(delegator), uint256(1000));

        // Simulate Alice's initial delegation
        // Ensure initial balance is sufficient for decrease validation
        vm.deal(delegator, 1000);
        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob redelegates with type switch to increase (should pass - more restrictive)
        bytes memory bobTerms = abi.encodePacked(false, address(delegator), uint256(800));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Charlie tries to redelegate back to decrease with amount > original (should fail)
        bytes memory charlieTermsInvalid = abi.encodePacked(true, address(delegator), uint256(1200));
        vm.prank(dm);
        vm.expectRevert("NativeTokenTotalBalanceChangeEnforcer:decrease-must-be-more-restrictive");
        enforcer.beforeAllHook(charlieTermsInvalid, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Charlie redelegates back to decrease with amount <= original (should pass)
        bytes memory charlieTermsValid = abi.encodePacked(true, address(delegator), uint256(600));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTermsValid, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Verify final state: should have both constraints
        bytes32 hashKey = enforcer.getHashKey(dm, address(delegator));
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 800, "Expected increase should be preserved");
        assertEq(expectedDecrease, 600, "Expected decrease should be most restrictive");

        // Net expected increase is 200; satisfy and clean up
        _increaseBalance(delegator, 200);
        vm.prank(dm);
        enforcer.afterAllHook(charlieTermsValid, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));
        vm.prank(dm);
        enforcer.afterAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));
        vm.prank(dm);
        enforcer.afterAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));
    }

    /**
     * @notice Test complex redelegation chain to ensure restrictiveness is maintained
     * @dev Verifies that multiple redelegations with type switching maintain security
     */
    function test_redelegation_complexChain_alwaysMoreRestrictive() public {
        // Alice creates initial delegation allowing decrease by 1000
        bytes memory initialTerms = abi.encodePacked(true, address(delegator), uint256(1000));

        // Simulate Alice's initial delegation
        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Chain of redelegations: decrease -> increase -> decrease -> increase
        // Each should make constraints more restrictive

        // 1. Bob: decrease to 800 (more restrictive)
        bytes memory bobTerms = abi.encodePacked(true, address(delegator), uint256(800));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // 2. Charlie: switch to increase of 600 (more restrictive)
        bytes memory charlieTerms = abi.encodePacked(false, address(delegator), uint256(600));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // 3. David: switch back to decrease of 400 (more restrictive)
        bytes memory davidTerms = abi.encodePacked(true, address(delegator), uint256(400));
        vm.prank(dm);
        enforcer.beforeAllHook(davidTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x456), address(0));

        // 4. Eve: switch to increase of 1000 (more restrictive)
        bytes memory eveTerms = abi.encodePacked(false, address(delegator), uint256(1000));
        vm.prank(dm);
        enforcer.beforeAllHook(eveTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x789), address(0));

        // Verify final state: should have most restrictive constraints
        bytes32 hashKey = enforcer.getHashKey(dm, address(delegator));
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 1000, "Expected increase should be most restrictive");
        assertEq(expectedDecrease, 400, "Expected decrease should be most restrictive");

        // Net expected increase is 600; satisfy before running afterAlls
        _increaseBalance(delegator, 600);

        vm.prank(dm);
        enforcer.afterAllHook(eveTerms, hex"", singleDefaultMode, executionCallData, keccak256(""), address(0x789), address(0));

        vm.prank(dm);
        enforcer.afterAllHook(davidTerms, hex"", singleDefaultMode, executionCallData, keccak256(""), address(0x789), address(0));

        vm.prank(dm);
        enforcer.afterAllHook(charlieTerms, hex"", singleDefaultMode, executionCallData, keccak256(""), address(0x789), address(0));

        vm.prank(dm);
        enforcer.afterAllHook(bobTerms, hex"", singleDefaultMode, executionCallData, keccak256(""), address(0x789), address(0));

        vm.prank(dm);
        enforcer.afterAllHook(initialTerms, hex"", singleDefaultMode, executionCallData, keccak256(""), address(0x789), address(0));
    }

    /**
     * @notice Test that first delegation requires delegator == recipient
     * @dev Verifies the security fix that prevents delegation hijacking
     */
    function test_firstDelegation_requiresDelegatorEqualsRecipient() public {
        // Bob tries to create first delegation with delegator != recipient (should fail)
        bytes memory bobTerms = abi.encodePacked(true, address(someUser), uint256(1000));
        vm.prank(dm);
        vm.expectRevert("NativeTokenTotalBalanceChangeEnforcer:invalid-delegator");
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Alice creates first delegation with delegator == recipient (should pass)
        bytes memory aliceTerms = abi.encodePacked(true, address(someUser), uint256(1000));
        // Ensure initial balance is sufficient to validate decreases later
        vm.deal(someUser, 1000);
        vm.prank(dm);
        enforcer.beforeAllHook(aliceTerms, hex"", singleDefaultMode, hex"", keccak256(""), someUser, address(0));

        // Now Bob can redelegate with more restrictive constraints
        bytes memory bobRedelegationTerms = abi.encodePacked(true, address(someUser), uint256(500));
        vm.prank(dm);
        enforcer.beforeAllHook(bobRedelegationTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // // Verify final state
        bytes32 hashKey = enforcer.getHashKey(dm, someUser);
        (,, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedDecrease, 500, "Expected decrease should be most restrictive amount");

        vm.prank(dm);
        enforcer.afterAllHook(bobRedelegationTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        vm.prank(dm);
        enforcer.afterAllHook(aliceTerms, hex"", singleDefaultMode, hex"", keccak256(""), someUser, address(0));
    }

    /**
     * @notice Test that aggregations only happen when delegator == recipient
     * @dev Verifies that constraint aggregation is restricted to the resource owner
     */
    function test_aggregation_onlyWhenDelegatorEqualsRecipient() public {
        // Alice creates first delegation with delegator == recipient
        bytes memory initialTerms = abi.encodePacked(true, address(delegator), uint256(1000));
        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Alice creates another delegation with delegator == recipient (should aggregate)
        bytes memory aliceTerms2 = abi.encodePacked(false, address(delegator), uint256(500));
        vm.prank(dm);
        enforcer.beforeAllHook(aliceTerms2, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob tries to redelegate with delegator != recipient (should be more restrictive, not aggregate)
        bytes memory bobTerms = abi.encodePacked(true, address(delegator), uint256(300));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Verify final state: should have both constraints from Alice + Bob's restrictive constraint
        bytes32 hashKey = enforcer.getHashKey(dm, address(delegator));
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 500, "Expected increase should be from Alice's delegation");
        assertEq(expectedDecrease, 300, "Expected decrease should be Bob's restrictive constraint");

        // Net expected increase is 200; satisfy and clean up
        _increaseBalance(delegator, 200);
        vm.prank(dm);
        enforcer.afterAllHook(bobTerms, hex"", singleDefaultMode, executionCallData, keccak256(""), address(0x789), address(0));
        vm.prank(dm);
        enforcer.afterAllHook(aliceTerms2, hex"", singleDefaultMode, executionCallData, keccak256(""), address(0x789), address(0));
        vm.prank(dm);
        enforcer.afterAllHook(initialTerms, hex"", singleDefaultMode, executionCallData, keccak256(""), address(0x789), address(0));
    }

    ////////////////////////////// Check events //////////////////////////////

    // Validates that the events are emitted correctly for an increase scenario.
    function test_events_emitted_correctly() public {
        address recipient_ = delegator;
        // Increase by 100
        bytes memory terms_ = abi.encodePacked(false, recipient_, uint256(100));

        // First beforeAllHook - should emit TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit NativeTokenTotalBalanceChangeEnforcer.TrackedBalance(dm, recipient_, 100000000000000000000);
        vm.expectEmit(true, true, true, true);
        emit NativeTokenTotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, recipient_, false, 100);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient_, delegate);

        // Second beforeAllHook should ONLY emit UpdatedExpectedBalance
        vm.recordLogs();
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient_, delegate);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "Should only emit one event");

        // Verify it's the UpdatedExpectedBalance event
        assertEq(logs[0].topics[0], keccak256("UpdatedExpectedBalance(address,address,bool,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(dm)))); // delegationManager
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(recipient_))))); // recipient

        _increaseBalance(recipient_, 200);
     
        // First afterAllHook should not emit anything
        vm.recordLogs();
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient_, delegate);

        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        assertEq(logs2.length, 0, "Should not emit any events");

        // Second afterAllHook should emit ValidatedBalance
        vm.expectEmit(true, true, true, true);
        emit NativeTokenTotalBalanceChangeEnforcer.ValidatedBalance(dm, recipient_, 200);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient_, delegate);
    }

    // Validates that the events are emitted correctly for a decrease scenario.
    function test_events_emitted_correctly_with_decrease() public {
        address recipient_ = delegator;
        // Decrease by 100
        bytes memory terms_ = abi.encodePacked(true, recipient_, uint256(100));

        // First beforeAllHook - should emit TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit NativeTokenTotalBalanceChangeEnforcer.TrackedBalance(dm, recipient_, 100000000000000000000);
        vm.expectEmit(true, true, true, true);
        emit NativeTokenTotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, recipient_, true, 100);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient_, delegate);

        _decreaseBalance(recipient_, 100);

        // First afterAllHook - should emit ValidatedBalance
        vm.expectEmit(true, true, true, true);
        emit NativeTokenTotalBalanceChangeEnforcer.ValidatedBalance(dm, recipient_, 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient_, delegate);
    }

    ////////////////////////////// Integration tests //////////////////////////////

    /**
     * @notice Tests that if balance changes in the afterAllHook the last balance change after all hook will validate it.
     * @dev This test check with multiple delegation that the last balance change after all hook will validate it.
     * 1. Creates a delegation of total balance enforcer with a balance change up to 1 eth.
     * 2. Creates a NativeTokenPaymentEnforcer with 1 eth of payment.
     * 3. Creates a delegation of total balance enforcer with a balance change up to 1 eth.
     * When redeeming the whole delegation change we will also execute a transfer of 1.1 eth.
     * This should revert because the balance change is not enough to cover the 1.1 transfer + 1 eth of NativeTokenPaymentEnforcer.
     */
    function test_combination_with_payment_enforcer() public {
        // Set up initial balances
        vm.deal(address(users.bob.deleGator), 10 ether); // Give Bob some ETH for payments
        vm.deal(address(users.alice.deleGator), 100 ether); // Give Alice 100 ETH for balance tracking

        // Create batch delegations with multiple enforcers
        // 1. First delegation: NativeTokenTotalBalanceChangeEnforcer allowing balance decrease up to 1 ETH
        bytes memory balanceTerms1_ = abi.encodePacked(true, address(delegatorIntegration),uint256(1 ether));

        Caveat[] memory caveats1_ = new Caveat[](1);
        caveats1_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: balanceTerms1_ });

        Delegation memory delegation1_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegatorIntegration,
            authority: ROOT_AUTHORITY,
            caveats: caveats1_,
            salt: 0,
            signature: hex""
        });

        delegation1_ = signDelegation(users.alice, delegation1_);

        // 2. Second delegation: NativeTokenTotalBalanceChangeEnforcer allowing balance decrease up to 1 ETH
        bytes memory balanceTerms2_ = abi.encodePacked(true, address(delegatorIntegration), uint256(1 ether));

        Caveat[] memory caveats2_ = new Caveat[](1);
        caveats2_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: balanceTerms2_ });

        Delegation memory delegation2_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegatorIntegration,
            authority: ROOT_AUTHORITY,
            caveats: caveats2_,
            salt: 1,
            signature: hex""
        });

        delegation2_ = signDelegation(users.alice, delegation2_);
     
         // 3. Third delegation: NativeTokenPaymentEnforcer requiring 1 ETH payment
        bytes memory paymentTerms_ = abi.encodePacked(address(0x1337), uint256(1 ether)); // Payment goes to 0x1337, not to Alice

        Caveat[] memory caveats3_ = new Caveat[](1);
        caveats3_[0] = Caveat({ args: hex"", enforcer: address(nativeTokenPaymentEnforcer), terms: paymentTerms_ });

        Delegation memory delegation3_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegatorIntegration,
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
        allowanceCaveats_[1] = Caveat({ 
            args: hex"", 
            enforcer: address(nativeTokenTransferAmountEnforcer), 
            terms: abi.encode(uint256(1 ether)) 
        });

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

        // Create execution that will transfer 0.4 ETH worth of native tokens (with 3 execution we get total of 1.2 ETH)
        // This plus the 1 ETH payment from the native payment enforcer = 2.2 ETH, which exceeds the allowed balance change of 2 ETH
        Execution memory executionValue_ = Execution({
            target: address(0xBEEF), // Target some external address to transfer ETH from Alice's balance
            value: uint256(0.4 ether),
            callData: hex""
        });

        // Create the delegation array for batch processing - order is important if native token payment enforcer
        // is between the two balance change enforcers it should be enforced first
        Delegation[][] memory delegations_ = new Delegation[][](3);
        delegations_[0] = new Delegation[](1);
        delegations_[0][0] = delegation1_;
        delegations_[1] = new Delegation[](1);
        delegations_[1][0] = delegation3_;
        delegations_[2] = new Delegation[](1);
        delegations_[2][0] = delegation2_;

        // Execute the delegations using batch processing
        bytes[] memory permissionContexts_ = new bytes[](3);
        permissionContexts_[0] = abi.encode(delegations_[0]);
        permissionContexts_[1] = abi.encode(delegations_[1]);
        permissionContexts_[2] = abi.encode(delegations_[2]);

        ModeCode[] memory encodedModes_ = new ModeCode[](3);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();
        encodedModes_[1] = ModeLib.encodeSimpleSingle();
        encodedModes_[2] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](3);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(executionValue_.target, executionValue_.value, executionValue_.callData);
        executionCallDatas_[1] = ExecutionLib.encodeSingle(executionValue_.target, executionValue_.value, executionValue_.callData);
        executionCallDatas_[2] = ExecutionLib.encodeSingle(executionValue_.target, executionValue_.value, executionValue_.callData);

        // This should revert because the total balance change allowed is 2 ETH (1 + 1) but we're trying to transfer 1.2 ETH
        // plus the 1 ETH payment from the native payment enforcer = 2.2 ETH, which exceeds the allowed balance change
        // Since delegator == recipient for all balance change enforcers, they should aggregate and catch this
        vm.expectRevert("NativeTokenTotalBalanceChangeEnforcer:exceeded-balance-decrease");
        vm.prank(address(users.bob.deleGator)); // Prank to Bob's address so he can use the delegation
        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);
    }

    ////////////////////////////// Helper functions //////////////////////////////

    function _increaseBalance(address _recipient, uint256 _amount) internal {
        vm.deal(_recipient, _recipient.balance + _amount);
    }

    function _decreaseBalance(address _recipient, uint256 _amount) internal {
        vm.deal(_recipient, _recipient.balance - _amount);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
