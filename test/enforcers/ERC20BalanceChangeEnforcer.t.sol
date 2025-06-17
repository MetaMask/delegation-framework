// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

import "../../src/utils/Types.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC20BalanceChangeEnforcer } from "../../src/enforcers/ERC20BalanceChangeEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC20BalanceChangeEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC20BalanceChangeEnforcer public enforcer;
    BasicERC20 public token;
    address delegator;
    address delegate;
    address recipient;
    address dm;
    Execution mintExecution;
    bytes mintExecutionCallData;

    ////////////////////////////// Set up //////////////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        recipient = address(users.carol.deleGator);
        dm = address(delegationManager);
        enforcer = new ERC20BalanceChangeEnforcer();
        vm.label(address(enforcer), "ERC20 Balance Change Enforcer");
        token = new BasicERC20(delegator, "TEST", "TEST", 0);
        vm.label(address(token), "ERC20 Test Token");
        mintExecution =
            Execution({ target: address(token), value: 0, callData: abi.encodeWithSelector(token.mint.selector, delegator, 100) });
        mintExecutionCallData = abi.encode(mintExecution);
    }

    ////////////////////////////// Basic Functionality //////////////////////////////

    // Validates the terms get decoded correctly for an increase scenario
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));
        (bool enforceDecrease_, address token_, address recipient_, uint256 amount_) = enforcer.getTermsInfo(terms_);
        assertEq(enforceDecrease_, false);
        assertEq(token_, address(token));
        assertEq(recipient_, address(recipient));
        assertEq(amount_, 100);
    }

    // Validates that a balance has increased at least the expected amount
    function test_allow_ifBalanceIncreases() public {
        // Terms: [flag=false, token, recipient, amount=100]
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));

        // Increase by 100
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 100);
        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Increase by 1000
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 1000);
        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that a delegation can be reused with different recipients (for increase) without interference
    function test_allow_reuseDelegationWithDifferentRecipients() public {
        // Terms for two different recipients (flag=false indicates increase expected)
        bytes memory terms1_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));
        bytes memory terms2_ = abi.encodePacked(false, address(token), address(delegator), uint256(100));

        // Increase for recipient
        vm.prank(dm);
        enforcer.beforeHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 100);
        vm.prank(dm);
        enforcer.afterHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Increase for delegator as recipient
        vm.prank(dm);
        enforcer.beforeHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(delegator, 100);
        vm.prank(dm);
        enforcer.afterHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that a balance decrease within the allowed range passes.
    // For decreases (flag = true), the enforcer now checks that the final balance is not below the cached balance minus the
    // allowed amount.
    // Example: if the cached balance is 100 and the allowed decrease is 10, the final balance must be at least 90.
    function test_allow_ifBalanceDoesNotDecreaseTooMuch() public {
        // Set an initial balance for the recipient.
        uint256 initialBalance_ = 100;
        vm.prank(delegator);
        token.mint(recipient, initialBalance_);

        // Terms: flag=true (decrease expected), token, recipient, allowed decrease amount = 10.
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(10));

        // Cache the initial balance via beforeHook.
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Simulate a decrease by transferring out 5 tokens (final balance becomes 95, which is >= 100 - 10)
        vm.prank(recipient);
        token.transfer(delegator, 5);

        // afterHook should pass since 95 >= 90.
        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // New Test: Reverts if the balance decreases too much (i.e. final balance falls below cached balance - allowed amount)
    function test_notAllow_excessiveDecrease() public {
        uint256 initialBalance_ = 100;
        vm.prank(delegator);
        token.mint(recipient, initialBalance_);

        // Terms: flag=true (decrease expected), token, recipient, allowed maximum decrease = 10.
        bytes memory terms_ = abi.encodePacked(true, address(token), address(recipient), uint256(10));

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Simulate an excessive decrease: transfer out 20 tokens (final balance becomes 80, which is below 100 - 10).
        vm.prank(recipient);
        token.transfer(delegator, 20);

        vm.prank(dm);
        vm.expectRevert(bytes("ERC20BalanceChangeEnforcer:exceeded-balance-decrease"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////////////// Errors //////////////////////////////

    // Reverts if an increase hasn't been sufficient
    function test_notAllow_insufficientIncrease() public {
        // Terms: flag=false (increase expected), required increase of 100 tokens.
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));

        // Mint only 10 tokens (insufficient increase)
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 10);
        vm.prank(dm);
        vm.expectRevert(bytes("ERC20BalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the enforcer is locked (i.e. reentrant beforeHook)
    function test_notAllow_reenterALockedEnforcer() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));
        bytes32 delegationHash_ = bytes32(uint256(99999999));

        vm.startPrank(dm);
        // First call locks the enforcer.
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, delegator, delegate);
        bytes32 hashKey_ = enforcer.getHashKey(address(delegationManager), address(token), delegationHash_);
        assertTrue(enforcer.isLocked(hashKey_));
        vm.expectRevert(bytes("ERC20BalanceChangeEnforcer:enforcer-is-locked"));
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, delegator, delegate);
        vm.stopPrank();

        vm.startPrank(delegator);
        token.mint(recipient, 1000);
        vm.stopPrank();

        vm.startPrank(dm);
        // AfterHook unlocks the enforcer.
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, delegator, delegate);
        assertFalse(enforcer.isLocked(hashKey_));
        // Can be used again, and the lock is reengaged.
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, delegator, delegate);
        assertTrue(enforcer.isLocked(hashKey_));
        vm.stopPrank();
    }

    // Reverts if no increase happens when one is expected
    function test_notAllow_noIncreaseToRecipient() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100));

        // Cache the initial balance.
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Do not modify recipient's balance.
        vm.prank(dm);
        vm.expectRevert(bytes("ERC20BalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that the terms are well formed (exactly 73 bytes)
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small: missing required bytes (should be 73 bytes)
        terms_ = abi.encodePacked(false, address(token), address(recipient), uint8(100));
        vm.expectRevert(bytes("ERC20BalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large: extra bytes beyond 73.
        terms_ = abi.encodePacked(false, address(token), address(recipient), uint256(100), uint256(100));
        vm.expectRevert(bytes("ERC20BalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address (address(0)) reverts when calling beforeHook.
    function test_invalid_tokenAddress() public {
        bytes memory terms_ = abi.encodePacked(false, address(0), address(recipient), uint256(100));
        vm.expectRevert();
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts when the balance increase triggers an overflow.
    function test_notAllow_expectingOverflow() public {
        bytes memory terms_ = abi.encodePacked(false, address(token), address(recipient), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.expectRevert();
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the execution mode is invalid (not default).
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
