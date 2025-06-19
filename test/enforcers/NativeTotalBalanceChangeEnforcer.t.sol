// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../src/utils/Types.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { NativeTotalBalanceChangeEnforcer } from "../../src/enforcers/NativeTotalBalanceChangeEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Counter } from "../utils/Counter.t.sol";

contract NativeTotalBalanceChangeEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    NativeTotalBalanceChangeEnforcer public enforcer;
    address delegator;
    address delegate;
    address dm;
    Execution noExecution;
    bytes executionCallData = abi.encode(noExecution);

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        dm = address(delegationManager);
        enforcer = new NativeTotalBalanceChangeEnforcer();
        vm.label(address(enforcer), "Native Balance Change Enforcer");
        noExecution = Execution(address(0), 0, hex"");
    }

    ////////////////////// Basic Functionality //////////////////////

    // Validates the terms get decoded correctly
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(false, address(users.carol.deleGator), uint256(100));
        bool enforceDecrease_;
        uint256 amount_;
        address recipient_;
        (enforceDecrease_, recipient_, amount_) = enforcer.getTermsInfo(terms_);
        assertFalse(enforceDecrease_);
        assertEq(recipient_, address(users.carol.deleGator));
        assertEq(amount_, 100);
    }

    // Validates that getHashKey function returns the correct hash
    function test_getHashKey() public {
        address caller_ = address(dm);
        address recipient_ = address(delegator);

        bytes32 expectedHash_ = keccak256(abi.encode(caller_, recipient_));
        bytes32 actualHash_ = enforcer.getHashKey(caller_, recipient_);

        assertEq(actualHash_, expectedHash_, "getHashKey should return correct hash");
    }

    // Validates that a balance has increased at least the expected amount
    function test_allow_ifBalanceIncreases() public {
        address recipient_ = delegator;
        // Expect it to increase by at least 100
        bytes memory terms_ = abi.encodePacked(false, recipient_, uint256(100));

        // Increase by 100
        vm.startPrank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        _increaseBalance(delegator, 100);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Increase by 1000
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        _increaseBalance(delegator, 1000);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    // Validates that a balance has decreased at most the expected amount
    function test_allow_ifBalanceDecreases() public {
        address recipient_ = delegator;
        vm.deal(recipient_, 1000); // Start with 1000
        // Expect it to decrease by at most 100
        bytes memory terms_ = abi.encodePacked(true, recipient_, uint256(100));

        // Decrease by 50
        vm.startPrank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        _decreaseBalance(delegator, 50);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Decrease by 100
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        _decreaseBalance(delegator, 100);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////// Errors //////////////////////

    // Reverts if a balance hasn't increased by the specified amount
    function test_notAllow_insufficientIncrease() public {
        address recipient_ = delegator;
        // Expect it to increase by at least 100
        bytes memory terms_ = abi.encodePacked(false, recipient_, uint256(100));

        // Increase by 10, expect revert
        vm.startPrank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        _increaseBalance(delegator, 10);
        vm.expectRevert(bytes("NativeTotalBalanceChangeEnforcer:insufficient-balance-increase"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if a balance has decreased more than the specified amount
    function test_notAllow_excessiveDecrease() public {
        address recipient_ = delegator;
        vm.deal(recipient_, 1000); // Start with 1000
        // Expect it to decrease by at most 100
        bytes memory terms_ = abi.encodePacked(true, recipient_, uint256(100));

        // Decrease by 150, expect revert
        vm.startPrank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        _decreaseBalance(delegator, 150);
        vm.expectRevert(bytes("NativeTotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    // Validates the terms are well formed
    function test_invalid_decodedTheTerms() public {
        address recipient_ = delegator;
        bytes memory terms_;

        // Too small
        terms_ = abi.encodePacked(false, recipient_, uint8(100));
        vm.expectRevert(bytes("NativeTotalBalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large
        terms_ = abi.encodePacked(false, uint256(100), uint256(100));
        vm.expectRevert(bytes("NativeTotalBalanceChangeEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid ID reverts
    function test_notAllow_expectingOverflow() public {
        address recipient_ = delegator;

        // Expect balance to increase so much that the validation overflows
        bytes memory terms_ = abi.encodePacked(false, recipient_, type(uint256).max);
        vm.deal(recipient_, type(uint256).max);
        vm.startPrank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        vm.expectRevert();
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeAllHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////////////// Multiple Enforcers //////////////////////////////

    function test_multiple_enforcers_insufficient_increase() public {
        address recipient_ = delegator;
        // increase by at least 100
        bytes memory terms_ = abi.encodePacked(false, recipient_, uint256(100));

        // we are running 2 enforcers in the delegation chain: both increasing by 100. Total expected balance change is an
        // increase of at least 200.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        _increaseBalance(delegator, 199);

        vm.expectRevert(bytes("NativeTotalBalanceChangeEnforcer:insufficient-balance-increase"));
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        _increaseBalance(delegator, 1);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    function test_multiple_enforcers_excessive_decrease() public {
        address recipient_ = delegator;
        vm.deal(recipient_, 1000); // Start with 1000

        // Expect it to decrease by at most 100
        bytes memory terms_ = abi.encodePacked(true, recipient_, uint256(100));

        // we are running 2 enforcers in the delegation chain: both decreasing by 100. Total expected balance change is an
        // decrease of at most 200.
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        _decreaseBalance(delegator, 201);

        vm.expectRevert(bytes("NativeTotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        _increaseBalance(delegator, 1);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    function test_mixed_enforcers_insufficient_increase() public {
        address recipient_ = delegator;
        // increase by at least 100
        bytes memory termsIncrease_ = abi.encodePacked(false, recipient_, uint256(100));
        // decrease by at most 100
        bytes memory termsDecrease_ = abi.encodePacked(true, recipient_, uint256(100));

        // we are running 3 enforcers in the delegation chain: 2 increasing and 1 decreasing. Total expected balance change is an
        // increase of at least 100.
        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        _increaseBalance(delegator, 99);

        vm.expectRevert(bytes("NativeTotalBalanceChangeEnforcer:insufficient-balance-increase"));
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        _increaseBalance(delegator, 1);

        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    function test_mixed_enforcers_excessive_decrease() public {
        address recipient_ = delegator;
        vm.deal(recipient_, 1000); // Start with 1000

        // increase by at least 100
        bytes memory termsIncrease_ = abi.encodePacked(false, recipient_, uint256(100));
        // decrease by at most 100
        bytes memory termsDecrease_ = abi.encodePacked(true, recipient_, uint256(100));

        // we are running 3 enforcers in the delegation chain: 1 increasing and 2 decreasing. Total expected balance change is an
        // decrease of at most 100.
        vm.prank(dm);
        enforcer.beforeAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.beforeAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        _decreaseBalance(delegator, 101);

        vm.expectRevert(bytes("NativeTotalBalanceChangeEnforcer:exceeded-balance-decrease"));
        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        _increaseBalance(delegator, 1);

        vm.prank(dm);
        enforcer.afterAllHook(termsIncrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        vm.prank(dm);
        enforcer.afterAllHook(termsDecrease_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////////////// Check events //////////////////////////////

    function test_events_emitted_correctly() public {
        address recipient_ = delegator;
        // Increase by 100
        bytes memory terms_ = abi.encodePacked(false, recipient_, uint256(100));

        // First beforeAllHook - should emit TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit NativeTotalBalanceChangeEnforcer.TrackedBalance(dm, recipient_, 100000000000000000000);
        vm.expectEmit(true, true, true, true);
        emit NativeTotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, recipient_, false, 100);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient_, delegate);

        // Second beforeAllHook should ONLY emit UpdatedExpectedBalance
        vm.recordLogs();
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient_, delegate);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "Should only emit one event");

        // Verify it's the UpdatedExpectedBalance event
        assertEq(logs[0].topics[0], keccak256("UpdatedExpectedBalance(address,address,bool,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(dm)))); // delegationManager
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(recipient_))))); // recipient

        _increaseBalance(recipient_, 200);

        // First afterAllHook - should emit ValidatedBalance
        vm.expectEmit(true, true, true, true);
        emit NativeTotalBalanceChangeEnforcer.ValidatedBalance(dm, delegator, 200);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);

        // Second afterAllHook should not emit anything
        vm.recordLogs();
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        assertEq(logs2.length, 0, "Should not emit any events");
    }

    function test_events_emitted_correctly_with_decrease() public {
        address recipient_ = delegator;
        // Decrease by 100
        bytes memory terms_ = abi.encodePacked(true, recipient_, uint256(100));

        // First beforeAllHook - should emit TrackedBalance and UpdatedExpectedBalance
        vm.expectEmit(true, true, true, true);
        emit NativeTotalBalanceChangeEnforcer.TrackedBalance(dm, recipient_, 100000000000000000000);
        vm.expectEmit(true, true, true, true);
        emit NativeTotalBalanceChangeEnforcer.UpdatedExpectedBalance(dm, recipient_, true, 100);
        vm.prank(dm);
        enforcer.beforeAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), recipient_, delegate);

        _decreaseBalance(recipient_, 100);

        // First afterAllHook - should emit ValidatedBalance
        vm.expectEmit(true, true, true, true);
        emit NativeTotalBalanceChangeEnforcer.ValidatedBalance(dm, delegator, 100);
        vm.prank(dm);
        enforcer.afterAllHook(terms_, hex"", singleDefaultMode, executionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////////////// Helper functions //////////////////////////////

    function _increaseBalance(address _recipient, uint256 _amount) internal {
        vm.deal(_recipient, _recipient.balance + _amount);
    }

    function _decreaseBalance(address _recipient, uint256 _amount) internal {
        vm.deal(_recipient, _recipient.balance - _amount);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
