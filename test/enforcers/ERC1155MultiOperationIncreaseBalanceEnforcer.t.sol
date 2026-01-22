// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicERC1155 } from "../utils/BasicERC1155.t.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC1155MultiOperationIncreaseBalanceEnforcer } from "../../src/enforcers/ERC1155MultiOperationIncreaseBalanceEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC1155MultiOperationIncreaseBalanceEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC1155MultiOperationIncreaseBalanceEnforcer public enforcer;
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
        enforcer = new ERC1155MultiOperationIncreaseBalanceEnforcer();
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
    // Terms format: [address token, address recipient, uint256 tokenId, uint256 amount]
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));
        ERC1155MultiOperationIncreaseBalanceEnforcer.TermsData memory termsData_ = enforcer.getTermsInfo(terms_);
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
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));

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

    // Allows checking the balance of different recipients.
    function test_allow_withDifferentRecipients() public {
        address[] memory recipients_ = new address[](2);
        recipients_[0] = delegator;
        recipients_[1] = address(99999);

        for (uint256 i = 0; i < recipients_.length; i++) {
            address currentRecipient_ = recipients_[i];
            bytes memory terms_ = abi.encodePacked(address(token), address(currentRecipient_), uint256(tokenId), uint256(100));

            // Increase by 100 for each recipient.
            vm.prank(dm);
            enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
            vm.prank(delegator);
            token.mint(currentRecipient_, tokenId, 100, "");
            vm.prank(dm);
            enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
        }
    }

    // Reverts if a balance hasn't increased by the set amount.
    function test_notAllow_insufficientIncrease() public {
        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));

        // Increase by 10 only, expect revert.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 10, "");
        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Considers any pre-existing balances in the recipient.
    function test_notAllow_withPreExistingBalance() public {
        // Recipient already has 50 tokens.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 50, "");

        // Expect balance to increase by at least 100.
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Increase balance by 50 only.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 50, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Validates that balance changes between beforeAllHook calls are allowed and validated in the last afterAllHook call
    function test_allow_balanceChangedBetweenBeforeAllHookCalls() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));

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
        (uint256 balanceBefore_, uint256 expectedIncrease_, uint256 validationRemaining_) = enforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore_, 0, "balanceBefore should be same as initial balance");
        assertEq(expectedIncrease_, 200, "expectedIncrease should be 200 (100 + 100)");
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
        bytes memory terms1_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));
        bytes memory terms2_ = abi.encodePacked(address(token), recipient2_, uint256(tokenId), uint256(100));

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
        vm.expectRevert(bytes("ERC1155MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance for recipient2.
        vm.prank(delegator);
        token.mint(recipient2_, tokenId, 100, "");

        // Recipient2 now passes.
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
    }

    ////////////////////// Invalid Terms Tests //////////////////////

    // Validates that the terms are well-formed (exactly 104 bytes).
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small: missing required bytes (should be 104 bytes)
        terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId));
        vm.expectRevert(bytes("ERC1155MultiOperationIncreaseBalanceEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large: extra bytes beyond 104
        terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100), uint256(1));
        vm.expectRevert(bytes("ERC1155MultiOperationIncreaseBalanceEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address causes a revert.
    function test_invalid_tokenAddress() public {
        bytes memory terms_ = abi.encodePacked(address(0), address(delegator), uint256(tokenId), uint256(100));
        vm.expectRevert();
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if an unrealistic amount triggers overflow.
    function test_notAllow_expectingOverflow() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        vm.prank(dm);
        vm.expectRevert();
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if amount is 0
    function test_revertWithZeroAmount() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(0));
        vm.prank(address(dm));
        vm.expectRevert("ERC1155MultiOperationIncreaseBalanceEnforcer:zero-expected-change-amount");
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    ////////////////////// Multiple enforcer in delegation chain Functionality //////////////////////////////

    // Reverts if the total balance increase is insufficient with multiple enforcers.
    // We are running 2 enforcers in the delegation chain: both increasing by 100. Total expected balance change is an
    // increase of at least 200.
    function test_multiple_enforcers_insufficient_increase() public {
        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        vm.prank(delegator);
        token.mint(delegator, tokenId, 199, "");

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Validates that delegation can be reused with different recipients without interference
    function test_allow_reuseDelegationWithDifferentRecipients() public {
        address recipient1_ = delegator;
        address recipient2_ = address(users.carol.deleGator);

        // Terms for two different recipients
        bytes memory terms1_ = abi.encodePacked(address(token), address(recipient1_), uint256(tokenId), uint256(100));
        bytes memory terms2_ = abi.encodePacked(address(token), address(recipient2_), uint256(tokenId), uint256(100));

        // Increase by 100 for recipient1 - First delegation
        vm.prank(dm);
        enforcer.beforeAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient1_, delegate);
        vm.prank(delegator);
        token.mint(recipient1_, tokenId, 100, "");
        vm.prank(dm);
        enforcer.afterAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient1_, delegate);

        // Increase by 100 for recipient2 - First delegation (aggregation)
        vm.prank(dm);
        enforcer.beforeAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient2_, delegate);
        vm.prank(delegator);
        token.mint(recipient2_, tokenId, 100, "");
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), recipient2_, delegate);
    }

    // Validates that balance tracker is properly cleaned up after validation
    function test_balanceTracker_clean() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));
        bytes32 hash_ = keccak256(abi.encode(address(dm), address(token), address(delegator), tokenId));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        (, uint256 expectedIncrease_,) = enforcer.balanceTracker(hash_);
        assertEq(expectedIncrease_, 100);

        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        (, expectedIncrease_,) = enforcer.balanceTracker(hash_);
        assertEq(expectedIncrease_, 0);
    }

    ////////////////////////////// Check events //////////////////////////////

    // Validates that the events are emitted correctly for an increase scenario.
    function test_events_emitted_correctly() public {
        // Increase by 100
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));

        // First beforeAllHook - should emit TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC1155MultiOperationIncreaseBalanceEnforcer.TrackedBalance(dm, delegator, address(token), tokenId, 0);
        vm.expectEmit(true, true, true, true);
        emit ERC1155MultiOperationIncreaseBalanceEnforcer.UpdatedExpectedBalance(dm, delegator, address(token), tokenId, 100);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Second beforeAllHook should ONLY emit UpdatedExpectedBalance
        vm.recordLogs();
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "Should only emit one event");

        // Verify it's the UpdatedExpectedBalance event
        assertEq(logs[0].topics[0], keccak256("UpdatedExpectedBalance(address,address,address,uint256,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(dm)))); // delegationManager
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(delegator))))); // recipient
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(address(token))))); // token

        vm.prank(delegator);
        token.mint(delegator, tokenId, 200, "");

        // First afterAllHook - should not emit anything
        vm.recordLogs();
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "Should not emit any events");

        // Second afterAllHook - should emit ValidatedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC1155MultiOperationIncreaseBalanceEnforcer.ValidatedBalance(dm, delegator, address(token), tokenId, 200);
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
