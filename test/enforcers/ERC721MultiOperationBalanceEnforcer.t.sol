// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicCF721 } from "../utils/BasicCF721.t.sol";

import { Execution, Caveat, Delegation, ModeCode, CallType, ExecType } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

import { ERC721MultiOperationBalanceEnforcer } from "../../src/enforcers/ERC721MultiOperationBalanceEnforcer.sol";
import { ExactCalldataEnforcer } from "../../src/enforcers/ExactCalldataEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { ModeLib, CALLTYPE_SINGLE, EXECTYPE_DEFAULT } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";

contract ERC721MultiOperationBalanceEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC721MultiOperationBalanceEnforcer public enforcer;
    ExactCalldataEnforcer public exactCalldataEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    ValueLteEnforcer public valueLteEnforcer;

    BasicCF721 public token;
    BasicCF721 public tokenB;

    address delegator;
    address delegate;
    address recipient;
    address someUser;
    address dm;

    Execution mintExecution;
    bytes mintExecutionCallData;

    ////////////////////////////// Set up //////////////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        recipient = address(users.carol.deleGator);
        someUser = address(users.dave.deleGator);
        dm = address(delegationManager);
        vm.label(address(enforcer), "ERC721 Balance Change Enforcer");
        vm.label(address(token), "ERC721 Test Token");
        mintExecution =
            Execution({ target: address(token), value: 0, callData: abi.encodeWithSelector(token.mint.selector, delegator) });
        mintExecutionCallData = abi.encode(mintExecution);

        // deploy enforcers
        enforcer = new ERC721MultiOperationBalanceEnforcer();
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
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));
        (bool enforceDecrease_, address token_, address recipient_, uint256 amount_) = enforcer.getTermsInfo(terms_);
        assertEq(enforceDecrease_, false);
        assertEq(token_, address(token));
        assertEq(recipient_, address(recipient));
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
        // Terms: [flag=false, token, recipient, amount=1]
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));

        // Increase by 1 - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        _mintTokens(recipient, 1);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Increase by 1 again - Subsequent delegation: delegator == recipient (aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        _mintTokens(recipient, 1);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    // Validates that a delegation can be reused with different recipients (for increase) without interference
    function test_allow_reuseDelegationWithDifferentRecipients() public {
        // Terms for two different recipients (flag=false indicates increase expected)
        bytes memory terms1_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));
        bytes memory terms2_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        // Increase for recipient - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        _mintTokens(recipient, 1);
        vm.prank(dm);
        enforcer.afterAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Increase for delegator as recipient - First delegation: delegator == delegator (aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        _mintTokens(delegator, 1);
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that a balance decrease within the allowed range passes.
    // For decreases (flag = true), the enforcer now checks that the final balance is not below the cached balance minus the
    // allowed amount.
    // Example: if the cached balance is 2 and the allowed decrease is 1, the final balance must be at least 1.
    function test_allow_ifBalanceDoesNotDecreaseTooMuch() public {
        // Set an initial balance for the recipient.
        _mintTokens(recipient, 2);
        uint256 initialBalance_ = token.balanceOf(recipient);
        assertEq(initialBalance_, 2);

        // Terms: flag=true (decrease expected), token, recipient, allowed decrease amount = 1.
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(1));

        // Cache the initial balance via beforeAllHook - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Simulate a decrease by transferring out 1 token (final balance becomes 1, which is >= 1)
        uint256 tokenIdToTransfer_ = token.tokenId() - 1;
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenIdToTransfer_);

        // afterAllHook should pass since 1 >= 1.
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    // Reverts if the balance decreases too much (i.e. final balance falls below cached balance - allowed amount)
    function test_notAllow_excessiveDecrease() public {
        uint256 initialBalance_ = 2;
        _mintTokens(recipient, 2);
        assertEq(token.balanceOf(recipient), initialBalance_);

        // Terms: flag=true (decrease expected), token, recipient, allowed maximum decrease = 1.
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Simulate an excessive decrease: transfer out 2 tokens (final balance becomes 0, which is below 2 - 1).
        uint256 tokenId1 = token.tokenId() - 2;
        uint256 tokenId2 = token.tokenId() - 1;
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenId1);
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenId2);

        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:exceeded-balance-decrease");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    // Reverts if an increase hasn't been sufficient
    function test_notAllow_insufficientIncrease() public {
        // Terms: flag=false (increase expected), required increase of 1 token.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));

        // No minting occurs here, so balance remains unchanged.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    // Reverts if no increase happens when one is expected
    function test_notAllow_noIncreaseToRecipient() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));

        // Cache the initial balance - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Do not modify recipient's balance.
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    // Validates that balance changes between beforeAllHook calls are allowed and validated in the last afterAllHook call
    function test_allow_balanceChangedBetweenBeforeAllHookCalls() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));

        // First beforeAllHook call - caches the initial balance - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Modify the recipient's balance between beforeAllHook calls - this should be allowed
        _mintTokens(recipient, 1);

        // Second beforeAllHook call - should now succeed and track the new balance (delegator == recipient for aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Verify that the balance tracker is properly updated
        bytes32 hashKey_ = keccak256(abi.encode(address(dm), address(token), address(recipient)));
        (uint256 balanceBefore_, uint256 expectedIncrease_, uint256 expectedDecrease_, uint256 validationRemaining_) =
            enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 0, "balanceBefore should be same as initial balance");
        assertEq(expectedIncrease_, 2, "expectedIncrease should be 2 (1 + 1)");
        assertEq(expectedDecrease_, 0, "expectedDecrease should be 0");
        assertEq(validationRemaining_, 2, "validationRemaining should be 2");

        // Mint additional tokens to satisfy the total requirement (already have 1, need 1 more)
        _mintTokens(recipient, 1);

        // First afterAllHook call - should not trigger balance check yet
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Second afterAllHook call - should trigger balance check and cleanup
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that balance check happens in the last afterAllHook call
    function test_balanceCheck_lastAfterAllHook() public {
        // Terms: [flag=false, token, recipient, amount=1] - expecting balance increase
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));
        bytes32 hashKey_ = keccak256(abi.encode(address(dm), address(token), address(recipient)));

        // First beforeAllHook call
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Check validationRemaining after first beforeAllHook
        (,,, uint256 validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 1, "validationRemaining should be 1 after first beforeAllHook");

        // Second beforeAllHook call (delegator == recipient for aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Check validationRemaining after second beforeAllHook
        (,,, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 2, "validationRemaining should be 2 after second beforeAllHook");

        // Mint tokens to recipient to satisfy the balance requiremen
        _mintTokens(recipient, 2);

        // First afterAllHook call - should not trigger balance check yet
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Check validationRemaining after first afterAllHook
        (,,, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(validationRemaining_, 1, "validationRemaining should be 1 after first afterAllHook");

        // Verify balance tracker still exists (not cleaned up yet)
        (uint256 balanceBefore_, uint256 expectedIncrease_, uint256 expectedDecrease_,) = enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 0, "balanceBefore should still be tracked");
        assertEq(expectedIncrease_, 2, "expectedIncrease should be 2 (1 + 1)");
        assertEq(expectedDecrease_, 0, "expectedDecrease should be 0");

        // Second afterAllHook call - should trigger balance check and cleanup
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Verify balance tracker is cleaned up (deleted)
        (balanceBefore_, expectedIncrease_, expectedDecrease_, validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 0, "balanceBefore should be 0 after cleanup");
        assertEq(expectedIncrease_, 0, "expectedIncrease should be 0 after cleanup");
        assertEq(expectedDecrease_, 0, "expectedDecrease should be 0 after cleanup");
        assertEq(validationRemaining_, 0, "validationRemaining should be 0 after cleanup");
    }

    // Validates that the terms are well formed (exactly 73 bytes)
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small: missing required bytes (should be 73 bytes)
        terms_ = abi.encodePacked(false, address(token), address(recipient), uint8(1));
        vm.expectRevert(bytes("ERC721MultiOperationBalanceEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large: extra bytes beyond 73.
        terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(1), uint256(1));
        vm.expectRevert(bytes("ERC721MultiOperationBalanceEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address (address(0)) reverts when calling beforeAllHook.
    function test_invalid_tokenAddress() public {
        bytes memory terms_ = abi.encodePacked(false, address(0), address(recipient), uint256(1));
        vm.expectRevert();
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts when the balance increase triggers an overflow.
    function test_notAllow_expectingOverflow() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.expectRevert();

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    // Reverts when the balance increase triggers an overflow.
    function test_balanceTracker_clean() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));
        bytes32 hash_ = keccak256(abi.encode(address(dm), address(token), address(recipient)));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        (, uint256 expectedIncrease_,,) = enforcer.balanceTracker(hash_);
        assertEq(expectedIncrease_, 1);

        _mintTokens(recipient, 1);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        (, expectedIncrease_,,) = enforcer.balanceTracker(hash_);
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
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(0));
        vm.prank(address(dm));
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:zero-expected-change-amount");
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////// Multiple enforcer in delegation chain Functionality //////////////////////////////

    // Reverts if the total balance increase is insufficient.
    // We are running 3 enforcers in the delegation chain: all increasing by 1. Total expected balance change is an
    // increase of at least 3.
    function test_multiple_enforcers_insufficient_increase() public {
        // Terms: [flag=false, token, recipient, amount=1]
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        _mintTokens(recipient, 2);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    // Validates that the total balance decrease is correct with multiple decrease enforcers.
    // We are running 2 enforcers in the delegation chain: both decreasing by 1. Total expected balance change is a
    // decrease of at most 2.
    function test_multiple_enforcers_decrease() public {
        uint256 initialBalance_ = 3;
        _mintTokens(recipient, 3);
        assertEq(token.balanceOf(recipient), initialBalance_);

        // Terms: [flag=true, token, recipient, amount=1]
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        uint256 tokenId1 = token.tokenId() - 2;
        uint256 tokenId2 = token.tokenId() - 1;
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenId1);
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenId2);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        // calling afterAllHook for each beforeAllHook
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    // Reverts if the total balance decrease is excessive with multiple decrease enforcers.
    // We are running 2 enforcers in the delegation chain: both decreasing by 1. Total expected balance change is a
    // decrease of at most 2.
    function test_multiple_enforcers_excessiveDecrease() public {
        uint256 initialBalance_ = 3;
        _mintTokens(recipient, 3);
        assertEq(token.balanceOf(recipient), initialBalance_);

        // Terms: [flag=true, token, recipient, amount=1]
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        uint256 tokenId1 = token.tokenId() - 3;
        uint256 tokenId2 = token.tokenId() - 2;
        uint256 tokenId3 = token.tokenId() - 1;
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenId1);
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenId2);
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenId3);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:exceeded-balance-decrease");
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    // Validates that the total balance increase is correct with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 1 and one decreasing by 1. Total expected
    // balance change is an increase of at least 0.
    function test_mixed_enforcers_overall_increase() public {
        // Terms: [flag=false, token, recipient, amount=1]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));
        // Terms: [flag=true, token, recipient, amount=1]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(recipient), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        _mintTokens(recipient, 1);
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that the total balance decrease is correct with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 1 and one decreasing by 2. Total expected
    // balance change is a decrease of at most 1.
    function test_mixed_enforcers_overall_decrease() public {
        uint256 initialBalance_ = 2;
        _mintTokens(recipient, 2);
        assertEq(token.balanceOf(recipient), initialBalance_);

        // Terms: [flag=false, token, recipient, amount=1]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));
        // Terms: [flag=true, token, recipient, amount=2]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(recipient), uint256(2));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        uint256 tokenId1 = token.tokenId() - 1;
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenId1);
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the total balance increase is insufficient with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 2 and one decreasing by 1. Total expected
    // balance change is an increase of at least 1.
    function test_mixed_enforcers_insufficientIncrease() public {
        // Terms: [flag=false, token, recipient, amount=2]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(recipient), uint256(2));
        // Terms: [flag=true, token, recipient, amount=1]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(recipient), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // First call afterAllHook for the increase terms (should pass)
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Then call afterAllHook for the decrease terms (should fail due to insufficient increase)
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    // Reverts if the total balance decrease is excessive with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: one increasing by 1 and one decreasing by 2. Total expected
    // balance change is a decrease of at most 1.
    function test_mixed_enforcers_excessiveDecrease() public {
        uint256 initialBalance_ = 2;
        _mintTokens(recipient, 2);
        assertEq(token.balanceOf(recipient), initialBalance_);

        // Terms: [flag=false, token, recipient, amount=1]
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));
        // Terms: [flag=true, token, recipient, amount=2]
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(recipient), uint256(2));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Transfer out both tokens (decrease by 2)
        uint256 tokenId1 = token.tokenId() - 1;
        uint256 tokenId2 = token.tokenId() - 2;
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenId1);
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenId2);

        // First call afterAllHook for the increase terms (should pass)
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Then call afterAllHook for the decrease terms (should fail due to excessive decrease)
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:exceeded-balance-decrease");
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    ////////////////////////////// Check events //////////////////////////////

    // Validates that the events are emitted correctly for an increase scenario.
    function test_events_emitted_correctly() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(1));

        // First beforeAllHook - should emit both TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC721MultiOperationBalanceEnforcer.TrackedBalance(dm, recipient, address(token), 0);
        vm.expectEmit(true, true, true, true);
        emit ERC721MultiOperationBalanceEnforcer.UpdatedExpectedBalance(dm, recipient, address(token), false, 1);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Second beforeAllHook should ONLY emit UpdatedExpectedBalance, NOT TrackedBalance
        vm.recordLogs();

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Check the logs to ensure only UpdatedExpectedBalance was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "Should only emit one event");
        assertEq(logs[0].topics[0], keccak256("UpdatedExpectedBalance(address,address,address,bool,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(dm)))); // delegationManager
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(recipient))))); // recipient
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(address(token))))); // token

        // Perform the balance change
        _mintTokens(recipient, 2);

        // First afterAllHook - should not emit any events
        vm.recordLogs();
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
        Vm.Log[] memory afterAllLogs = vm.getRecordedLogs();
        assertEq(afterAllLogs.length, 0, "Should not emit any events");

        // Second afterAllHook - should emit ValidatedBalance
        vm.prank(dm);
        vm.expectEmit(true, true, true, true);
        emit ERC721MultiOperationBalanceEnforcer.ValidatedBalance(dm, recipient, address(token), 2);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    // Test events for decrease scenario
    function test_events_emitted_correctly_decrease() public {
        uint256 initialBalance_ = 2;
        _mintTokens(recipient, 2);

        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(1));

        // Test TrackedBalance and UpdatedExpectedBalance events for decrease
        vm.expectEmit(true, true, true, true);
        emit ERC721MultiOperationBalanceEnforcer.TrackedBalance(dm, recipient, address(token), 2);
        vm.expectEmit(true, true, true, true);
        emit ERC721MultiOperationBalanceEnforcer.UpdatedExpectedBalance(dm, recipient, address(token), true, 1);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);

        // Perform allowed decrease
        uint256 tokenIdToTransfer_ = token.tokenId() - 1;
        vm.prank(recipient);
        token.transferFrom(recipient, delegator, tokenIdToTransfer_);

        // Test ValidatedBalance event for decrease
        vm.prank(dm);
        vm.expectEmit(true, true, true, true);
        emit ERC721MultiOperationBalanceEnforcer.ValidatedBalance(dm, recipient, address(token), 1);

        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient, delegate);
    }

    ////////////////////////////// Redelegation Tests //////////////////////////////

    /**
     * @notice Test that redelegations with same type (decrease) are always more restrictive
     * @dev Verifies that each redelegation must have amount <= previous amount
     */
    function test_redelegation_decreaseType_alwaysMoreRestrictive() public {
        // Alice creates initial delegation allowing decrease by 10
        bytes memory initialTerms = abi.encodePacked(true, address(token), address(delegator), uint256(10));

        // Ensure initial balance is sufficient to avoid underflow when validating decrease
        _mintTokens(delegator, 10);

        // Simulate Alice's initial delegation (delegator must equal recipient for first delegation)
        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob tries to redelegate with same type but larger amount (should fail)
        bytes memory bobTerms = abi.encodePacked(true, address(token), address(delegator), uint256(12));
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:decrease-must-be-more-restrictive");
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Bob tries to redelegate with same type and smaller amount (should pass)
        bytes memory bobTermsRestrictive = abi.encodePacked(true, address(token), address(delegator), uint256(8));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTermsRestrictive, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Charlie tries to redelegate with even smaller amount (should pass)
        bytes memory charlieTerms = abi.encodePacked(true, address(token), address(delegator), uint256(5));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Verify final state: expectedDecrease should be 5 (most restrictive)
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), address(delegator));
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedDecrease, 5, "Expected decrease should be most restrictive amount");
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
        // Alice creates initial delegation requiring increase by 5
        bytes memory initialTerms = abi.encodePacked(false, address(token), address(delegator), uint256(5));

        // Simulate Alice's initial delegation
        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob tries to redelegate with same type but smaller amount (should fail)
        bytes memory bobTerms = abi.encodePacked(false, address(token), address(delegator), uint256(3));
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:increase-must-be-more-restrictive");
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Bob tries to redelegate with same type and larger amount (should pass)
        bytes memory bobTermsRestrictive = abi.encodePacked(false, address(token), address(delegator), uint256(8));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTermsRestrictive, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Charlie tries to redelegate with even larger amount (should pass)
        bytes memory charlieTerms = abi.encodePacked(false, address(token), address(delegator), uint256(12));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Verify final state: expectedIncrease should be 12 (most restrictive)
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), address(delegator));
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 12, "Expected increase should be most restrictive amount");
        assertEq(expectedDecrease, 0, "Expected decrease should remain 0");

        // Satisfy net expected increase and clean up
        _mintTokens(delegator, 12);

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
        // Alice creates initial delegation allowing decrease by 10
        bytes memory initialTerms = abi.encodePacked(true, address(token), address(delegator), uint256(10));

        // Simulate Alice's initial delegation
        // Ensure initial balance is sufficient for decrease validation
        _mintTokens(delegator, 10);

        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob redelegates with type switch to increase (should pass - more restrictive)
        bytes memory bobTerms = abi.encodePacked(false, address(token), address(delegator), uint256(8));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Charlie tries to redelegate back to decrease with amount > original (should fail)
        bytes memory charlieTermsInvalid = abi.encodePacked(true, address(token), address(delegator), uint256(12));
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:decrease-must-be-more-restrictive");
        enforcer.beforeAllHook(charlieTermsInvalid, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Charlie redelegates back to decrease with amount <= original (should pass)
        bytes memory charlieTermsValid = abi.encodePacked(true, address(token), address(delegator), uint256(6));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTermsValid, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Verify final state: should have both constraints
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), address(delegator));
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 8, "Expected increase should be preserved");
        assertEq(expectedDecrease, 6, "Expected decrease should be most restrictive");

        // Net expected increase is 200; satisfy and clean up
        _mintTokens(delegator, 2);

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
        // Alice creates initial delegation allowing decrease by 10
        bytes memory initialTerms = abi.encodePacked(true, address(token), address(delegator), uint256(10));

        // Simulate Alice's initial delegation
        _mintTokens(delegator, 10);

        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Chain of redelegations: decrease -> increase -> decrease -> increase
        // Each should make constraints more restrictive

        // 1. Bob: decrease to 800 (more restrictive)
        bytes memory bobTerms = abi.encodePacked(true, address(token), address(delegator), uint256(8));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // 2. Charlie: switch to increase of 600 (more restrictive)
        bytes memory charlieTerms = abi.encodePacked(false, address(token), address(delegator), uint256(6));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // 3. David: switch back to decrease of 400 (more restrictive)
        bytes memory davidTerms = abi.encodePacked(true, address(token), address(delegator), uint256(4));
        vm.prank(dm);
        enforcer.beforeAllHook(davidTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x456), address(0));

        // 4. Eve: switch to increase of 1000 (more restrictive)
        bytes memory eveTerms = abi.encodePacked(false, address(token), address(delegator), uint256(10));
        vm.prank(dm);
        enforcer.beforeAllHook(eveTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x789), address(0));

        // Verify final state: should have most restrictive constraints
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), address(delegator));
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 10, "Expected increase should be most restrictive");
        assertEq(expectedDecrease, 4, "Expected decrease should be most restrictive");

        // Net expected increase is 6; satisfy before running afterAlls
        _mintTokens(delegator, 6);

        vm.prank(dm);
        enforcer.afterAllHook(eveTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x789), address(0));

        vm.prank(dm);
        enforcer.afterAllHook(davidTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x456), address(0));

        vm.prank(dm);
        enforcer.afterAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        vm.prank(dm);
        enforcer.afterAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        vm.prank(dm);
        enforcer.afterAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));
    }

    /**
     * @notice Test that first delegation requires delegator == recipient
     * @dev Verifies the security fix that prevents delegation hijacking
     */
    function test_firstDelegation_requiresDelegatorEqualsRecipient() public {
        // Bob tries to create first delegation with delegator != recipient (should fail)
        bytes memory bobTerms = abi.encodePacked(true, address(token), someUser, uint256(10));
        vm.prank(dm);
        vm.expectRevert("ERC721MultiOperationBalanceEnforcer:invalid-delegator");
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Alice creates first delegation with delegator == recipient (should pass)
        bytes memory aliceTerms = abi.encodePacked(true, address(token), someUser, uint256(10));
        // Ensure initial balance is sufficient to validate decreases later
        _mintTokens(someUser, 10);

        vm.prank(dm);
        enforcer.beforeAllHook(aliceTerms, hex"", singleDefaultMode, hex"", keccak256(""), someUser, address(0));

        // Now Bob can redelegate with more restrictive constraints
        bytes memory bobRedelegationTerms = abi.encodePacked(true, address(token), someUser, uint256(5));
        vm.prank(dm);
        enforcer.beforeAllHook(bobRedelegationTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // // Verify final state
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), someUser);
        (,, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedDecrease, 5, "Expected decrease should be most restrictive amount");

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
        bytes memory aliceTerms = abi.encodePacked(true, address(token), address(delegator), uint256(10));
        vm.prank(dm);
        enforcer.beforeAllHook(aliceTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Alice creates another delegation with delegator == recipient (should aggregate)
        bytes memory aliceTerms2 = abi.encodePacked(false, address(token), address(delegator), uint256(5));
        vm.prank(dm);
        enforcer.beforeAllHook(aliceTerms2, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob tries to redelegate with delegator != recipient (should be more restrictive, not aggregate)
        bytes memory bobTerms = abi.encodePacked(true, address(token), address(delegator), uint256(3));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Verify final state: should have both constraints from Alice + Bob's restrictive constraint
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), address(delegator));
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 5, "Expected increase should be from Alice's delegation");
        assertEq(expectedDecrease, 3, "Expected decrease should be Bob's restrictive constraint");

        // Net expected increase is 2; satisfy and clean up
        _mintTokens(delegator, 2);

        vm.prank(dm);
        enforcer.afterAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));
        vm.prank(dm);
        enforcer.afterAllHook(aliceTerms2, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));
        vm.prank(dm);
        enforcer.afterAllHook(aliceTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
