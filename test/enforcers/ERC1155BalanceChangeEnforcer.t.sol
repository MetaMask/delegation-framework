// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../src/utils/Types.sol";
import { BasicERC1155 } from "../utils/BasicERC1155.t.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC1155BalanceChangeEnforcer } from "../../src/enforcers/ERC1155BalanceChangeEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC1155BalanceChangeEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC1155BalanceChangeEnforcer public enforcer;
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
        enforcer = new ERC1155BalanceChangeEnforcer();
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
        (bool enforceDecrease_, address token_, address recipient_, uint256 tokenId_, uint256 amount_) =
            enforcer.getTermsInfo(terms_);
        assertEq(enforceDecrease_, true);
        assertEq(token_, address(token));
        assertEq(recipient_, delegator);
        assertEq(tokenId_, tokenId);
        assertEq(amount_, 100);
    }

    // Validates that a balance has increased at least by the expected amount.
    function test_allow_ifBalanceIncreases() public {
        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        // Increase by 100.
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");
        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Increase by 1000.
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 1000, "");
        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    ////////////////////// Errors //////////////////////

    // Reverts if a balance hasn't increased by the set amount.
    function test_notAllow_insufficientIncrease() public {
        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        // Increase by 10 only, expect revert.
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 10, "");
        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155BalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if a balance decreases in between the hooks.
    function test_notAllow_ifBalanceDecreases() public {
        // Starting with 10 tokens.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 10, "");

        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Decrease balance by transferring tokens away.
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(1), tokenId, 10, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155BalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
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
            enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
            vm.prank(delegator);
            token.mint(currentRecipient_, tokenId, 100, "");
            vm.prank(dm);
            enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
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
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Increase balance by 50 only.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 50, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155BalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Differentiates delegation hash with different recipients.
    function test_differentiateDelegationHashWithRecipient() public {
        bytes32 delegationHash_ = bytes32(uint256(99999999));
        address recipient2_ = address(1111111);
        // Terms for two different recipients.
        bytes memory terms1_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));
        bytes memory terms2_ = abi.encodePacked(false, address(token), recipient2_, uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        vm.prank(dm);
        enforcer.beforeHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance by 100 only for recipient1.
        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");

        // Recipient1 passes.
        vm.prank(dm);
        enforcer.afterHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Recipient2 did not receive tokens, so it should revert.
        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155BalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance for recipient2.
        vm.prank(delegator);
        token.mint(recipient2_, tokenId, 100, "");

        // Recipient2 now passes.
        vm.prank(dm);
        enforcer.afterHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
    }

    // Reverts if the enforcer is locked (i.e. if beforeHook is reentered).
    function test_notAllow_reenterALockedEnforcer() public {
        // Expect increase by at least 100.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100));
        bytes32 delegationHash_ = bytes32(uint256(99999999));

        vm.startPrank(dm);
        // Lock the enforcer.
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        bytes32 hashKey_ =
            enforcer.getHashKey(address(delegationManager), address(token), address(delegator), tokenId, delegationHash_);
        assertTrue(enforcer.isLocked(hashKey_));
        vm.expectRevert(bytes("ERC1155BalanceChangeEnforcer:enforcer-is-locked"));
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        vm.stopPrank();

        vm.prank(delegator);
        token.mint(delegator, tokenId, 1000, "");

        vm.startPrank(dm);
        // Unlock the enforcer.
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        assertFalse(enforcer.isLocked(hashKey_));
        // Reuse the enforcer, which locks it again.
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        assertTrue(enforcer.isLocked(hashKey_));
        vm.stopPrank();
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
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Remove 10 tokens: final balance becomes 90, which is >= 100 - 20 = 80.
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(2), tokenId, 10, "");

        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
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
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Remove 30 tokens: final balance becomes 70, which is below 100 - 20 = 80.
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(3), tokenId, 30, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155BalanceChangeEnforcer:exceeded-balance-decrease"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    ////////////////////// Invalid Terms Tests //////////////////////

    // Validates that the terms are well-formed (exactly 105 bytes).
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small: missing required bytes (no boolean flag, etc.).
        terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));
        vm.expectRevert(bytes("ERC1155BalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large: extra bytes appended.
        terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), uint256(100), uint256(1));
        vm.expectRevert(bytes("ERC1155BalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address causes a revert.
    function test_invalid_tokenAddress() public {
        bytes memory terms_ = abi.encodePacked(false, address(0), address(delegator), uint256(tokenId), uint256(100));
        vm.expectRevert();
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if an unrealistic amount triggers overflow.
    function test_notAllow_expectingOverflow() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(delegator), uint256(tokenId), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.expectRevert();
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Fails with an invalid execution mode (non-default).
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
