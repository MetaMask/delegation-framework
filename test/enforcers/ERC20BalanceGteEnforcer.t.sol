// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

import "../../src/utils/Types.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC20BalanceGteEnforcer } from "../../src/enforcers/ERC20BalanceGteEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC20BalanceGteEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC20BalanceGteEnforcer public enforcer;
    BasicERC20 public token;
    address delegator;
    address delegate;
    address recipient;
    address dm;
    Execution mintExecution;
    bytes mintExecutionCallData;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        recipient = address(users.carol.deleGator);
        dm = address(delegationManager);
        enforcer = new ERC20BalanceGteEnforcer();
        vm.label(address(enforcer), "ERC20 BalanceGte Enforcer");
        token = new BasicERC20(delegator, "TEST", "TEST", 0);
        vm.label(address(token), "ERC20 Test Token");
        mintExecution =
            Execution({ target: address(token), value: 0, callData: abi.encodeWithSelector(token.mint.selector, delegator, 100) });
        mintExecutionCallData = abi.encode(mintExecution);
    }

    ////////////////////// Basic Functionality //////////////////////

    // Validates the terms get decoded correctly
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(address(recipient), address(token), uint256(100));
        uint256 amount_;
        address token_;
        address recipient_;
        (recipient_, token_, amount_) = enforcer.getTermsInfo(terms_);
        assertEq(amount_, 100);
        assertEq(token_, address(token));
        assertEq(recipient_, address(recipient));
    }

    // Validates that a balance has increased at least the expected amount
    function test_allow_ifBalanceIncreases() public {
        // Expect it to increase by at least 100
        bytes memory terms_ = abi.encodePacked(address(recipient), address(token), uint256(100));

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

    // Validates that the delegation can be reused with different recipients
    function test_allow_reuseDelegationWithDifferentRecipients() public {
        // Expect it to increase by at least 100
        bytes memory terms1_ = abi.encodePacked(address(recipient), address(token), uint256(100));
        bytes memory terms2_ = abi.encodePacked(address(delegator), address(token), uint256(100));

        // Increase by 100, check for recipient
        vm.prank(dm);
        enforcer.beforeHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 100);
        vm.prank(dm);
        enforcer.afterHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // Increase by 100, check for delegator as recipient
        vm.prank(dm);
        enforcer.beforeHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(delegator, 100);
        vm.prank(dm);
        enforcer.afterHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // ////////////////////// Errors //////////////////////

    // Reverts if a balance hasn't increased by the set amount
    function test_notAllow_insufficientIncrease() public {
        // Expect it to increase by at least 100
        bytes memory terms_ = abi.encodePacked(address(recipient), address(token), uint256(100));

        // Increase by 10, expect revert
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.prank(delegator);
        token.mint(recipient, 10);
        vm.prank(dm);
        vm.expectRevert(bytes("ERC20BalanceGteEnforcer:balance-not-gt"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if a enforcer is locked
    function test_notAllow_reenterALockedEnforcer() public {
        // Expect it to increase by at least 100
        bytes memory terms_ = abi.encodePacked(address(recipient), address(token), uint256(100));
        bytes32 delegationHash_ = bytes32(uint256(99999999));

        // Increase by 100
        vm.startPrank(dm);
        // Locks the enforcer
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, delegator, delegate);
        bytes32 hashKey_ = enforcer.getHashKey(address(delegationManager), address(token), delegationHash_);
        assertTrue(enforcer.isLocked(hashKey_));
        vm.expectRevert(bytes("ERC20BalanceGteEnforcer:enforcer-is-locked"));
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, delegator, delegate);
        vm.startPrank(delegator);
        token.mint(recipient, 1000);
        vm.startPrank(dm);

        // Unlocks the enforcer
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, delegator, delegate);
        assertFalse(enforcer.isLocked(hashKey_));
        // Can be used again, and locks it again
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, delegator, delegate);
        assertTrue(enforcer.isLocked(hashKey_));
    }

    // Reverts if the recipient didn't receive any tokens
    function test_notAllow_noIncreaseToRecipient() public {
        bytes memory terms_ = abi.encodePacked(address(recipient), address(token), uint256(100));

        // BeforeHook should cache the recipient's balance
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);

        // No tokens are minted to the recipient, so balance shouldn't increase
        vm.prank(dm);
        vm.expectRevert(bytes("ERC20BalanceGteEnforcer:balance-not-gt"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates the terms are well formed
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small
        terms_ = abi.encodePacked(address(recipient), address(token), uint8(100));
        vm.expectRevert(bytes("ERC20BalanceGteEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large
        terms_ = abi.encodePacked(address(recipient), address(token), uint256(100), uint256(100));
        vm.expectRevert(bytes("ERC20BalanceGteEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates the token address is a token
    function test_invalid_tokenAddress() public {
        bytes memory terms_;

        // Invalid token
        terms_ = abi.encodePacked(address(recipient), address(0), uint256(100));
        vm.expectRevert();
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that an invalid ID reverts
    function test_notAllow_expectingOverflow() public {
        // Expect balance to increase so much that the balance overflows
        bytes memory terms_ = abi.encodePacked(address(recipient), address(token), type(uint256).max);

        // Increase
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
        vm.expectRevert();
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), delegator, delegate);
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
