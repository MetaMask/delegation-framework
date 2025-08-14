// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicERC1155 } from "../utils/BasicERC1155.t.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC1155TotalBalanceChangeEnforcer } from "../../src/enforcers/ERC1155TotalBalanceChangeEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC1155TotalBalanceChangeEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC1155TotalBalanceChangeEnforcer public enforcer;
    BasicERC1155 public token;
    address delegator;
    address delegate;
    address dm;
    address someUser;
    Execution mintExecution;
    bytes mintExecutionCallData;

    uint256 public tokenId = 1;

    ////////////////////// Set up //////////////////////
    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        someUser = address(users.dave.deleGator);
        dm = address(delegationManager);
        enforcer = new ERC1155TotalBalanceChangeEnforcer();
        vm.label(address(enforcer), "ERC1155 Balance Change Enforcer");
        token = new BasicERC1155(delegator, "ERC1155Token", "ERC1155Token", "");
        vm.label(address(token), "ERC1155 Test Token");

        // Prepare the Execution data for minting.
        mintExecution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(token.mint.selector, delegator, tokenId, 100, "")
        });
        mintExecutionCallData = abi.encode(mintExecution);
    }

    ////////////////////// Basic Functionality //////////////////////

    // Validates the terms get decoded correctly.
    // Terms format: [bool shouldBalanceIncrease, address token, address recipient, uint256 tokenId, uint256 amount]
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(100));
        ERC1155TotalBalanceChangeEnforcer.TermsData memory termsData_ = enforcer.getTermsInfo(terms_);
        assertEq(termsData_.enforceDecrease, true);
        assertEq(termsData_.token, address(token));
        assertEq(termsData_.recipient, delegator);
        assertEq(termsData_.tokenId, tokenId);
        assertEq(termsData_.amount, 100);
    }

    // Validates that getHashKey function returns the correct hash
    function test_getHashKey() public {
        address caller_ = address(dm);
        address token_ = address(token);
        address recipient_ = address(delegator);
        uint256 tokenId_ = 1;

        bytes32 expectedHash_ = keccak256(abi.encode(caller_, token_, recipient_, tokenId_));
        bytes32 actualHash_ = enforcer.getHashKey(caller_, token_, recipient_, tokenId_);

        assertEq(actualHash_, expectedHash_, "getHashKey should return correct hash");
    }

    // Validates that a balance has increased at least by the expected amount.
    function test_allow_ifBalanceIncreases() public {
        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        // Increase by 100 - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Increase by 1000 - Subsequent delegation: delegator == recipient (aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 1000, "");
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////// Errors //////////////////////

    // Reverts if a balance hasn't increased by the set amount.
    function test_notAllow_insufficientIncrease() public {
        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        // Increase by 10 only, expect revert.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 10, "");
        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if a balance decreases in between the hooks.
    function test_notAllow_ifBalanceDecreases() public {
        // Starting with 10 tokens.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 10, "");

        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Decrease balance by transferring tokens away.
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(1), tokenId, 10, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Allows checking the balance of different recipients.
    function test_allow_withDifferentRecipients() public {
        address[] memory recipients_ = new address[](2);
        recipients_[0] = delegator;
        recipients_[1] = address(99999);

        for (uint256 i = 0; i < recipients_.length; i++) {
            address currentRecipient_ = recipients_[i];
            bytes memory terms_ = abi.encodePacked(false, address(token), currentRecipient_, uint256(tokenId), uint256(100));

            // Increase by 100 for each recipient.
            vm.prank(dm);
            enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), currentRecipient_, delegate);
            vm.prank(delegator);
            token.mint(currentRecipient_, tokenId, 100, "");
            vm.prank(dm);
            enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), currentRecipient_, delegate);
        }
    }

    // Considers any pre-existing balances in the recipient.
    function test_notAllow_withPreExistingBalance() public {
        // Recipient already has 50 tokens.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 50, "");

        // Expect balance to increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Increase balance by 50 only.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 50, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that balance changes between beforeAllHook calls are allowed and validated in the last afterAllHook call
    function test_allow_balanceChangedBetweenBeforeAllHookCalls() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        // First beforeAllHook call - caches the initial balance - First delegation: delegator == recipient
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Modify the recipient's balance between beforeAllHook calls - this should be allowed
        vm.prank(delegator);
        token.mint(delegator, tokenId, 50, "");

        // Second beforeAllHook call - should now succeed and track the new balance (delegator == recipient for aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Verify that the balance tracker is properly updated
        bytes32 hashKey_ = keccak256(abi.encode(address(dm), address(token), address(delegator), tokenId));
        (uint256 balanceBefore_, uint256 expectedIncrease_, uint256 expectedDecrease_, uint256 validationRemaining_) =
            enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 0, "balanceBefore should be same as initial balance");
        assertEq(expectedIncrease_, 200, "expectedIncrease should be 200 (100 + 100)");
        assertEq(expectedDecrease_, 0, "expectedDecrease should be 0");
        assertEq(validationRemaining_, 2, "validationRemaining should be 2");

        // Mint additional tokens to satisfy the total requirement (already have 50, need 150 more)
        vm.prank(delegator);
        token.mint(delegator, tokenId, 150, "");

        // First afterAllHook call - should not trigger balance check yet
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Second afterAllHook call - should trigger balance check and cleanup
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Differentiates delegation hash with different recipients.
    function test_differentiateDelegationHashWithRecipient() public {
        bytes32 delegationHash_ = bytes32(uint256(99999999));
        address recipient2_ = address(1111111);
        // Terms for two different recipients.
        bytes memory terms1_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));
        bytes memory terms2_ = abi.encodePacked(false, address(token), recipient2_, uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, delegator, delegate);

        vm.prank(dm);
        enforcer.beforeAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, recipient2_, delegate);

        // Increase balance by 100 only for recipient1.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");

        // Recipient1 passes.
        vm.prank(dm);
        enforcer.afterAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, recipient2_, delegate);

        // Recipient2 did not receive tokens, so it should revert.
        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, delegator, delegate);

        // Increase balance for recipient2.
        vm.prank(delegator);
        token.mint(recipient2_, tokenId, 100, "");

        // Recipient2 now passes.
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, delegator, delegate);
    }

    ////////////////////// Decrease Tests //////////////////////

    // Validates that a balance decrease within the allowed range passes.
    // For decrease scenarios (flag = true), the final balance must be at least the cached balance minus the allowed decrease.
    function test_allow_ifBalanceDoesNotDecreaseTooMuch() public {
        // Mint 100 tokens to delegator.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");
        // Confirm initial balance.
        uint256 initialBalance_ = token.balanceOf(delegator, tokenId);
        assertEq(initialBalance_, 100);

        // Set terms with flag = true (decrease expected), allowed decrease is 20.
        bytes memory terms_ = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(20));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Remove 10 tokens: final balance becomes 90, which is >= 100 - 20 = 80.
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(2), tokenId, 10, "");

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the balance decreases too much (i.e. final balance falls below cached balance - allowed amount).
    function test_notAllow_excessiveDecrease() public {
        // Mint 100 tokens to delegator.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");
        uint256 initialBalance_ = token.balanceOf(delegator, tokenId);
        assertEq(initialBalance_, 100);

        // Set terms with flag = true (decrease expected), allowed decrease is 20.
        bytes memory terms_ = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(20));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Remove 30 tokens: final balance becomes 70, which is below 100 - 20 = 80.
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(3), tokenId, 30, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////// Invalid Terms Tests //////////////////////

    // Validates that the terms are well-formed (exactly 105 bytes).
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small: missing required bytes (no boolean flag, etc.).
        terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large: extra bytes appended.
        terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100), uint256(1));
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address causes a revert.
    function test_invalid_tokenAddress() public {
        bytes memory terms_ = abi.encodePacked(false, address(0), address(delegator), uint256(tokenId), uint256(100));
        vm.expectRevert();
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if an unrealistic amount triggers overflow.
    function test_notAllow_expectingOverflow() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        vm.expectRevert();
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if amount is 0
    function test_revertWithZeroAmount() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(0));
        vm.prank(address(dm));
        vm.expectRevert("ERC1155TotalBalanceChangeEnforcer:zero-expected-change-amount");
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////// Multiple enforcer in delegation chain Functionality //////////////////////////////

    // Reverts if the total balance increase is insufficient with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: both increasing by 100. Total expected balance change is an
    // increase of at least 200.
    function test_multiple_enforcers_insufficient_increase() public {
        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        vm.prank(delegator);
        token.mint(delegator, tokenId, 199, "");

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the total balance decrease is excessive with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: both decreasing by 100. Total expected balance change is a
    // decrease of at most 200.
    function test_multiple_enforcers_excessive_decrease() public {
        vm.prank(delegator);
        token.mint(delegator, tokenId, 300, "");

        // Expect decrease of max 100.
        bytes memory terms_ = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Decrease by more than allowed (201 instead of 200)
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(2), tokenId, 201, "");

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the total balance increase is insufficient with multiple enforcers.
    // We are running 3 enforcers in the delegation chain: 2 increasing and 1 decreasing. Total expected balance change is an
    // increase of at least 100.
    function test_mixed_enforcers_insufficient_increase() public {
        // Decrease by 100
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(100));
        // Increase by 100
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Net expected increase is 100; don't mint any tokens
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        vm.expectRevert("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase");
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the total balance decrease is excessive with multiple enforcers.
    // We are running 3 enforcers in the delegation chain: 1 increasing and 2 decreasing. Total expected balance change is an
    // decrease of at most 100.
    function test_mixed_enforcers_excessive_decrease() public {
        vm.prank(delegator);
        token.mint(delegator, tokenId, 300, "");

        // Decrease by 100
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(100));
        // Increase by 100
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Transfer out more than allowed (101 tokens)
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(2), tokenId, 101, "");

        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        vm.expectRevert("ERC1155TotalBalanceChangeEnforcer:exceeded-balance-decrease");
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////////////// Check events //////////////////////////////

    // Validates that the events are emitted correctly for an increase scenario.
    function test_events_emitted_correctly() public {
        // Increase by 100
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        // First beforeAllHook - should emit TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC1155TotalBalanceChangeEnforcer.TrackedBalance(dm, delegator, address(token), tokenId, 0);
        vm.expectEmit(true, true, true, true);
        emit ERC1155TotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, delegator, address(token), tokenId, false, 100);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Second beforeAllHook should ONLY emit UpdatedExpectedBalance
        vm.recordLogs();
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "Should only emit one event");

        // Verify it's the UpdatedExpectedBalance event
        assertEq(logs[0].topics[0], keccak256("UpdatedExpectedBalance(address,address,address,uint256,bool,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(dm)))); // delegationManager
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(delegator))))); // recipient
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(address(token))))); // token

        vm.prank(delegator);
        token.mint(delegator, tokenId, 200, "");

        // First afterAllHook should not emit anything
        vm.recordLogs();
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "Should not emit any events");

        // Second afterAllHook - should emit ValidatedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC1155TotalBalanceChangeEnforcer.ValidatedBalance(dm, delegator, address(token), tokenId, 200);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that the events are emitted correctly for a decrease scenario.
    function test_events_emitted_correctly_with_decrease() public {
        // Mint 100 tokens to delegator.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");

        // Decrease by 100
        bytes memory terms_ = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(100));

        // beforeAllHook - should emit TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC1155TotalBalanceChangeEnforcer.TrackedBalance(dm, delegator, address(token), tokenId, 100);
        vm.expectEmit(true, true, true, true);
        emit ERC1155TotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, delegator, address(token), tokenId, true, 100);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(2), tokenId, 50, "");

        // afterAllHook - should emit ValidatedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC1155TotalBalanceChangeEnforcer.ValidatedBalance(dm, delegator, address(token), tokenId, 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Fails with an invalid execution mode (non-default).
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeAllHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////////////// Redelegation Tests //////////////////////////////

    /**
     * @notice Test that redelegations with same type (decrease) are always more restrictive
     * @dev Verifies that each redelegation must have amount <= previous amount
     */
    function test_redelegation_decreaseType_alwaysMoreRestrictive() public {
        // Alice creates initial delegation allowing decrease by 1000
        bytes memory initialTerms = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(1000));

        // Ensure initial balance is sufficient to avoid underflow when validating decrease
        vm.prank(delegator);
        token.mint(delegator, tokenId, 1000, "");

        // Simulate Alice's initial delegation (delegator must equal recipient for first delegation)
        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob tries to redelegate with same type but larger amount (should fail)
        bytes memory bobTerms = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(1200));
        vm.prank(dm);
        vm.expectRevert("ERC1155TotalBalanceChangeEnforcer:redelegation-must-be-more-restrictive");
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Bob tries to redelegate with same type and smaller amount (should pass)
        bytes memory bobTermsRestrictive = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(800));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTermsRestrictive, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Charlie tries to redelegate with even smaller amount (should pass)
        bytes memory charlieTerms = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(500));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Verify final state: expectedDecrease should be 500 (most restrictive)
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), address(delegator), tokenId);
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
        // Alice creates initial delegation requiring increase by 5
        bytes memory initialTerms = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(500));

        // Simulate Alice's initial delegation
        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob tries to redelegate with same type but smaller amount (should fail)
        bytes memory bobTerms = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(300));
        vm.prank(dm);
        vm.expectRevert("ERC1155TotalBalanceChangeEnforcer:redelegation-must-be-more-restrictive");
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Bob tries to redelegate with same type and larger amount (should pass)
        bytes memory bobTermsRestrictive = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(800));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTermsRestrictive, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Charlie tries to redelegate with even larger amount (should pass)
        bytes memory charlieTerms = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(1200));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Verify final state: expectedIncrease should be 1200 (most restrictive)
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), address(delegator), tokenId);
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 1200, "Expected increase should be most restrictive amount");
        assertEq(expectedDecrease, 0, "Expected decrease should remain 0");

        // Satisfy net expected increase and clean up
        vm.prank(delegator);
        token.mint(delegator, tokenId, 1200, "");

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
        bytes memory initialTerms = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(1000));

        // Simulate Alice's initial delegation
        // Ensure initial balance is sufficient for decrease validation
        vm.prank(delegator);
        token.mint(delegator, tokenId, 1000, "");

        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob redelegates with type switch to increase (should pass - more restrictive)
        bytes memory bobTerms = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(800));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Charlie tries to redelegate back to decrease with amount > original (should fail)
        bytes memory charlieTermsInvalid = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(1200));
        vm.prank(dm);
        vm.expectRevert("ERC1155TotalBalanceChangeEnforcer:redelegation-must-be-more-restrictive");
        enforcer.beforeAllHook(charlieTermsInvalid, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Charlie redelegates back to decrease with amount <= original (should pass)
        bytes memory charlieTermsValid = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(600));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTermsValid, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // Verify final state: should have both constraints
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), address(delegator), tokenId);
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 800, "Expected increase should be preserved");
        assertEq(expectedDecrease, 600, "Expected decrease should be most restrictive");

        // Net expected increase is 2; satisfy and clean up
        vm.prank(delegator);
        token.mint(delegator, tokenId, 200, "");

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
        bytes memory initialTerms = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(1000));

        // Simulate Alice's initial delegation
        vm.prank(delegator);
        token.mint(delegator, tokenId, 1000, "");

        vm.prank(dm);
        enforcer.beforeAllHook(initialTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Chain of redelegations: decrease -> increase -> decrease -> increase
        // Each should make constraints more restrictive

        // 1. Bob: decrease to 800 (more restrictive)
        bytes memory bobTerms = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(800));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // 2. Charlie: switch to increase of 600 (more restrictive)
        bytes memory charlieTerms = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(600));
        vm.prank(dm);
        enforcer.beforeAllHook(charlieTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x123), address(0));

        // 3. David: switch back to decrease of 400 (more restrictive)
        bytes memory davidTerms = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(400));
        vm.prank(dm);
        enforcer.beforeAllHook(davidTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x456), address(0));

        // 4. Eve: switch to increase of 1000 (more restrictive)
        bytes memory eveTerms = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(1000));
        vm.prank(dm);
        enforcer.beforeAllHook(eveTerms, hex"", singleDefaultMode, hex"", keccak256(""), address(0x789), address(0));

        // Verify final state: should have most restrictive constraints
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), address(delegator), tokenId);
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 1000, "Expected increase should be most restrictive");
        assertEq(expectedDecrease, 400, "Expected decrease should be most restrictive");

        // Net expected increase is 600; satisfy before running afterAlls
        vm.prank(delegator);
        token.mint(delegator, tokenId, 600, "");

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
        bytes memory bobTerms = abi.encodePacked(true, address(token), address(someUser), uint256(tokenId), uint256(1000));
        vm.prank(dm);
        vm.expectRevert("ERC1155TotalBalanceChangeEnforcer:invalid-delegator");
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Alice creates first delegation with delegator == recipient (should pass)
        bytes memory aliceTerms = abi.encodePacked(true, address(token), address(someUser), uint256(tokenId), uint256(1000));
        // Ensure initial balance is sufficient to validate decreases later
        vm.prank(delegator);
        token.mint(someUser, tokenId, 1000, "");

        vm.prank(dm);
        enforcer.beforeAllHook(aliceTerms, hex"", singleDefaultMode, hex"", keccak256(""), someUser, address(0));

        // Now Bob can redelegate with more restrictive constraints
        bytes memory bobRedelegationTerms = abi.encodePacked(true, address(token), address(someUser), uint256(tokenId), uint256(500));
        vm.prank(dm);
        enforcer.beforeAllHook(bobRedelegationTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Verify final state
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), someUser, tokenId);
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
        bytes memory aliceTerms = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(1000));
        vm.prank(dm);
        enforcer.beforeAllHook(aliceTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Alice creates another delegation with delegator == recipient (should aggregate)
        bytes memory aliceTerms2 = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(500));
        vm.prank(dm);
        enforcer.beforeAllHook(aliceTerms2, hex"", singleDefaultMode, hex"", keccak256(""), delegator, address(0));

        // Bob tries to redelegate with delegator != recipient (should be more restrictive, not aggregate)
        bytes memory bobTerms = abi.encodePacked(true, address(token), address(delegator), uint256(tokenId), uint256(300));
        vm.prank(dm);
        enforcer.beforeAllHook(bobTerms, hex"", singleDefaultMode, hex"", keccak256(""), delegate, address(0));

        // Verify final state: should have both constraints from Alice + Bob's restrictive constraint
        bytes32 hashKey = enforcer.getHashKey(dm, address(token), address(delegator), tokenId);
        (, uint256 expectedIncrease, uint256 expectedDecrease,) = enforcer.balanceTracker(hashKey);

        assertEq(expectedIncrease, 500, "Expected increase should be from Alice's delegation");
        assertEq(expectedDecrease, 300, "Expected decrease should be Bob's restrictive constraint");

        // Net expected increase is 2; satisfy and clean up
        vm.prank(delegator);
        token.mint(delegator, tokenId, 200, "");

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
