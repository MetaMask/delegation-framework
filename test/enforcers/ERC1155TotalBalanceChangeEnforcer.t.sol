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
    Execution mintExecution;
    bytes mintExecutionCallData;

    uint256 public tokenId = 1;

    ////////////////////// Set up //////////////////////
    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
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

        // Increase by 100.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Increase by 1000.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 1000, "");
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    ////////////////////// Errors //////////////////////

    // Reverts if a balance hasn't increased by the set amount.
    function test_notAllow_insufficientIncrease() public {
        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        // Increase by 10 only, expect revert.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 10, "");
        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if a balance decreases in between the hooks.
    function test_notAllow_ifBalanceDecreases() public {
        // Starting with 10 tokens.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 10, "");

        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Decrease balance by transferring tokens away.
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(1), tokenId, 10, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
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
            enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
            vm.prank(delegator);
            token.mint(currentRecipient_, tokenId, 100, "");
            vm.prank(dm);
            enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
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
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Increase balance by 50 only.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 50, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if balance changes between beforeAllHook calls for the same recipient/token pair
    function test_notAllow_balanceChangedBetweenBeforeAllHookCalls() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        // First beforeAllHook call - caches the initial balance
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Modify the recipient's balance between beforeAllHook calls
        vm.prank(delegator);
        token.mint(delegator, tokenId, 50, "");

        // Second beforeAllHook call - should revert because balance changed
        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:balance-changed"));
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Differentiates delegation hash with different recipients.
    function test_differentiateDelegationHashWithRecipient() public {
        bytes32 delegationHash_ = bytes32(uint256(99999999));
        address recipient2_ = address(1111111);
        // Terms for two different recipients.
        bytes memory terms1_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));
        bytes memory terms2_ = abi.encodePacked(false, address(token), recipient2_, uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        vm.prank(dm);
        enforcer.beforeAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance by 100 only for recipient1.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");

        // Recipient1 passes.
        vm.prank(dm);
        enforcer.afterAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Recipient2 did not receive tokens, so it should revert.
        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance for recipient2.
        vm.prank(delegator);
        token.mint(recipient2_, tokenId, 100, "");

        // Recipient2 now passes.
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
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
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Remove 10 tokens: final balance becomes 90, which is >= 100 - 20 = 80.
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(2), tokenId, 10, "");

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
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
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Remove 30 tokens: final balance becomes 70, which is below 100 - 20 = 80.
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(3), tokenId, 30, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
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
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        vm.prank(dm);
        vm.expectRevert();
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    ////////////////////// Multiple enforcer in delegation chain Functionality //////////////////////////////

    // Reverts if the total balance increase is insufficient with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: both increasing by 100. Total expected balance change is an
    // increase of at least 200.
    function test_multiple_enforcers_insufficient_increase() public {
        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        vm.prank(delegator);
        token.mint(delegator, tokenId, 199, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
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
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // decrease by more then 200
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(2), tokenId, 201, "");

        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
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
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        vm.prank(delegator);
        token.mint(delegator, tokenId, 99, "");

        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
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
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(2), tokenId, 101, "");

        vm.expectRevert(bytes("ERC1155TotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    ////////////////////////////// Check events //////////////////////////////

    // Validates that the events are emitted correctly for an increase scenario.
    function test_events_emitted_correctly() public {
        // Increase by 100
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        // First beforeAllHook - should emit TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC1155TotalBalanceChangeEnforcer.TrackedBalance(dm, delegator, address(token), 0);
        vm.expectEmit(true, true, true, true);
        emit ERC1155TotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, address(token), delegator, false, 100);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Second beforeAllHook should ONLY emit UpdatedExpectedBalance
        vm.recordLogs();
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "Should only emit one event");

        // Verify it's the UpdatedExpectedBalance event
        assertEq(logs[0].topics[0], keccak256("UpdatedExpectedBalance(address,address,address,bool,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(dm)))); // delegationManager
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(token))))); // token
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(address(delegator))))); // recipient

        // mint 2 tokens
        vm.prank(delegator);
        token.mint(delegator, tokenId, 200, "");

        // First afterAllHook - should emit ValidatedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC1155TotalBalanceChangeEnforcer.ValidatedBalance(dm, delegator, address(token), 200);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Second afterAllHook should not emit anything
        vm.recordLogs();
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "Should not emit any events");
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
        emit ERC1155TotalBalanceChangeEnforcer.TrackedBalance(dm, delegator, address(token), 100);
        vm.expectEmit(true, true, true, true);
        emit ERC1155TotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, address(token), delegator, true, 100);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(2), tokenId, 50, "");

        // afterAllHook - should emit ValidatedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC1155TotalBalanceChangeEnforcer.ValidatedBalance(dm, delegator, address(token), 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Fails with an invalid execution mode (non-default).
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeAllHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
