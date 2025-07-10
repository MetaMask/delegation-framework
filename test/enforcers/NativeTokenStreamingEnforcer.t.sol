// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Caveat, Delegation, Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { NativeTokenStreamingEnforcer } from "../../src/enforcers/NativeTokenStreamingEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

contract NativeTokenStreamingEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    NativeTokenStreamingEnforcer public nativeTokenStreamingEnforcer;
    address public alice;
    address public bob;
    address public carol;

    ////////////////////// Set up //////////////////////
    function setUp() public override {
        super.setUp();
        nativeTokenStreamingEnforcer = new NativeTokenStreamingEnforcer();
        vm.label(address(nativeTokenStreamingEnforcer), "NativeTokenStreamingEnforcer");

        alice = address(users.alice.deleGator);
        bob = address(users.bob.deleGator);
        carol = address(users.carol.deleGator);
    }

    //////////////////// Error / Revert Tests //////////////////////

    /**
     * @notice Ensures it reverts if _terms is not exactly 128 bytes.
     */
    function test_invalidTermsLength() public {
        // Provide less than 128 bytes
        bytes memory badTerms_ = new bytes(100);

        // Build execution data with a native token value of 10 ether.
        bytes memory execData_ = _encodeNativeTokenExecution(10 ether);

        vm.expectRevert(bytes("NativeTokenStreamingEnforcer:invalid-terms-length"));
        nativeTokenStreamingEnforcer.beforeHook(badTerms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /**
     * @notice Checks revert if `maxAmount < initialAmount`.
     */
    function test_invalidMaxAmount() public {
        // initial = 100, max = 50 => invalid
        bytes memory terms_ = _encodeTerms(
            100 ether, // initialAmount
            50 ether, // maxAmount (invalid)
            1 ether, // amountPerSecond
            block.timestamp + 10
        );

        bytes memory execData_ = _encodeNativeTokenExecution(10 ether);

        vm.expectRevert(bytes("NativeTokenStreamingEnforcer:invalid-max-amount"));
        nativeTokenStreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /**
     * @notice Tests that it reverts if startTime == 0.
     */
    function test_invalidZeroStartTime() public {
        // Prepare valid token and amounts, but zero start time
        uint256 startTime_ = 0;
        bytes memory terms_ = _encodeTerms(
            10 ether, // initialAmount
            100 ether, // maxAmount
            1 ether, // rate
            startTime_
        );

        bytes memory execData_ = _encodeNativeTokenExecution(10 ether);

        vm.expectRevert(bytes("NativeTokenStreamingEnforcer:invalid-zero-start-time"));
        nativeTokenStreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /**
     * @notice Tests that it reverts if the native token transfer exceeds the unlocked amount.
     */
    function test_allowanceExceeded() public {
        // Start in the future => 0 available now
        uint256 futureStart_ = block.timestamp + 100;
        bytes memory terms_ = _encodeTerms(
            10 ether, // initialAmount
            50 ether, // maxAmount
            1 ether, // rate
            futureStart_
        );

        // Attempt to transfer 10 while 0 is unlocked
        bytes memory execData_ = _encodeNativeTokenExecution(10 ether);

        vm.expectRevert(bytes("NativeTokenStreamingEnforcer:allowance-exceeded"));
        nativeTokenStreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /**
     * @notice should fail with invalid call type mode (batch instead of single singleDefaultMode)
     */
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        nativeTokenStreamingEnforcer.beforeHook(
            hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0)
        );
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        nativeTokenStreamingEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    //////////////////// Valid cases //////////////////////

    /**
     * @notice Tests that getTermsInfo() correctly decodes a valid 128-byte terms payload.
     */
    function test_getTermsInfoHappyPath() public {
        uint256 initialAmount_ = 100 ether;
        uint256 maxAmount_ = 200 ether;
        uint256 amountPerSecond_ = 1 ether;
        uint256 startTime_ = block.timestamp + 100;

        bytes memory termsData_ = _encodeTerms(initialAmount_, maxAmount_, amountPerSecond_, startTime_);
        (uint256 decodedInit_, uint256 decodedMax_, uint256 decodedRate_, uint256 decodedStart_) =
            nativeTokenStreamingEnforcer.getTermsInfo(termsData_);

        assertEq(decodedInit_, initialAmount_, "Initial amount mismatch");
        assertEq(decodedMax_, maxAmount_, "Max amount mismatch");
        assertEq(decodedRate_, amountPerSecond_, "Rate mismatch");
        assertEq(decodedStart_, startTime_, "Start time mismatch");
    }

    /**
     * @notice Ensures getTermsInfo() reverts if _terms is not exactly 128 bytes.
     */
    function test_getTermsInfoInvalidLength() public {
        // Create terms shorter than 128 bytes
        bytes memory shortTerms_ = new bytes(100);
        vm.expectRevert(bytes("NativeTokenStreamingEnforcer:invalid-terms-length"));
        nativeTokenStreamingEnforcer.getTermsInfo(shortTerms_);
    }

    /**
     * @notice Confirms the IncreasedSpentMap event is emitted for a valid native token transfer.
     */
    function test_increasedSpentMapEvent() public {
        uint256 initialAmount_ = 1 ether;
        uint256 maxAmount_ = 10 ether;
        uint256 amountPerSecond_ = 1 ether;
        uint256 startTime_ = block.timestamp;
        bytes memory terms_ = _encodeTerms(initialAmount_, maxAmount_, amountPerSecond_, startTime_);

        // Transfer 0.5 ether, which is below the allowance so it should succeed.
        uint256 transferAmount_ = 0.5 ether;
        bytes memory execData_ = _encodeNativeTokenExecution(transferAmount_);

        vm.expectEmit(true, true, true, true, address(nativeTokenStreamingEnforcer));
        emit NativeTokenStreamingEnforcer.IncreasedSpentMap(
            address(this),
            alice,
            bytes32(0),
            initialAmount_,
            maxAmount_,
            amountPerSecond_,
            startTime_,
            transferAmount_,
            block.timestamp
        );

        nativeTokenStreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        // Verify final storage
        (uint256 storedInit_, uint256 storedMax_, uint256 storedRate_, uint256 storedStart_, uint256 storedSpent_) =
            nativeTokenStreamingEnforcer.streamingAllowances(address(this), bytes32(0));

        assertEq(storedInit_, initialAmount_, "Initial amount not stored correctly");
        assertEq(storedMax_, maxAmount_, "Max amount not stored correctly");
        assertEq(storedRate_, amountPerSecond_, "Rate not stored correctly");
        assertEq(storedStart_, startTime_, "Start time not stored correctly");
        assertEq(storedSpent_, transferAmount_, "Spent amount not updated correctly");
    }

    /**
     * @notice Tests that no native tokens are available before startTime.
     */
    function test_getAvailableAmountBeforeStartTime() public {
        // This start time is in the future
        uint256 futureStart_ = block.timestamp + 1000;
        bytes memory terms_ = _encodeTerms(50 ether, 100 ether, 1 ether, futureStart_);

        bytes memory execData_ = _encodeNativeTokenExecution(10 ether);

        // Calls beforeHook expecting no tokens to be spendable => must revert
        vm.expectRevert("NativeTokenStreamingEnforcer:allowance-exceeded");
        nativeTokenStreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        // Checking getAvailableAmount directly also returns 0
        uint256 available_ = nativeTokenStreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 0, "Expected 0 tokens available before startTime");
    }

    /**
     * @notice Demonstrates a scenario with initial=0, purely linear native token streaming.
     */
    function test_linearStreamingWithInitialZero() public {
        // initial=0 => nothing at startTime; accrues at 1 ether/sec, capped at 5.
        bytes memory terms_ = _encodeTerms(
            0, // initial
            5 ether, // max
            1 ether, // rate
            block.timestamp
        );

        uint256 available_ = nativeTokenStreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 0, "Should have 0 tokens available initially");

        // After 3 seconds => 3 unlocked (since initial=0)
        vm.warp(block.timestamp + 3);

        // Transfer 2 => ok
        bytes memory execData_ = _encodeNativeTokenExecution(2 ether);
        nativeTokenStreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        // 3 were unlocked, spent=2 => 1 left
        available_ = nativeTokenStreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 1 ether, "Expected 1 ether remaining after transfer");

        // Another 10 seconds => total unlocked=3+10=13, but clamp at max=5 => total=5 => spent=2 => 3 left
        vm.warp(block.timestamp + 10);
        available_ = nativeTokenStreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 3 ether, "Expected 3 ether remaining after clamping at max");
    }

    /**
     * @notice Demonstrates a scenario with initial>0 plus linear streaming,
     *         verifying partial spends and max clamp.
     */
    function test_linearStreamingWithInitialNonzero() public {
        // initial=10 => available at startTime, rate=2 => 2 tokens added each second, up to max=20

        uint256 startTime_ = block.timestamp;
        bytes memory terms = _encodeTerms(10 ether, 20 ether, 2 ether, startTime_);

        // Transfer 5 immediately => 5 left (spent=5)
        bytes memory execData_ = _encodeNativeTokenExecution(5 ether);
        nativeTokenStreamingEnforcer.beforeHook(terms, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        // spent=5, unlocked=10 => 5 remain
        uint256 available_ = nativeTokenStreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 5 ether, "Expected 5 ether remaining from initial chunk after spending 5");

        // warp 5 seconds => totalUnlocked=10 + (2*5)=20 => at or beyond max=20 => clamp=20 => spent=5 => 15 left
        vm.warp(block.timestamp + 5);
        available_ = nativeTokenStreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 15 ether, "Expected 15 ether remaining after accrual, clamped at 20");

        // Transfer 15 => total spent=20 => 0 remain
        execData_ = _encodeNativeTokenExecution(15 ether);
        nativeTokenStreamingEnforcer.beforeHook(terms, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        available_ = nativeTokenStreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 0, "Expected 0 remaining after full consumption");
    }

    /**
     * @notice Ensures that once the allowance is fully consumed (spent == maxAmount),
     *         any further native token transfer reverts with `allowance-exceeded`.
     */
    function test_fullySpentCannotTransferMore() public {
        // initial=5 => immediately available
        // plus linear accrual => rate=2 => but max=5 => we can never exceed 5 total unlocked
        // so effectively it's all unlocked at startTime, because initial=5 already hits the max
        uint256 startTime_ = block.timestamp;
        bytes memory terms = _encodeTerms(5 ether, 5 ether, 2 ether, startTime_);

        // Transfer the full 5 => should succeed
        bytes memory execData_ = _encodeNativeTokenExecution(5 ether);
        nativeTokenStreamingEnforcer.beforeHook(terms, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        // Now spent == maxAmount (5). No more tokens remain.
        // Another attempt to transfer any positive amount should revert
        execData_ = _encodeNativeTokenExecution(1 ether);
        vm.expectRevert(bytes("NativeTokenStreamingEnforcer:allowance-exceeded"));
        nativeTokenStreamingEnforcer.beforeHook(terms, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /**
     * @notice Tests that exactly initialAmount is available at startTime.
     */
    function test_availableAtExactStartTime() public {
        uint256 startTime_ = block.timestamp + 10;
        // initial=8, max=50, rate=2 => at startTime
        bytes memory terms_ = _encodeTerms(8 ether, 50 ether, 2 ether, startTime_);
        vm.warp(startTime_);

        bytes memory execData_ = _encodeNativeTokenExecution(8 ether);
        nativeTokenStreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        uint256 available_ = nativeTokenStreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 0, "After transferring the initial amount 8 ether, 0 should remain at start date");

        // 5 seconds after start time, it should have accruied 10 ether
        vm.warp(block.timestamp + 5);
        available_ = nativeTokenStreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 10 ether, "After 10 seconds, 10 ether should be available");
    }

    ////////////////////// Integration //////////////////////

    /**
     * @notice Integration test: Successful native token streaming via delegation.
     * A delegation is created that uses the NativeTokenStreamingEnforcer. Two native token transfers
     * (user ops) are executed sequentially. The test verifies that the enforcer’s state is updated
     * correctly and that the available amount decreases as expected.
     */
    function test_nativeTokenStreamingIntegration_Success() public {
        // Prepare the streaming terms:
        // initial = 5 ether (available immediately at startTime),
        // max = 20 ether (the cap),
        // rate = 2 ether per second,
        // startTime = current block timestamp.
        uint256 startTime = block.timestamp;
        bytes memory terms = _encodeTerms(5 ether, 20 ether, 2 ether, startTime);

        // Create a caveat that uses the native token streaming enforcer.
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ args: hex"", enforcer: address(nativeTokenStreamingEnforcer), terms: terms });

        // Build a delegation using the caveats array.
        Delegation memory delegation =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats, salt: 0, signature: hex"" });
        delegation = signDelegation(users.alice, delegation);
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        uint256 balanceCarol = carol.balance;

        // --- First UserOp: Transfer 3 native tokens ---
        // Create an execution that represents a native token transfer of 3 ether to Carol
        Execution memory execution1 = Execution({
            target: carol,
            value: 3 ether,
            callData: "" // no callData needed for native token transfer
         });

        // Invoke the delegation user op.
        invokeDelegation_UserOp(users.bob, delegations, execution1);

        balanceCarol += 3 ether;
        assertEq(carol.balance, balanceCarol, "Carol should have received 3 ether");

        // At this point, the enforcer should have recorded 3 ether as spent.
        (uint256 storedInitial, uint256 storedMax, uint256 storedRate, uint256 storedStart, uint256 storedSpent) =
            nativeTokenStreamingEnforcer.streamingAllowances(address(delegationManager), delegationHash);
        assertEq(storedInitial, 5 ether, "Initial amount should be 5 ether");
        assertEq(storedMax, 20 ether, "Max amount should be 20 ether");
        assertEq(storedRate, 2 ether, "Stored rate should be 2 ether");
        assertEq(storedStart, startTime, "Stored start should be startTime");
        assertEq(storedSpent, 3 ether, "Spent should be 3 ether after first op");

        // The unlocked amount at startTime is initial (5 ether), so available should be 5-3 = 2 ether.
        uint256 availableAfter1 = nativeTokenStreamingEnforcer.getAvailableAmount(address(delegationManager), delegationHash);
        assertEq(availableAfter1, 2 ether, "Available should be 2 ether after first op");

        // --- Second UserOp: Transfer 4 native tokens after time warp ---
        // Warp forward 5 seconds. Now unlocked = 5 + (2 * 5) = 15 ether, cap is 20.
        vm.warp(block.timestamp + 5);

        // Create an execution for transferring 4 ether.
        Execution memory execution2 = Execution({ target: carol, value: 4 ether, callData: "" });

        // Invoke the user op.
        invokeDelegation_UserOp(users.bob, delegations, execution2);

        balanceCarol += 4 ether;
        assertEq(carol.balance, balanceCarol, "Carol should have received 4 ether");

        // Total spent should now be 3 + 4 = 7 ether.
        (,,,, uint256 spentAfter2) = nativeTokenStreamingEnforcer.streamingAllowances(address(delegationManager), delegationHash);
        assertEq(spentAfter2, 7 ether, "Spent should be 7 ether after second op");

        // Available should now be unlocked (15) - spent (7) = 8 ether.
        uint256 availableAfter2 = nativeTokenStreamingEnforcer.getAvailableAmount(address(delegationManager), delegationHash);
        assertEq(availableAfter2, 8 ether, "Available should be 8 ether after second op");
    }

    /**
     * @notice Integration test: Failing native token streaming due to exceeding allowance.
     * A delegation is created with streaming terms where the maximum equals the initial amount.
     * After consuming the full allowance, a subsequent native token transfer attempt should revert.
     */
    function test_nativeTokenStreamingIntegration_ExceedsAllowance() public {
        // Set streaming terms:
        // initial = 5 ether, max = 5 ether (so no accrual beyond startTime), rate = 1 ether/sec.
        uint256 startTime = block.timestamp;
        bytes memory terms = _encodeTerms(5 ether, 5 ether, 1 ether, startTime);

        // Create caveats and delegation
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ args: hex"", enforcer: address(nativeTokenStreamingEnforcer), terms: terms });
        Delegation memory delegation =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats, salt: 0, signature: hex"" });
        delegation = signDelegation(users.alice, delegation);
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        uint256 balanceCarol = carol.balance;

        // First, invoke a user op to transfer the full 5 ether.
        Execution memory execution1 = Execution({ target: carol, value: 5 ether, callData: "" });
        invokeDelegation_UserOp(users.bob, delegations, execution1);

        balanceCarol += 5 ether;
        assertEq(carol.balance, balanceCarol, "Carol should have received 5 ether");

        // Now the allowance is fully consumed (spent == max = 5 ether). Available = 0.
        uint256 available = nativeTokenStreamingEnforcer.getAvailableAmount(address(delegationManager), delegationHash);
        assertEq(available, 0, "Available should be 0 after full consumption");

        // Next, attempt another native token transfer of 1 ether.
        Execution memory execution2 = Execution({ target: carol, value: 1 ether, callData: "" });
        invokeDelegation_UserOp(users.bob, delegations, execution2);

        assertEq(carol.balance, balanceCarol, "Carol should not have received anything");
    }

    ////////////////////// Helper Functions //////////////////////

    /**
     * @notice Builds a 128-byte _terms payload for the native token streaming logic:
     *   [0..32]   = initial amount
     *   [32..64]  = max amount
     *   [64..96]  = amount per second
     *   [96..128] = start time
     */
    function _encodeTerms(
        uint256 _initialAmount,
        uint256 _maxAmount,
        uint256 _amountPerSecond,
        uint256 _startTime
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(bytes32(_initialAmount), bytes32(_maxAmount), bytes32(_amountPerSecond), bytes32(_startTime));
    }

    /**
     * @notice Encodes a native token execution call.
     * @dev The execution data is encoded as (target, value, callData).
     * For native token transfers, callData is empty.
     * @param _value The native token amount.
     */
    function _encodeNativeTokenExecution(uint256 _value) internal pure returns (bytes memory) {
        // Here, target is not used (we no longer check it). We encode a dummy address.
        return abi.encodePacked(address(0), _value, "");
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(nativeTokenStreamingEnforcer));
    }
}
