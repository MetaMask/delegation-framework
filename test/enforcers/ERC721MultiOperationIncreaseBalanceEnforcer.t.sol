// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicCF721 } from "../utils/BasicCF721.t.sol";

import { Execution, Caveat, Delegation, ModeCode, CallType, ExecType } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

import { ERC721MultiOperationIncreaseBalanceEnforcer } from "../../src/enforcers/ERC721MultiOperationIncreaseBalanceEnforcer.sol";
import { ExactCalldataEnforcer } from "../../src/enforcers/ExactCalldataEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { ModeLib, CALLTYPE_SINGLE, EXECTYPE_DEFAULT } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";

contract ERC721MultiOperationIncreaseBalanceEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC721MultiOperationIncreaseBalanceEnforcer public enforcer;
    ExactCalldataEnforcer public exactCalldataEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    ValueLteEnforcer public valueLteEnforcer;

    BasicCF721 public token;
    BasicCF721 public tokenB;

    address delegator;
    address delegate;
    address dm;

    Execution mintExecution;
    bytes mintExecutionCallData;

    ////////////////////////////// Set up //////////////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        dm = address(delegationManager);
        vm.label(address(enforcer), "ERC721 Balance Change Enforcer");
        vm.label(address(token), "ERC721 Test Token");
        mintExecution =
            Execution({ target: address(token), value: 0, callData: abi.encodeWithSelector(token.mint.selector, delegator) });
        mintExecutionCallData = abi.encode(mintExecution);

        // deploy enforcers
        enforcer = new ERC721MultiOperationIncreaseBalanceEnforcer();
        exactCalldataEnforcer = new ExactCalldataEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();

        // Deploy test tokens
        tokenB = new BasicCF721(delegate, "TokenB", "TKB", "");
        token = new BasicCF721(delegator, "TEST", "TEST", "");
    }

    ////////////////////////////// Helper Functions //////////////////////////////

    /**
     * @notice Helper function to mint tokens to a specified address
     * @param to The address to mint tokens to
     * @param count The number of tokens to mint
     */
    function _mintTokens(address to, uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            vm.prank(delegator);
            token.mint(to);
        }
    }

    ////////////////////////////// Basic Functionality //////////////////////////////

    // Validates the terms get decoded correctly for an increase scenario
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));
        (address token_, address recipient_, uint256 amount_) = enforcer.getTermsInfo(terms_);
        assertEq(token_, address(token));
        assertEq(recipient_, address(delegator));
        assertEq(amount_, 1);
    }

    // Validates that getHashKey function returns the correct hash
    function test_getHashKey() public {
        address caller_ = address(dm);
        address token_ = address(token);
        address recipient_ = address(delegator);

        bytes32 expectedHash_ = keccak256(abi.encode(caller_, token_, recipient_));
        bytes32 actualHash_ = enforcer.getHashKey(caller_, token_, recipient_);

        assertEq(actualHash_, expectedHash_, "getHashKey should return correct hash");
    }

    // Validates that a balance has increased at least the expected amount
    function test_allow_ifBalanceIncreases() public {
        // Terms: [token, recipient, amount=1]
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        // Increase by 1 - First delegation
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        _mintTokens(delegator, 1);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Increase by 1 again - Subsequent delegation (aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        _mintTokens(delegator, 1);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that a delegation can be reused with different recipients (for increase) without interference
    function test_allow_reuseDelegationWithDifferentRecipients() public {
        // Terms for two different recipients
        bytes memory terms1_ = abi.encodePacked(address(token), address(delegator), uint256(1));
        bytes memory terms2_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        // Increase for delegator - First delegation
        vm.prank(dm);
        enforcer.beforeAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        _mintTokens(delegator, 1);
        vm.prank(dm);
        enforcer.afterAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Increase for delegator as recipient - First delegation (aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        _mintTokens(delegator, 1);
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if an increase hasn't been sufficient
    function test_notAllow_insufficientIncrease() public {
        // Terms: required increase of 1 token
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        // No minting occurs here, so balance remains unchanged.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if no increase happens when one is expected
    function test_notAllow_noIncreaseToRecipient() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        // Cache the initial balance - First delegation
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Do not modify recipient's balance.
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that balance changes between beforeAllHook calls are allowed and validated in the last afterAllHook call
    function test_allow_balanceChangedBetweenBeforeAllHookCalls() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        // First beforeAllHook call - caches the initial balance - First delegation
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Modify the recipient's balance between beforeAllHook calls - this should be allowed
        _mintTokens(delegator, 1);

        // Second beforeAllHook call - should now succeed and track the new balance (aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Verify that the balance tracker is properly updated
        bytes32 hashKey_ = keccak256(abi.encode(address(dm), address(token), address(delegator)));
        (uint256 balanceBefore_, uint256 expectedIncrease_, uint256 validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 0, "balanceBefore should be same as initial balance");
        assertEq(expectedIncrease_, 2, "expectedIncrease should be 2 (1 + 1)");
        assertEq(validationRemaining_, 2, "validationRemaining should be 2");

        // Mint additional tokens to satisfy the total requirement (already have 1, need 1 more)
        _mintTokens(delegator, 1);

        // First afterAllHook call - should not trigger balance check yet
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Second afterAllHook call - should trigger balance check and cleanup
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that balance check happens in the last afterAllHook call
    function test_balanceCheck_lastAfterAllHook() public {
        // Terms: [token, recipient, amount=1] - expecting balance increase
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));
        bytes32 hashKey_ = keccak256(abi.encode(address(dm), address(token), address(delegator)));

        // First beforeAllHook call
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Check validationRemaining after first beforeAllHook
        (,, uint256 validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 1, "validationRemaining should be 1 after first beforeAllHook");

        // Second beforeAllHook call (aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Check validationRemaining after second beforeAllHook
        (,, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 2, "validationRemaining should be 2 after second beforeAllHook");

        // Mint tokens to recipient to satisfy the balance requirement
        _mintTokens(delegator, 2);

        // First afterAllHook call - should not trigger balance check yet
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Check validationRemaining after first afterAllHook
        (,, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 1, "validationRemaining should be 1 after first afterAllHook");

        // Verify balance tracker still exists (not cleaned up yet)
        (uint256 balanceBefore_, uint256 expectedIncrease_,) = enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 0, "balanceBefore should still be tracked");
        assertEq(expectedIncrease_, 2, "expectedIncrease should be 2 (1 + 1)");

        // Second afterAllHook call - should trigger balance check and cleanup
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Verify balance tracker is cleaned up (deleted)
        (balanceBefore_, expectedIncrease_, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 0, "balanceBefore should be 0 after cleanup");
        assertEq(expectedIncrease_, 0, "expectedIncrease should be 0 after cleanup");
        assertEq(validationRemaining_, 0, "validationRemaining should be 0 after cleanup");
    }

    // Validates that the terms are well formed (exactly 72 bytes)
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small: missing required bytes (should be 72 bytes)
        terms_ = abi.encodePacked(address(token), address(delegator), uint8(1));
        vm.expectRevert(bytes("ERC721MultiOperationIncreaseBalanceEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large: extra bytes beyond 72
        terms_ = abi.encodePacked(address(token), address(delegator), uint256(1), uint256(1));
        vm.expectRevert(bytes("ERC721MultiOperationIncreaseBalanceEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address (address(0)) reverts when calling beforeAllHook.
    function test_invalid_tokenAddress() public {
        bytes memory terms_ = abi.encodePacked(address(0), address(delegator), uint256(1));
        vm.expectRevert();
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts when the balance increase triggers an overflow.
    function test_notAllow_expectingOverflow() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // This should revert due to overflow in balance calculation
        vm.expectRevert();

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts when the balance increase triggers an overflow.
    function test_balanceTracker_clean() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));
        bytes32 hash_ = keccak256(abi.encode(address(dm), address(token), address(delegator)));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        (, uint256 expectedIncrease_,) = enforcer.balanceTracker(hash_);
        assertEq(expectedIncrease_, 1);

        _mintTokens(delegator, 1);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        (, expectedIncrease_,) = enforcer.balanceTracker(hash_);
        assertEq(expectedIncrease_, 0);
    }

    // Reverts if the execution mode is invalid (not default).
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeAllHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    // Reverts if amount is 0
    function test_revertWithZeroAmount() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(0));
        vm.prank(address(dm));
        vm.expectRevert("ERC721MultiOperationIncreaseBalanceEnforcer:zero-expected-change-amount");
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////// Multiple enforcer in delegation chain Functionality //////////////////////////////

    // Reverts if the total balance increase is insufficient.
    // We are running 3 enforcers in the delegation chain: all increasing by 1. Total expected balance change is an
    // increase of at least 3.
    function test_multiple_enforcers_insufficient_increase() public {
        // Terms: [token, recipient, amount=1]
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        _mintTokens(delegator, 2);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that pre-existing balances are considered when calculating required increases
    function test_notAllow_withPreExistingBalance() public {
        // Recipient already has 1 token
        _mintTokens(delegator, 1);

        // Expect balance to increase by at least 1 token
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // No additional minting occurs, so balance remains unchanged
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that different delegation hashes with different recipients are handled separately
    function test_differentiateDelegationHashWithRecipient() public {
        bytes32 delegationHash1_ = bytes32(uint256(99999999));
        bytes32 delegationHash2_ = bytes32(uint256(88888888));

        address recipient1_ = delegator;
        address recipient2_ = address(users.carol.deleGator);

        // Terms for two different recipients
        bytes memory terms1_ = abi.encodePacked(address(token), address(recipient1_), uint256(1));
        bytes memory terms2_ = abi.encodePacked(address(token), address(recipient2_), uint256(1));

        // First delegation for recipient1
        vm.prank(dm);
        enforcer.beforeAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash1_, recipient1_, delegate);

        // First delegation for recipient2
        vm.prank(dm);
        enforcer.beforeAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash2_, recipient2_, delegate);

        // Mint 1 token only for recipient1
        _mintTokens(recipient1_, 1);

        // Recipient1 passes
        vm.prank(dm);
        enforcer.afterAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash1_, recipient1_, delegate);

        // Recipient2 did not receive tokens, so it should revert
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash2_, recipient2_, delegate);

        // Mint 1 token for recipient2
        _mintTokens(recipient2_, 1);

        // Recipient2 now passes
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash2_, recipient2_, delegate);
    }

    ////////////////////////////// Check events //////////////////////////////

    // Validates that the events are emitted correctly for an increase scenario.
    function test_events_emitted_correctly() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        // First beforeAllHook - should emit both TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC721MultiOperationIncreaseBalanceEnforcer.TrackedBalance(dm, delegator, address(token), 0);
        vm.expectEmit(true, true, true, true);
        emit ERC721MultiOperationIncreaseBalanceEnforcer.UpdatedExpectedBalance(dm, delegator, address(token), 1);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Second beforeAllHook should ONLY emit UpdatedExpectedBalance, NOT TrackedBalance
        vm.recordLogs();

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Check the logs to ensure only UpdatedExpectedBalance was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "Should only emit one event");
        assertEq(logs[0].topics[0], keccak256("UpdatedExpectedBalance(address,address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(dm)))); // delegationManager
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(delegator))))); // recipient
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(address(token))))); // token

        // Perform the balance change
        _mintTokens(delegator, 2);

        // First afterAllHook - should not emit any events
        vm.recordLogs();
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        Vm.Log[] memory afterAllLogs = vm.getRecordedLogs();
        assertEq(afterAllLogs.length, 0, "Should not emit any events");

        // Second afterAllHook - should emit ValidatedBalance
        vm.prank(dm);
        vm.expectEmit(true, true, true, true);
        emit ERC721MultiOperationIncreaseBalanceEnforcer.ValidatedBalance(dm, delegator, address(token), 2);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
