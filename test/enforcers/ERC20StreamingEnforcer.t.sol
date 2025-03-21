// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC20StreamingEnforcer } from "../../src/enforcers/ERC20StreamingEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

contract ERC20StreamingEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC20StreamingEnforcer public erc20StreamingEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;

    BasicERC20 public basicERC20;
    // --- Added state variable for the mock token ---
    MockERC20 public mockToken;
    address public alice;
    address public bob;
    address public carol;
    bytes32 public delegationHash;

    // Test parameters
    uint256 constant INITIAL_AMOUNT = 10 ether;
    uint256 constant MAX_AMOUNT = 100 ether;
    uint256 constant AMOUNT_PER_SECOND = 1 ether;

    ////////////////////// Set up //////////////////////
    function setUp() public override {
        super.setUp();
        erc20StreamingEnforcer = new ERC20StreamingEnforcer();
        vm.label(address(erc20StreamingEnforcer), "Streaming ERC20 Enforcer");
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();

        alice = address(users.alice.deleGator);
        bob = address(users.bob.deleGator);
        carol = address(users.carol.deleGator);

        basicERC20 = new BasicERC20(alice, "TestToken", "TestToken", 100 ether);
        // --- Deploy the mock token used for the streaming allowance drain test ---
        mockToken = new MockERC20("Mock Token", "MOCK");
        mockToken.mint(address(users.alice.deleGator), 200 ether);

        // Fund the wallets with ETH for gas
        vm.deal(address(users.alice.deleGator), 10 ether);
        vm.deal(address(users.bob.deleGator), 10 ether);

        // Labels
        vm.label(address(erc20StreamingEnforcer), "ERC20StreamingEnforcer");
        vm.label(address(allowedTargetsEnforcer), "AllowedTargetsEnforcer");
        vm.label(address(allowedMethodsEnforcer), "AllowedMethodsEnforcer");
        vm.label(address(basicERC20), "BasicERC20");
        vm.label(address(mockToken), "MockToken");
    }

    //////////////////// Error / Revert Tests //////////////////////
    /**
     * @notice Ensures it reverts if `_terms.length != 148`.
     */
    function test_invalidTermsLength() public {
        // Provide less than 148 bytes
        bytes memory badTerms_ = new bytes(100);

        // Minimal callData_
        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        vm.expectRevert(bytes("ERC20StreamingEnforcer:invalid-terms-length"));
        erc20StreamingEnforcer.beforeHook(badTerms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /**
     * @notice Checks revert if `maxAmount < initialAmount`.
     */
    function test_invalidMaxAmount() public {
        // initial=100, max=50 => revert
        bytes memory terms_ = _encodeTerms(
            address(basicERC20),
            100 ether, // initial
            50 ether, // max < initial
            1 ether,
            block.timestamp + 10
        );

        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        vm.expectRevert(bytes("ERC20StreamingEnforcer:invalid-max-amount"));
        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /**
     * @notice Test that it reverts if startTime == 0.
     */
    function test_invalidZeroStartTime() public {
        // Prepare valid token and amounts, but zero start time
        uint256 startTime_ = 0;
        bytes memory terms_ = _encodeTerms(address(basicERC20), 10 ether, 100 ether, 1 ether, startTime_);

        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        vm.expectRevert(bytes("ERC20StreamingEnforcer:invalid-zero-start-time"));
        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /**
     * @notice Test that it reverts with `ERC20StreamingEnforcer:allowance-exceeded`
     *         if the transfer request exceeds the currently unlocked amount.
     */
    function test_allowanceExceeded() public {
        // Start in the future => 0 available now
        uint256 futureStart_ = block.timestamp + 100;
        bytes memory terms_ = _encodeTerms(address(basicERC20), 50 ether, 100 ether, 1 ether, futureStart_);

        // Attempt to transfer 10 while 0 is unlocked
        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        vm.expectRevert(bytes("ERC20StreamingEnforcer:allowance-exceeded"));
        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /// @notice Test that it reverts with `ERC20StreamingEnforcer:invalid-execution-length` if the callData_ is not 68 bytes.
    function test_invalidExecutionLength() public {
        // valid `_terms`
        bytes memory terms_ = _encodeTerms(address(basicERC20), 100 ether, 1 ether, 1 ether, block.timestamp + 10);
        // Provide some random data that is not exactly 68 bytes
        bytes memory badCallData_ = new bytes(40);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, badCallData_);

        vm.expectRevert(bytes("ERC20StreamingEnforcer:invalid-execution-length"));
        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /**
     * @notice Test that it reverts with `ERC20StreamingEnforcer:invalid-method`
     *         if the selector isn't `IERC20.transfer.selector`.
     */
    function test_invalidMethodSelector() public {
        bytes memory terms_ = _encodeTerms(address(basicERC20), 100 ether, 100 ether, 1 ether, block.timestamp + 10);

        // Use `transferFrom` instead of `transfer`
        bytes memory badCallData_ = abi.encodeWithSelector(IERC20.transferFrom.selector, bob, 10 ether);

        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, badCallData_);

        vm.expectRevert(bytes("ERC20StreamingEnforcer:invalid-method"));
        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /// @notice Test that it reverts with `ERC20StreamingEnforcer:invalid-contract` if the token address doesn't match the target.
    function test_invalidContract() public {
        // Terms says the token is `basicERC20`, but we call a different target in `execData_`
        bytes memory terms_ = _encodeTerms(address(basicERC20), 100 ether, 100 ether, 1 ether, block.timestamp + 10);

        // Encode callData_ with correct selector but to a different contract address
        BasicERC20 otherToken_ = new BasicERC20(alice, "TestToken2", "TestToken2", 100 ether);
        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory execData_ = _encodeSingleExecution(address(otherToken_), 0, callData_);

        vm.expectRevert(bytes("ERC20StreamingEnforcer:invalid-contract"));
        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    //////////////////// Valid cases //////////////////////
    /**
     * @notice Test getTermsInfo() on correct 148-byte terms
     */
    function test_getTermsInfoHappyPath() public {
        address token_ = address(basicERC20);
        uint256 initialAmount_ = 100 ether;
        uint256 maxAmount_ = 200 ether;
        uint256 amountPerSecond_ = 1 ether;
        uint256 startTime_ = block.timestamp + 100;

        bytes memory termsData_ = _encodeTerms(token_, initialAmount_, maxAmount_, amountPerSecond_, startTime_);

        (
            address decodedToken_,
            uint256 decodedInitialAmount_,
            uint256 decodedMaxAmount_,
            uint256 decodedAmountPerSecond_,
            uint256 decodedStartTime_
        ) = erc20StreamingEnforcer.getTermsInfo(termsData_);

        assertEq(decodedToken_, token_, "Token mismatch");
        assertEq(decodedInitialAmount_, initialAmount_, "Initial amount mismatch");
        assertEq(decodedMaxAmount_, maxAmount_, "Max amount mismatch");
        assertEq(decodedAmountPerSecond_, amountPerSecond_, "Amount per second mismatch");
        assertEq(decodedStartTime_, startTime_, "Start time mismatch");
    }

    /// @notice Test that getTermsInfo() reverts with `ERC20StreamingEnforcer:invalid-terms-length` if `_terms` is not 148 bytes.
    function test_getTermsInfoInvalidLength() public {
        // Create terms shorter than 148 bytes
        bytes memory shortTermsData_ = new bytes(100);
        vm.expectRevert(bytes("ERC20StreamingEnforcer:invalid-terms-length"));
        erc20StreamingEnforcer.getTermsInfo(shortTermsData_);
    }

    /**
     * @notice Confirms the `IncreasedSpentMap` event is emitted for a valid transfer.
     */
    function test_increasedSpentMapEvent() public {
        uint256 initialAmount_ = 1 ether;
        uint256 maxAmount_ = 10 ether;
        uint256 amountPerSecond_ = 1 ether;
        uint256 startTime_ = block.timestamp;
        bytes memory terms_ = _encodeTerms(address(basicERC20), initialAmount_, maxAmount_, amountPerSecond_, startTime_);

        // Transfer 0.5 ether, which is below the allowance so it should succeed.
        uint256 transferAmount_ = 0.5 ether;
        bytes memory callData_ = _encodeERC20Transfer(bob, transferAmount_);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        vm.expectEmit(true, true, true, true, address(erc20StreamingEnforcer));
        emit ERC20StreamingEnforcer.IncreasedSpentMap(
            address(this), // sender = this test contract is calling beforeHook()
            alice, // redeemer = alice is the original message sender in this scenario
            bytes32(0), // example delegationHash (we're using 0 here)
            address(basicERC20), // token
            initialAmount_,
            maxAmount_,
            amountPerSecond_,
            startTime_,
            transferAmount_, // spent amount after this transfer
            block.timestamp // lastUpdateTimestamp (the event uses current block timestamp)
        );

        erc20StreamingEnforcer.beforeHook(
            terms_,
            bytes(""), // no additional data
            singleDefaultMode, // single execution singleDefaultMode
            execData_,
            bytes32(0), // example delegation hash
            address(0), // extra param (unused here)
            alice // redeemer
        );

        // Verify final storage
        (uint256 storedInitial_, uint256 storedMax, uint256 storedRate_, uint256 storedStart_, uint256 storedSpent_) =
            erc20StreamingEnforcer.streamingAllowances(address(this), bytes32(0));

        assertEq(storedInitial_, initialAmount_, "Should store the correct initialAmount");
        assertEq(storedMax, maxAmount_, "Should store correct max");
        assertEq(storedRate_, amountPerSecond_, "Should store the correct amountPerSecond");
        assertEq(storedStart_, startTime_, "Should store the correct startTime");
        assertEq(storedSpent_, transferAmount_, "Should record the correct spent");
    }

    /**
     * @notice Test that no tokens are available before the configured start time.
     */
    function test_getAvailableAmountBeforeStartTime() public {
        // This start time is in the future
        uint256 futureStart_ = block.timestamp + 1000;
        bytes memory terms_ = _encodeTerms(address(basicERC20), 50 ether, 100 ether, 1 ether, futureStart_);

        // Prepare a valid IERC20.transfer call
        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        // Calls beforeHook expecting no tokens to be spendable => must revert
        vm.expectRevert("ERC20StreamingEnforcer:allowance-exceeded");
        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        // Checking getAvailableAmount directly also returns 0
        uint256 available_ = erc20StreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 0, "Expected 0 tokens available before start time");
    }

    /**
     * @notice Demonstrates a scenario with initial=0, purely linear streaming.
     */
    function test_linearStreamingWithInitialZero() public {
        // initial=0 => nothing at startTime, tokens accrue at rate=1 ether/sec
        // up to max=5
        bytes memory terms_ = _encodeTerms(
            address(basicERC20),
            0, // initial
            5 ether, // max
            1 ether, // rate
            block.timestamp
        );

        uint256 available_ = erc20StreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 0, "Should have 0 tokens available");

        // After 3 seconds => 3 unlocked (since initial=0)
        vm.warp(block.timestamp + 3);

        // Transfer 2 => ok
        bytes memory callData_ = _encodeERC20Transfer(bob, 2 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        // 3 were unlocked, spent=2 => 1 left
        available_ = erc20StreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 1 ether, "Should have 1 ether left after spending 2 of 3");

        // Another 10 seconds => total unlocked=3+10=13, but clamp at max=5 => total=5 => spent=2 => 3 left
        vm.warp(block.timestamp + 10);
        available_ = erc20StreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 3 ether, "Should clamp at max=5, spent=2 => 3 remain");
    }

    /**
     * @notice Demonstrates a scenario with initial>0 plus linear streaming,
     *         verifying partial spends and the max clamp.
     */
    function test_linearStreamingWithInitialNonzero() public {
        // initial=10 => available at startTime, rate=2 => 2 tokens added each second, up to max=20
        uint256 startTime_ = block.timestamp;
        bytes memory terms_ = _encodeTerms(address(basicERC20), 10 ether, 20 ether, 2 ether, startTime_);

        // Transfer 5 immediately => 5 left (spent=5)
        bytes memory callData_ = _encodeERC20Transfer(bob, 5 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        // spent=5, unlocked=10 => 5 remain
        uint256 available_ = erc20StreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 5 ether, "Should have 5 left from the initial chunk after spending 5");

        // warp 5 seconds => totalUnlocked=10 + (2*5)=20 => at or beyond max=20 => clamp=20 => spent=5 => 15 left
        vm.warp(block.timestamp + 5);
        available_ = erc20StreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 15 ether, "Should have 15 left after 5 seconds of linear accrual, clamped at 20");

        // Transfer 15 => total spent=20 => 0 remain
        callData_ = _encodeERC20Transfer(bob, 15 ether);
        execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        available_ = erc20StreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 0, "Should have 0 left after spending 20 total");
    }

    /**
     * @notice Ensures that once the streaming allowance is fully consumed (spent == maxAmount),
     *         any further transfer attempt reverts with `allowance-exceeded`.
     */
    function test_fullySpentCannotTransferMore() public {
        // initial=5 => immediately available
        // plus linear accrual => rate=2 => but max=5 => we can never exceed 5 total unlocked
        // so effectively it's all unlocked at startTime, because initial=5 already hits the max
        uint256 startTime_ = block.timestamp;
        bytes memory terms_ = _encodeTerms(address(basicERC20), 5 ether, 5 ether, 2 ether, startTime_);

        // Transfer the full 5 => should succeed
        bytes memory callData_ = _encodeERC20Transfer(bob, 5 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        // Now spent == maxAmount (5). No more tokens remain.
        // Another attempt to transfer any positive amount should revert
        callData_ = _encodeERC20Transfer(bob, 1 ether);
        execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        vm.expectRevert(bytes("ERC20StreamingEnforcer:allowance-exceeded"));
        erc20StreamingEnforcer.beforeHook(terms_, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);
    }

    /**
     * @notice Tests that exactly initialAmount is available at startTime.
     */
    function test_availableAtExactStartTime() public {
        uint256 startTime_ = block.timestamp + 10;
        // initial=8, max=50, rate=2 => at startTime
        bytes memory terms = _encodeTerms(address(basicERC20), 8 ether, 50 ether, 2 ether, startTime_);
        vm.warp(startTime_);

        // Transfer the full 8 => should succeed
        bytes memory callData_ = _encodeERC20Transfer(bob, 8 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        erc20StreamingEnforcer.beforeHook(terms, bytes(""), singleDefaultMode, execData_, bytes32(0), address(0), alice);

        uint256 available_ = erc20StreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 0, "After transferring the initial amount 8 ether, 0 should remain at start date");

        // 5 seconds after start time, it should have accrued 10 ether
        vm.warp(block.timestamp + 5);
        available_ = erc20StreamingEnforcer.getAvailableAmount(address(this), bytes32(0));
        assertEq(available_, 10 ether, "After 10 seconds, 10 ether should be available");
    }

    /**
     * @notice Tests it fails with invalid call type singleDefaultMode (batch instead of single singleDefaultMode)
     */
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        erc20StreamingEnforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        erc20StreamingEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////
    /**
     * @notice Integration test: Successful native token streaming via delegation.
     * A delegation is created that uses the erc20StreamingEnforcer. Two native token transfers
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
        bytes memory terms = _encodeTerms(address(basicERC20), 5 ether, 20 ether, 2 ether, startTime);

        // Create a caveat that uses the native token streaming enforcer.
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ args: hex"", enforcer: address(erc20StreamingEnforcer), terms: terms });

        // Build a delegation using the caveats array.
        Delegation memory delegation =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats, salt: 0, signature: hex"" });
        delegation = signDelegation(users.alice, delegation);
        delegationHash = EncoderLib._getDelegationHash(delegation);

        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        uint256 balanceCarol = basicERC20.balanceOf(carol);

        // --- First UserOp: Transfer 3 native tokens ---
        // Create an execution that represents a native token transfer of 3 ether to Carol
        bytes memory callData_ = _encodeERC20Transfer(carol, 3 ether);
        Execution memory execution1 = Execution({ target: address(basicERC20), value: 0, callData: callData_ });

        // Invoke the delegation user op.
        invokeDelegation_UserOp(users.bob, delegations, execution1);

        balanceCarol += 3 ether;
        assertEq(basicERC20.balanceOf(carol), balanceCarol, "Carol should have received 3 ether");

        // At this point, the enforcer should have recorded 3 ether as spent.
        (uint256 storedInitial, uint256 storedMax, uint256 storedRate, uint256 storedStart, uint256 storedSpent) =
            erc20StreamingEnforcer.streamingAllowances(address(delegationManager), delegationHash);
        assertEq(storedInitial, 5 ether, "Initial amount should be 5 ether");
        assertEq(storedMax, 20 ether, "Max amount should be 20 ether");
        assertEq(storedRate, 2 ether, "Stored rate should be 2 ether");
        assertEq(storedStart, startTime, "Stored start should be startTime");
        assertEq(storedSpent, 3 ether, "Spent should be 3 ether after first op");

        // The unlocked amount at startTime is initial (5 ether), so available should be 5-3 = 2 ether.
        uint256 availableAfter1 = erc20StreamingEnforcer.getAvailableAmount(address(delegationManager), delegationHash);
        assertEq(availableAfter1, 2 ether, "Available should be 2 ether after first op");

        // --- Second UserOp: Transfer 4 native tokens after time warp ---
        // Warp forward 5 seconds. Now unlocked = 5 + (2 * 5) = 15 ether, cap is 20.
        vm.warp(block.timestamp + 5);

        // Create an execution for transferring 4 ether.
        callData_ = _encodeERC20Transfer(carol, 4 ether);
        Execution memory execution2 = Execution({ target: address(basicERC20), value: 0, callData: callData_ });

        // Invoke the user op.
        invokeDelegation_UserOp(users.bob, delegations, execution2);

        balanceCarol += 4 ether;
        assertEq(basicERC20.balanceOf(carol), balanceCarol, "Carol should have received 4 ether");

        // Total spent should now be 3 + 4 = 7 ether.
        (,,,, uint256 spentAfter2) = erc20StreamingEnforcer.streamingAllowances(address(delegationManager), delegationHash);
        assertEq(spentAfter2, 7 ether, "Spent should be 7 ether after second op");

        // Available should now be unlocked (15) - spent (7) = 8 ether.
        uint256 availableAfter2 = erc20StreamingEnforcer.getAvailableAmount(address(delegationManager), delegationHash);
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
        bytes memory terms = _encodeTerms(address(basicERC20), 5 ether, 5 ether, 1 ether, startTime);

        // Create caveats and delegation
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ args: hex"", enforcer: address(erc20StreamingEnforcer), terms: terms });
        Delegation memory delegation =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats, salt: 0, signature: hex"" });
        delegation = signDelegation(users.alice, delegation);
        delegationHash = EncoderLib._getDelegationHash(delegation);

        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        uint256 balanceCarol = basicERC20.balanceOf(carol);

        // First, invoke a user op to transfer the full 5 ether.
        bytes memory callData_ = _encodeERC20Transfer(carol, 5 ether);
        Execution memory execution1 = Execution({ target: address(basicERC20), value: 0, callData: callData_ });
        invokeDelegation_UserOp(users.bob, delegations, execution1);

        balanceCarol += 5 ether;
        assertEq(basicERC20.balanceOf(carol), balanceCarol, "Carol should have received 5 ether");

        // Now the allowance is fully consumed (spent == max = 5 ether). Available = 0.
        uint256 available = erc20StreamingEnforcer.getAvailableAmount(address(delegationManager), delegationHash);
        assertEq(available, 0, "Available should be 0 after full consumption");

        // Next, attempt another native token transfer of 1 ether.
        callData_ = _encodeERC20Transfer(carol, 1 ether);
        Execution memory execution2 = Execution({ target: address(basicERC20), value: 0, callData: callData_ });
        // vm.expectRevert(bytes("erc20StreamingEnforcer:allowance-exceeded"));
        invokeDelegation_UserOp(users.bob, delegations, execution2);

        assertEq(basicERC20.balanceOf(carol), balanceCarol, "Carol should not have received anything");
    }

    /**
     * @notice Integration test: Streaming allowance drain with failed transfers.
     * This test verifies that if a token transfer fails (simulated via MockERC20),
     * the streaming enforcer does not increase its recorded "spent" amount.
     */
    function test_streamingAllowanceDrainWithFailedTransfers() public {
        // Create streaming terms that define:
        // - initialAmount = 10 ether (available immediately at startTime)
        // - maxAmount = 100 ether (total streaming cap)
        // - amountPerSecond = 1 ether (streaming rate)
        // - startTime = current block timestamp (start streaming now)
        uint256 startTime_ = block.timestamp;
        bytes memory streamingTerms_ = abi.encodePacked(
            address(mockToken), // token address (20 bytes)
            uint256(INITIAL_AMOUNT), // initial amount (32 bytes)
            uint256(MAX_AMOUNT), // max amount (32 bytes)
            uint256(AMOUNT_PER_SECOND), // amount per second (32 bytes)
            uint256(startTime_) // start time (32 bytes)
        );

        Caveat[] memory caveats_ = new Caveat[](3);

        // Allowed Targets Enforcer - only allow the token
        caveats_[0] =
            Caveat({ enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(mockToken)), args: hex"" });

        // Allowed Methods Enforcer - only allow transfer
        caveats_[1] =
            Caveat({ enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IERC20.transfer.selector), args: hex"" });

        // ERC20 Streaming Enforcer - with the streaming terms
        caveats_[2] = Caveat({ enforcer: address(erc20StreamingEnforcer), terms: streamingTerms_, args: hex"" });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Sign the delegation
        delegation_ = signDelegation(users.alice, delegation_);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        // Initial balances
        uint256 aliceInitialBalance_ = mockToken.balanceOf(address(users.alice.deleGator));
        uint256 bobInitialBalance_ = mockToken.balanceOf(address(users.bob.addr));

        // Amount to transfer
        uint256 amountToTransfer = 5 ether;

        // First test - Successful transfer with default execution type
        {
            // Make sure token transfers will succeed
            mockToken.setHaltTransfer(false);

            // Prepare a transfer execution
            Execution memory execution_ = Execution({
                target: address(mockToken),
                value: 0,
                callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.addr), amountToTransfer)
            });

            // Execute the delegation using default mode
            execute_UserOp(
                users.bob,
                abi.encodeWithSelector(
                    delegationManager.redeemDelegations.selector,
                    _createPermissionContexts(delegation_),
                    _createModes(singleDefaultMode),
                    _createExecutionCallDatas(execution_)
                )
            );

            // Check balances after successful transfer
            uint256 aliceBalanceAfterSuccess_ = mockToken.balanceOf(address(users.alice.deleGator));
            uint256 bobBalanceAfterSuccess_ = mockToken.balanceOf(address(users.bob.addr));

            // Check streaming allowance state
            (,,,, uint256 storedSpent_) = erc20StreamingEnforcer.streamingAllowances(address(delegationManager), delegationHash_);
            assertEq(storedSpent_, amountToTransfer, "Spent amount should be updated after successful transfer");

            // Verify tokens were actually transferred
            assertEq(aliceBalanceAfterSuccess_, aliceInitialBalance_ - amountToTransfer, "Alice balance should decrease");
            assertEq(bobBalanceAfterSuccess_, bobInitialBalance_ + amountToTransfer, "Bob balance should increase");
        }

        // Second test - Failed transfer in try execution mode (transfer will fail)
        {
            // Make token transfers fail
            mockToken.setHaltTransfer(true);

            // Prepare the same transfer execution
            Execution memory execution_ = Execution({
                target: address(mockToken),
                value: 0,
                callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.addr), amountToTransfer)
            });

            // Record spent amount before the failed transfer
            (,,,, uint256 spentBeforeFailure_) =
                erc20StreamingEnforcer.streamingAllowances(address(delegationManager), delegationHash_);

            // Execute the delegation using try mode so execution continues despite transfer failure
            execute_UserOp(
                users.bob,
                abi.encodeWithSelector(
                    delegationManager.redeemDelegations.selector,
                    _createPermissionContexts(delegation_),
                    _createModes(singleTryMode),
                    _createExecutionCallDatas(execution_)
                )
            );

            // Check balances after failed transfer
            uint256 aliceBalanceAfterFailure_ = mockToken.balanceOf(address(users.alice.deleGator));
            uint256 bobBalanceAfterFailure_ = mockToken.balanceOf(address(users.bob.addr));

            // Check spent amount after failed transfer
            (,,,, uint256 spentAfterFailure_) =
                erc20StreamingEnforcer.streamingAllowances(address(delegationManager), delegationHash_);

            // The spent amount should NOT increase after a failed transfer
            assertEq(spentAfterFailure_, spentBeforeFailure_, "Spent amount should not increase after failed transfer");

            // Verify tokens weren't actually transferred
            assertEq(
                aliceBalanceAfterFailure_,
                aliceInitialBalance_ - amountToTransfer,
                "Alice balance should not change after failed transfer"
            );
            assertEq(
                bobBalanceAfterFailure_,
                bobInitialBalance_ + amountToTransfer,
                "Bob balance should not change after failed transfer"
            );
        }
    }

    ////////////////////// Helper functions //////////////////////
    /**
     * @notice Builds a 148-byte `_terms` data for the new streaming logic:
     *   [0..20]   = token address
     *   [20..52]  = initial amount
     *   [52..84]  = max amount
     *   [84..116] = amount per second
     *   [116..148]= start time
     */
    function _encodeTerms(
        address _token,
        uint256 _initialAmount,
        uint256 _maxAmount,
        uint256 _amountPerSecond,
        uint256 _startTime
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            bytes20(_token), bytes32(_initialAmount), bytes32(_maxAmount), bytes32(_amountPerSecond), bytes32(_startTime)
        );
    }

    /**
     * @dev Construct the callData_ for `IERC20.transfer(address,uint256)`.
     * @param _to Recipient of the transfer
     * @param _amount Amount to transfer
     */
    function _encodeERC20Transfer(address _to, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.transfer.selector, _to, _amount);
    }

    function _encodeSingleExecution(address _target, uint256 _value, bytes memory _callData) internal pure returns (bytes memory) {
        return abi.encodePacked(_target, _value, _callData);
    }

    function _createPermissionContexts(Delegation memory _delegation) internal pure returns (bytes[] memory) {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _delegation;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        return permissionContexts_;
    }

    function _createExecutionCallDatas(Execution memory _execution) internal pure returns (bytes[] memory) {
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(_execution.target, _execution.value, _execution.callData);
        return executionCallDatas_;
    }

    function _createModes(ModeCode _mode) internal pure returns (ModeCode[] memory) {
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = _mode;
        return modes_;
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(erc20StreamingEnforcer));
    }
}

/*
* @notice:  Added to support failed transfers
*/
contract MockERC20 is ERC20 {
    // Flag to make transfers fail
    bool public haltTransfers;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        haltTransfers = false;
    }

    function setHaltTransfer(bool _halt) external {
        haltTransfers = _halt;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (haltTransfers) return false; // Fail silently

        return super.transfer(to, amount);
    }
}
