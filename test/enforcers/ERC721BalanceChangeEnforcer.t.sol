// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicCF721 } from "../utils/BasicCF721.t.sol";

import "../../src/utils/Types.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC721BalanceChangeEnforcer } from "../../src/enforcers/ERC721BalanceChangeEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC721BalanceChangeEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC721BalanceChangeEnforcer public enforcer;
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
        enforcer = new ERC721BalanceChangeEnforcer();
        vm.label(address(enforcer), "ERC721 Balance Change Enforcer");
        token = new BasicCF721(delegator, "ERC721Token", "ERC721Token", "");
        vm.label(address(token), "ERC721 Test Token");

        // Prepare the Execution data for minting.
        mintExecution =
            Execution({ target: address(token), value: 0, callData: abi.encodeWithSelector(token.mint.selector, delegator) });
        mintExecutionCallData = abi.encode(mintExecution);
    }

    ////////////////////// Basic Functionality //////////////////////

    // Validates the terms get decoded correctly (increase scenario)
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(true, address(token), address(delegator), uint256(1));
        (bool enforceDecrease_, address token_, address recipient_, uint256 amount_) = enforcer.getTermsInfo(terms_);
        assertTrue(enforceDecrease_);
        assertEq(token_, address(token));
        assertEq(recipient_, delegator);
        assertEq(amount_, 1);
    }

    // Validates that a balance has increased by at least the expected amount
    function test_allow_ifBalanceIncreases() public {
        // Expect increase by at least 1
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        // Increase by 1
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Increase by 1 again (a second mint)
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if a balance hasn't increased by the set amount
    function test_notAllow_insufficientIncrease() public {
        // Expect increase by at least 1
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        // No minting occurs here, so balance remains unchanged.
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721BalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if the balance decreases when an increase is expected
    function test_notAllow_ifBalanceDecreases() public {
        // Starting with 1 token for delegator.
        vm.prank(delegator);
        token.mint(delegator);

        // Expect an increase by at least 1.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Transfer the token away, decreasing the balance.
        uint256 tokenIdToTransfer_ = token.tokenId() - 1;
        vm.prank(delegator);
        token.transferFrom(delegator, address(1), tokenIdToTransfer_);

        vm.prank(dm);
        vm.expectRevert(bytes("ERC721BalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
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
            enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
            vm.prank(delegator);
            token.mint(currentRecipient_);
            vm.prank(dm);
            enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
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
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // No new minting – the balance doesn't increase.
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721BalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Differentiates delegation hash with different recipients
    function test_differentiateDelegationHashWithRecipient() public {
        bytes32 delegationHash_ = bytes32(uint256(99999999));
        address recipient2_ = address(1111111);
        // Terms for two different recipients.
        bytes memory terms1_ = abi.encodePacked(false, address(token), delegator, uint256(1));
        bytes memory terms2_ = abi.encodePacked(false, address(token), recipient2_, uint256(1));

        vm.prank(dm);
        enforcer.beforeHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        vm.prank(dm);
        enforcer.beforeHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance by 1 only for recipient1.
        vm.prank(delegator);
        token.mint(delegator);

        // Recipient1 should pass as its balance increased.
        vm.prank(dm);
        enforcer.afterHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Recipient2 did not receive a token, so it should revert.
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721BalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance for recipient2.
        vm.prank(delegator);
        token.mint(recipient2_);

        // Recipient2 now passes.
        vm.prank(dm);
        enforcer.afterHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
    }

    // Reverts if the enforcer is locked (i.e. if beforeHook is reentered)
    function test_notAllow_reenterALockedEnforcer() public {
        // Expect increase by at least 1.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1));
        bytes32 delegationHash_ = bytes32(uint256(99999999));

        vm.startPrank(dm);
        // Lock the enforcer.
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        bytes32 hashKey_ = enforcer.getHashKey(address(delegationManager), address(token), address(delegator), delegationHash_);
        assertTrue(enforcer.isLocked(hashKey_));
        vm.expectRevert(bytes("ERC721BalanceChangeEnforcer:enforcer-is-locked"));
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        vm.stopPrank();

        vm.prank(delegator);
        token.mint(delegator);

        vm.startPrank(dm);
        // Unlock the enforcer.
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        assertFalse(enforcer.isLocked(hashKey_));
        // Reuse the enforcer, which locks it again.
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        assertTrue(enforcer.isLocked(hashKey_));
        vm.stopPrank();
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
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Remove one token: final balance becomes 1 (which is 2 - 1, and thus acceptable).
        uint256 tokenIdToTransfer_ = token.tokenId() - 1;
        vm.prank(delegator);
        token.transferFrom(delegator, address(2), tokenIdToTransfer_);

        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
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
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Remove both tokens: final balance becomes 0, which is below (2 - 1) = 1.
        uint256 tokenId1 = token.tokenId() - 2;
        uint256 tokenId2 = token.tokenId() - 1;
        vm.prank(delegator);
        token.transferFrom(delegator, address(3), tokenId1);
        vm.prank(delegator);
        token.transferFrom(delegator, address(4), tokenId2);

        vm.prank(dm);
        vm.expectRevert(bytes("ERC721BalanceChangeEnforcer:exceeded-balance-decrease"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Validates that the terms are well-formed (exactly 73 bytes)
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small: missing required bytes.
        terms_ = abi.encodePacked(false, address(token), address(delegator), uint8(1));
        vm.expectRevert(bytes("ERC721BalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large: extra bytes.
        terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(1), uint256(1));
        vm.expectRevert(bytes("ERC721BalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address causes a revert when calling beforeHook.
    function test_invalid_tokenAddress() public {
        bytes memory terms_ = abi.encodePacked(false, address(0), address(delegator), uint256(1));
        vm.expectRevert();
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if an unrealistic amount triggers overflow.
    function test_notAllow_expectingOverflow() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.expectRevert();
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Fails with an invalid execution mode (non-default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
