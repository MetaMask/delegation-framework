// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicCF721 } from "../utils/BasicCF721.t.sol";

import "../../src/utils/Types.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC721TotalBalanceChangeEnforcer } from "../../src/enforcers/ERC721TotalBalanceChangeEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC721TotalBalanceChangeEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC721TotalBalanceChangeEnforcer public enforcer;
    BasicCF721 public token;
    address delegator;
    address delegate;
    address dm;
    Execution mintExecution;
    bytes mintExecutionCallData;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        dm = address(delegationManager);
        enforcer = new ERC721TotalBalanceChangeEnforcer();
        vm.label(address(enforcer), "ERC721 Balance Change Enforcer");
        token = new BasicCF721(delegator, "ERC721Token", "ERC721Token", "");
        vm.label(address(token), "ERC721 Test Token");

        // Prepare the Execution data for minting.
        mintExecution =
            Execution({ target: address(token), value: 0, callData: abi.encodeWithSelector(token.mint.selector, delegator) });
        mintExecutionCallData = abi.encode(mintExecution);
    }

    ////////////////////// Basic Functionality - same as ERC721BalanceChangeEnforcer //////////////////////

    // Validates the terms get decoded correctly (increase scenario)
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(true, address(token), address(delegator), uint256(1));
        (bool enforceDecrease_, address token_, address recipient_, uint256 amount_) = enforcer.getTermsInfo(terms_);
        assertTrue(enforceDecrease_);
        assertEq(token_, address(token));
        assertEq(recipient_, delegator);
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

    // Validates that a balance has increased by at least the expected amount
    function test_allow_ifBalanceIncreases() public {
        // Expect increase by at least 1
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        // Increase by 1
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Increase by 1 again (a second mint)
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if a balance hasn't increased by the set amount
    function test_notAllow_insufficientIncrease() public {
        // Expect increase by at least 1
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        // No minting occurs here, so balance remains unchanged.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if the balance decreases when an increase is expected
    function test_notAllow_ifBalanceDecreases() public {
        // Starting with 1 token for delegator.
        vm.prank(delegator);
        token.mint(delegator);

        // Expect an increase by at least 1.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Transfer the token away, decreasing the balance.
        uint256 tokenIdToTransfer_ = token.tokenId() - 1;
        vm.prank(delegator);
        token.transferFrom(delegator, address(1), tokenIdToTransfer_);

        vm.prank(dm);
        vm.expectRevert(bytes("ERC721TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Allows checking the balance of different recipients
    function test_allow_withDifferentRecipients() public {
        address[] memory recipients_ = new address[](2);
        recipients_[0] = delegator;
        recipients_[1] = address(99999);

        for (uint256 i = 0; i < recipients_.length; i++) {
            address currentRecipient_ = recipients_[i];
            bytes memory terms_ = abi.encodePacked(false, address(token), currentRecipient_, uint256(1));

            // Increase by 1 for each recipient.
            vm.prank(dm);
            enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
            vm.prank(delegator);
            token.mint(currentRecipient_);
            vm.prank(dm);
            enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
        }
    }

    // Considers any pre-existing balances in the recipient
    function test_notAllow_withPreExistingBalance() public {
        // Delegator already has 1 token.
        vm.prank(delegator);
        token.mint(delegator);

        // Expect balance to increase by at least 1.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // No new minting – the balance doesn't increase.
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Differentiates delegation hash with different recipients
    function test_differentiateDelegationHashWithRecipient() public {
        bytes32 delegationHash_ = bytes32(uint256(99999999));
        address recipient2_ = address(1111111);
        // Terms for two different recipients.
        bytes memory terms1_ = abi.encodePacked(false, address(token), delegator, uint256(1));
        bytes memory terms2_ = abi.encodePacked(false, address(token), recipient2_, uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        vm.prank(dm);
        enforcer.beforeAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance by 1 only for recipient1.
        vm.prank(delegator);
        token.mint(delegator);

        // Recipient1 should pass as its balance increased.
        vm.prank(dm);
        enforcer.afterAllHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Recipient2 did not receive a token, so it should revert.
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance for recipient2.
        vm.prank(delegator);
        token.mint(recipient2_);

        // Recipient2 now passes.
        vm.prank(dm);
        enforcer.afterAllHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
    }

    // Validates that a balance decrease within the allowed range passes.
    // For decrease scenarios (flag = false), the final balance must be at least the cached balance minus the allowed decrease.
    // Example: if the cached balance is 2 and the allowed decrease is 1, then final balance must be >= 1.
    function test_allow_ifBalanceDoesNotDecreaseTooMuch() public {
        // Mint 2 tokens to delegator.
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(delegator);
        token.mint(delegator);
        // Ensure initial balance is 2.
        uint256 initialBalance_ = token.balanceOf(delegator);
        assertEq(initialBalance_, 2);

        // Set terms with flag = true for decrease, allowed decrease is 1.
        bytes memory terms_ = abi.encodePacked(true, address(token), address(delegator), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Remove one token: final balance becomes 1 (which is 2 - 1, and thus acceptable).
        uint256 tokenIdToTransfer_ = token.tokenId() - 1;
        vm.prank(delegator);
        token.transferFrom(delegator, address(2), tokenIdToTransfer_);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if the balance decreases too much (i.e. final balance falls below cached balance - allowed amount)
    function test_notAllow_excessiveDecrease() public {
        // Mint 2 tokens to delegator.
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(delegator);
        token.mint(delegator);
        // Confirm initial balance is 2.
        uint256 initialBalance = token.balanceOf(delegator);
        assertEq(initialBalance, 2);

        // Terms: flag = true (decrease expected), allowed decrease is 1.
        bytes memory terms_ = abi.encodePacked(true, address(token), address(delegator), uint256(1));

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Remove both tokens: final balance becomes 0, which is below (2 - 1) = 1.
        uint256 tokenId1 = token.tokenId() - 2;
        uint256 tokenId2 = token.tokenId() - 1;
        vm.prank(delegator);
        token.transferFrom(delegator, address(3), tokenId1);
        vm.prank(delegator);
        token.transferFrom(delegator, address(4), tokenId2);

        vm.prank(dm);
        vm.expectRevert(bytes("ERC721TotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Validates that the terms are well-formed (exactly 73 bytes)
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small: missing required bytes.
        terms_ = abi.encodePacked(false, address(token), address(delegator), uint8(1));
        vm.expectRevert(bytes("ERC721TotalBalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large: extra bytes.
        terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1), uint256(1));
        vm.expectRevert(bytes("ERC721TotalBalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address causes a revert when calling beforeAllHook.
    function test_invalid_tokenAddress() public {
        bytes memory terms_ = abi.encodePacked(false, address(0), address(delegator), uint256(1));
        vm.expectRevert();
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if an unrealistic amount triggers overflow.
    function test_notAllow_expectingOverflow() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        vm.prank(dm);
        vm.expectRevert();
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    ////////////////////// Multiple enforcer in delegation chain Functionality //////////////////////////////

    function test_multiple_enforcers_insufficient_increase() public {
        // Increase by 1
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        vm.prank(dm);
        // we are running 2 enforcers in the delegation chain both increaseing
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    function test_multiple_enforcers_excessive_decrease() public {
        // Mint 3 tokens to delegator.
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(delegator);
        token.mint(delegator);
        uint256 tokenCount = token.tokenId();

        // Decrease by 1
        bytes memory terms_ = abi.encodePacked(true, address(token), address(delegator), uint256(1));

        vm.prank(dm);
        // we are running 2 enforcers in the delegation chain both decreasing
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.transferFrom(delegator, dm, tokenCount - 1);
        vm.prank(delegator);
        token.transferFrom(delegator, dm, tokenCount - 2);
        vm.prank(delegator);
        token.transferFrom(delegator, dm, tokenCount - 3);
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721TotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        token.transferFrom(dm, delegator, tokenCount - 3);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    function test_mixed_enforcers_insufficient_increase() public {
        // Decrease by 1
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(delegator), uint256(1));
        // Increase by 1
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        // we are running 3 enforcers in the delegation chain: 2 increasing and 1 decreasing
        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        vm.prank(dm);
        // should fail with no change to the balance
        vm.expectRevert(bytes("ERC721TotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(dm);
        // should pass with 1 increase
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    function test_mixed_enforcers_excessive_decrease() public {
        // Mint 2 tokens to delegator.
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(delegator);
        token.mint(delegator);
        uint256 tokenCount = token.tokenId();

        // Decrease by 1
        bytes memory termsDecrease_ = abi.encodePacked(true, address(token), address(delegator), uint256(1));
        // Increase by 1
        bytes memory termsIncrease_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        // we are running 3 enforcers in the delegation chain: 1 increasing and 2 decreasing
        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        vm.prank(delegator);
        token.transferFrom(delegator, dm, tokenCount - 1);
        vm.prank(delegator);
        token.transferFrom(delegator, dm, tokenCount - 2);

        vm.prank(dm);
        // should fail with balance decrease of more then 1
        vm.expectRevert(bytes("ERC721TotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(dm);
        // should pass with overall balance decrease of 1
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    ////////////////////////////// Check events //////////////////////////////

    function test_events_emitted_correctly() public {
        // Increase by 1
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        // First beforeAllHook - should emit TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC721TotalBalanceChangeEnforcer.TrackedBalance(dm, delegator, address(token), 0);
        vm.expectEmit(true, true, true, true);
        emit ERC721TotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, address(token), delegator, false, 1);
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
        token.mint(delegator);
        vm.prank(delegator);
        token.mint(delegator);

        // First afterAllHook - should emit ValidatedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC721TotalBalanceChangeEnforcer.ValidatedBalance(dm, delegator, address(token), 2);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Second afterAllHook - should not emit any events
        vm.recordLogs();
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        assertEq(logs2.length, 0, "Should not emit any events");
    }

    function test_events_emitted_correctly_decrease() public {
        // Mint 2 tokens to delegator.
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(delegator);
        token.mint(delegator);

        // Decrease by 1
        bytes memory terms_ = abi.encodePacked(true, address(token), address(delegator), uint256(1));

        // beforeAllHook - should emit TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit ERC721TotalBalanceChangeEnforcer.TrackedBalance(dm, delegator, address(token), 2);
        vm.expectEmit(true, true, true, true);
        emit ERC721TotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, address(token), delegator, true, 1);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        uint256 tokenToTransfer_ = token.tokenId() - 1;
        vm.prank(delegator);
        token.transferFrom(delegator, dm, tokenToTransfer_);

        // afterAllHook - should emit ValidatedBalance
        vm.prank(dm);
        vm.expectEmit(true, true, true, true);
        emit ERC721TotalBalanceChangeEnforcer.ValidatedBalance(dm, delegator, address(token), 1);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Fails with an invalid execution mode (non-default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeAllHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
