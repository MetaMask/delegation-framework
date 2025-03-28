// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Caveat, Delegation, Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { MultiTokenPeriodEnforcer } from "../../src/enforcers/MultiTokenPeriodEnforcer.sol";
import { BasicERC20, IERC20 as BasicIERC20 } from "../utils/BasicERC20.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

contract MultiTokenPeriodEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    MultiTokenPeriodEnforcer public multiTokenEnforcer;
    BasicERC20 public basicERC20; // Used for ERC20 tests
    BasicERC20 public basicERC20B;

    address public alice;
    address public bob;

    // A dummy delegation hash for simulation.
    bytes32 dummyDelegationHash = keccak256("test-delegation");
    address redeemer = address(0x123);

    // Parameters for the ERC20 configuration.
    uint256 public erc20PeriodAmount = 1000;
    uint256 public erc20PeriodDuration = 1 days; // 86400 seconds
    uint256 public erc20StartDate;

    // Parameters for the native token configuration.
    uint256 public nativePeriodAmount = 1 ether;
    uint256 public nativePeriodDuration = 1 days;
    uint256 public nativeStartDate;

    ////////////////////// Set up //////////////////////
    function setUp() public override {
        super.setUp();
        multiTokenEnforcer = new MultiTokenPeriodEnforcer();
        vm.label(address(multiTokenEnforcer), "MultiToken Period Transfer Enforcer");

        alice = address(users.alice.deleGator);
        bob = address(users.bob.deleGator);
        basicERC20 = new BasicERC20(alice, "TestToken", "TT", 100 ether);
        basicERC20B = new BasicERC20(alice, "TestTokenB", "TTB", 50 ether);

        erc20StartDate = block.timestamp;
        nativeStartDate = block.timestamp;
        // For native tests, ensure the sender has ETH.
        vm.deal(alice, 100 ether);
    }

    ////////////////////// Error / Revert Tests //////////////////////

    /// @notice Ensures it reverts if _terms length is not a multiple of 116 bytes.
    function test_InvalidTermsLength() public {
        bytes memory invalidTerms_ = new bytes(115); // not a multiple of 116
        vm.expectRevert("MultiTokenPeriodEnforcer:invalid-terms-length");
        multiTokenEnforcer.getTermsInfo(invalidTerms_, address(basicERC20));
    }

    /// @notice Reverts if a token configuration is not found in _terms.
    function test_TokenConfigNotFound() public {
        // Encode only an ERC20 configuration.
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        // Request native config (address(0)) which is not present.
        vm.expectRevert("MultiTokenPeriodEnforcer:token-config-not-found");
        multiTokenEnforcer.getTermsInfo(terms_, address(0));
    }

    /// @notice Reverts if the ERC20 config has a zero start date.
    function test_InvalidZeroStartDateErc20() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, uint256(0));
        bytes memory callData_ = _encodeERC20Transfer(bob, 100);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        vm.expectRevert("MultiTokenPeriodEnforcer:invalid-zero-start-date");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the ERC20 config has a zero period duration.
    function test_InvalidZeroPeriodDurationErc20() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, uint256(0), erc20StartDate);
        bytes memory callData_ = _encodeERC20Transfer(bob, 100);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        vm.expectRevert("MultiTokenPeriodEnforcer:invalid-zero-period-duration");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the ERC20 config has a zero period amount.
    function test_InvalidZeroPeriodAmountErc20() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), uint256(0), erc20PeriodDuration, erc20StartDate);
        bytes memory callData_ = _encodeERC20Transfer(bob, 100);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        vm.expectRevert("MultiTokenPeriodEnforcer:invalid-zero-period-amount");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the ERC20 transfer is attempted before the start date.
    function test_TransferNotStartedErc20() public {
        uint256 futureStart_ = block.timestamp + 100;
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, futureStart_);
        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        vm.expectRevert("MultiTokenPeriodEnforcer:transfer-not-started");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the ERC20 execution call data length is invalid.
    function test_InvalidExecutionLengthErc20() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        bytes memory invalidExecData_ = new bytes(67);
        vm.expectRevert("MultiTokenPeriodEnforcer:invalid-execution-length");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, invalidExecData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the ERC20 target does not match the token in _terms.
    function test_InvalidContractErc20() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory invalidExecData_ = _encodeSingleExecution(address(0xdead), 0, callData_);
        vm.expectRevert("MultiTokenPeriodEnforcer:token-config-not-found");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, invalidExecData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the ERC20 call data selector is invalid.
    function test_InvalidMethodErc20() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        bytes memory invalidCallData_ = abi.encodeWithSelector(IERC20.transferFrom.selector, redeemer, 500);
        bytes memory invalidExecData_ = _encodeSingleExecution(address(basicERC20), 0, invalidCallData_);
        vm.expectRevert("MultiTokenPeriodEnforcer:invalid-method");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, invalidExecData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if an ERC20 transfer exceeds the available allowance.
    function test_TransferAmountExceededErc20() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        // First transfer: 800 tokens.
        bytes memory callData1_ = _encodeERC20Transfer(bob, 800);
        bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        // Second transfer: attempt 300 tokens (exceeds remaining allowance).
        bytes memory callData2_ = _encodeERC20Transfer(bob, 300);
        bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);
        vm.expectRevert("MultiTokenPeriodEnforcer:transfer-amount-exceeded");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Tests a successful ERC20 transfer and verifies that the TransferredInPeriod event is emitted.
    function test_SuccessfulTransferAndEventErc20() public {
        uint256 transferAmount_ = 500;
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        bytes memory callData_ = _encodeERC20Transfer(bob, transferAmount_);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        vm.expectEmit(true, true, true, true);
        emit MultiTokenPeriodEnforcer.TransferredInPeriod(
            address(this),
            redeemer,
            dummyDelegationHash,
            address(basicERC20),
            erc20PeriodAmount,
            erc20PeriodDuration,
            erc20StartDate,
            transferAmount_,
            block.timestamp
        );
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
        (uint256 available_,,) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
        assertEq(available_, erc20PeriodAmount - transferAmount_);
    }

    /// @notice Tests multiple ERC20 transfers within the same period.
    function test_MultipleTransfersInSamePeriodErc20() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        // First transfer: 400 tokens.
        bytes memory callData1_ = _encodeERC20Transfer(bob, 400);
        bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), bob);

        // Second transfer: 300 tokens.
        bytes memory callData2_ = _encodeERC20Transfer(bob, 300);
        bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), bob);

        (uint256 available_,,) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
        assertEq(available_, erc20PeriodAmount - 700);

        // Third transfer: attempt 400 tokens (should exceed allowance).
        bytes memory callData3_ = _encodeERC20Transfer(bob, 400);
        bytes memory execData3_ = _encodeSingleExecution(address(basicERC20), 0, callData3_);
        vm.expectRevert("MultiTokenPeriodEnforcer:transfer-amount-exceeded");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData3_, dummyDelegationHash, address(0), bob);
    }

    /// @notice Tests that the ERC20 allowance resets when a new period begins.
    function test_NewPeriodResetsAllowanceErc20() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        // First transfer: 800 tokens.
        bytes memory callData1_ = _encodeERC20Transfer(bob, 800);
        bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        (uint256 availableBefore_,, uint256 periodBefore_) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
        assertEq(availableBefore_, erc20PeriodAmount - 800);

        vm.warp(block.timestamp + erc20PeriodDuration + 1);

        (uint256 availableAfter_, bool isNewPeriod_, uint256 periodAfter_) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
        assertEq(availableAfter_, erc20PeriodAmount);
        assertTrue(isNewPeriod_);
        assertGt(periodAfter_, periodBefore_);

        // New transfer: 600 tokens.
        bytes memory callData2_ = _encodeERC20Transfer(bob, 600);
        bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);

        (uint256 availableAfterTransfer_,,) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
        assertEq(availableAfterTransfer_, erc20PeriodAmount - 600);
    }

    /// @notice Reverts if an invalid call type mode is used.
    function test_RevertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        multiTokenEnforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    /// @notice Reverts if an invalid execution mode is used.
    function test_RevertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        multiTokenEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Native Token Tests //////////////////////

    /// @notice Reverts if the native token config has a zero start date.
    function test_InvalidZeroStartDateNative() public {
        bytes memory terms_ = abi.encodePacked(address(0), nativePeriodAmount, nativePeriodDuration, uint256(0));
        bytes memory execData_ = _encodeNativeTransfer(bob, 0.5 ether);
        vm.expectRevert("MultiTokenPeriodEnforcer:invalid-zero-start-date");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the native token config has a zero period duration.
    function test_InvalidZeroPeriodDurationNative() public {
        bytes memory terms_ = abi.encodePacked(address(0), nativePeriodAmount, uint256(0), nativeStartDate);
        bytes memory execData_ = _encodeNativeTransfer(bob, 0.5 ether);
        vm.expectRevert("MultiTokenPeriodEnforcer:invalid-zero-period-duration");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the native token config has a zero period amount.
    function test_InvalidZeroPeriodAmountNative() public {
        bytes memory terms_ = abi.encodePacked(address(0), uint256(0), nativePeriodDuration, nativeStartDate);
        bytes memory execData_ = _encodeNativeTransfer(bob, 0.5 ether);
        vm.expectRevert("MultiTokenPeriodEnforcer:invalid-zero-period-amount");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if a native transfer is attempted before the start date.
    function test_TransferNotStartedNative() public {
        uint256 futureStart_ = block.timestamp + 100;
        bytes memory terms_ = abi.encodePacked(address(0), nativePeriodAmount, nativePeriodDuration, futureStart_);
        bytes memory execData_ = _encodeNativeTransfer(bob, 0.5 ether);
        vm.expectRevert("MultiTokenPeriodEnforcer:transfer-not-started");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if a native transfer exceeds the available allowance.
    function test_TransferAmountExceededNative() public {
        bytes memory terms_ = abi.encodePacked(address(0), nativePeriodAmount, nativePeriodDuration, nativeStartDate);
        // First transfer: 0.8 ether.
        bytes memory execData1_ = _encodeNativeTransfer(bob, 0.8 ether);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        // Second transfer: attempt 0.3 ether (exceeds remaining allowance).
        bytes memory execData2_ = _encodeNativeTransfer(bob, 0.3 ether);
        vm.expectRevert("MultiTokenPeriodEnforcer:transfer-amount-exceeded");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Tests a successful native transfer and verifies that the TransferredInPeriod event is emitted.
    function test_SuccessfulTransferAndEventNative() public {
        uint256 transferAmount_ = 0.5 ether;
        bytes memory terms_ = abi.encodePacked(address(0), nativePeriodAmount, nativePeriodDuration, nativeStartDate);
        bytes memory execData_ = _encodeNativeTransfer(bob, transferAmount_);

        vm.expectEmit(true, true, true, true);
        emit MultiTokenPeriodEnforcer.TransferredInPeriod(
            address(this),
            redeemer,
            dummyDelegationHash,
            address(0),
            nativePeriodAmount,
            nativePeriodDuration,
            nativeStartDate,
            transferAmount_,
            block.timestamp
        );
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
        (uint256 available_,,) = multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(0));
        assertEq(available_, nativePeriodAmount - transferAmount_);
    }

    /// @notice Tests multiple native transfers within the same period.
    function test_MultipleTransfersInSamePeriodNative() public {
        bytes memory terms_ = abi.encodePacked(address(0), nativePeriodAmount, nativePeriodDuration, nativeStartDate);
        // First transfer: 0.4 ether.
        bytes memory execData1_ = _encodeNativeTransfer(bob, 0.4 ether);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        // Second transfer: 0.3 ether.
        bytes memory execData2_ = _encodeNativeTransfer(bob, 0.3 ether);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);

        (uint256 available_,,) = multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(0));
        assertEq(available_, nativePeriodAmount - 0.7 ether);

        // Third transfer: attempt 0.4 ether (should revert).
        bytes memory execData3_ = _encodeNativeTransfer(bob, 0.4 ether);
        vm.expectRevert("MultiTokenPeriodEnforcer:transfer-amount-exceeded");
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData3_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Tests that the native allowance resets when a new period begins.
    function test_NewPeriodResetsAllowanceNative() public {
        bytes memory terms_ = abi.encodePacked(address(0), nativePeriodAmount, nativePeriodDuration, nativeStartDate);
        // First transfer: 0.8 ether.
        bytes memory execData1_ = _encodeNativeTransfer(bob, 0.8 ether);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        (uint256 availableBefore_,, uint256 periodBefore_) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(0));
        assertEq(availableBefore_, nativePeriodAmount - 0.8 ether);

        vm.warp(block.timestamp + nativePeriodDuration + 1);

        (uint256 availableAfter_, bool isNewPeriod_, uint256 periodAfter_) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(0));
        assertEq(availableAfter_, nativePeriodAmount);
        assertTrue(isNewPeriod_);
        assertGt(periodAfter_, periodBefore_);

        // New transfer: 0.3 ether.
        bytes memory execData2_ = _encodeNativeTransfer(bob, 0.3 ether);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);

        (uint256 availableAfterTransfer_,,) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(0));
        assertEq(availableAfterTransfer_, nativePeriodAmount - 0.3 ether);
    }

    ////////////////////// Additional Tests //////////////////////

    /// @notice Ensures that once an allowance is initialized, subsequent calls with different _terms do not override the stored
    /// state.
    function test_TermsMismatchAfterInitialization() public {
        // Initialize allowance using the initial ERC20 configuration.
        bytes memory initialTerms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        uint256 initialTransfer_ = 200;
        bytes memory callData1_ = _encodeERC20Transfer(bob, initialTransfer_);
        bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);
        multiTokenEnforcer.beforeHook(initialTerms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        // Prepare new terms with different parameters.
        uint256 newPeriodAmount_ = erc20PeriodAmount + 500;
        uint256 newPeriodDuration_ = erc20PeriodDuration + 100;
        uint256 newStartDate_ = erc20StartDate + 50;
        bytes memory newTerms_ = abi.encodePacked(address(basicERC20), newPeriodAmount_, newPeriodDuration_, newStartDate_);
        uint256 secondTransfer_ = 300;
        bytes memory callData2_ = _encodeERC20Transfer(bob, secondTransfer_);
        bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);
        multiTokenEnforcer.beforeHook(newTerms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);

        // The stored allowance should still reflect the initial terms.
        (uint256 available_,,) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), initialTerms_, address(basicERC20));
        assertEq(available_, erc20PeriodAmount - (initialTransfer_ + secondTransfer_), "Stored state overridden by new terms");
    }

    /// @notice Tests that allowances are isolated per delegation manager (msg.sender).
    function test_AllowanceIsolationByDelegationManager() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        uint256 transferAmount_ = 400;
        bytes memory callData_ = _encodeERC20Transfer(bob, transferAmount_);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        // Call as the default delegation manager.
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
        // Now simulate a different delegation manager.
        address otherManager_ = address(0x456);
        vm.prank(otherManager_);
        (uint256 availableOther_,,) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, otherManager_, terms_, address(basicERC20));
        assertEq(availableOther_, erc20PeriodAmount, "Allowance not isolated by delegation manager");
    }

    /// @notice Tests boundary conditions in period calculation at exactly the start date and at a period boundary.
    function test_BoundaryPeriodCalculation() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);

        // Warp to exactly the start date.
        vm.warp(erc20StartDate);
        (uint256 availableAtStart_, bool isNewAtStart_, uint256 currentPeriodAtStart_) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
        assertEq(availableAtStart_, erc20PeriodAmount, "Available not full at startDate");
        assertTrue(isNewAtStart_, "isNewPeriod not true at startDate");
        assertEq(currentPeriodAtStart_, 1, "Current period should be 1 at startDate");

        // Perform a transfer to initialize the allowance.
        uint256 transferAmount_ = 100;
        bytes memory callData_ = _encodeERC20Transfer(bob, transferAmount_);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);

        // Warp to exactly the end of the period.
        uint256 boundaryTime_ = erc20StartDate + erc20PeriodDuration;
        vm.warp(boundaryTime_);
        (uint256 availableAtBoundary_, bool isNewAtBoundary_, uint256 currentPeriodAtBoundary_) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
        // Expect a reset: full allowance available and period index incremented.
        assertEq(availableAtBoundary_, erc20PeriodAmount, "Available should reset at period boundary");
        assertTrue(isNewAtBoundary_, "isNewPeriod should be true at boundary");
        assertEq(currentPeriodAtBoundary_, 2, "Current period should be 2 at boundary");
    }

    /// @notice Tests native transfer behavior when non-empty callData is provided.
    /// @dev Although the spec expects empty callData for native transfers, the current implementation does not enforce it.
    function test_NativeTransferWithNonEmptyCallData() public {
        bytes memory terms_ = abi.encodePacked(address(0), nativePeriodAmount, nativePeriodDuration, nativeStartDate);
        // Prepare execution data for a native transfer with non-empty callData.
        bytes memory nonEmptyCallData_ = "non-empty";
        bytes memory execData_ = abi.encodePacked(bob, nativePeriodAmount / 2, nonEmptyCallData_);
        // This should pass and reduce the available allowance.
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
        (uint256 available_,,) = multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(0));
        assertEq(
            available_, nativePeriodAmount - (nativePeriodAmount / 2), "Available not reduced correctly with non-empty callData"
        );
    }

    /// @notice Tests that multiple beforeHook calls within the same period correctly accumulate the transferred amount.
    function test_MultipleBeforeHookCallsMaintainsState() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        // First call: transfer 300 tokens.
        uint256 firstTransfer_ = 300;
        bytes memory callData1_ = _encodeERC20Transfer(bob, firstTransfer_);
        bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        // Second call: transfer 200 tokens.
        uint256 secondTransfer_ = 200;
        bytes memory callData2_ = _encodeERC20Transfer(bob, secondTransfer_);
        bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);

        // Total transferred should be 500 tokens.
        (uint256 available_,,) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
        assertEq(
            available_, erc20PeriodAmount - (firstTransfer_ + secondTransfer_), "Multiple calls did not accumulate state properly"
        );
    }

    ////////////////////// Integration Tests //////////////////////

    /// @notice Integration: Successfully transfers both ERC20 and native tokens under the same delegation.
    function test_IntegrationCombinedTokens() public {
        // Encode terms for two token configurations (ERC20 then native).
        bytes memory terms_ = abi.encodePacked(
            address(basicERC20),
            erc20PeriodAmount,
            erc20PeriodDuration,
            erc20StartDate,
            address(0),
            nativePeriodAmount,
            nativePeriodDuration,
            nativeStartDate
        );
        // Build execution data for an ERC20 transfer.
        uint256 erc20TransferAmount_ = 400;
        bytes memory erc20CallData_ = _encodeERC20Transfer(bob, erc20TransferAmount_);
        bytes memory erc20ExecData_ = _encodeSingleExecution(address(basicERC20), 0, erc20CallData_);
        // Build execution data for a native transfer.
        uint256 nativeTransferAmount_ = 0.5 ether;
        bytes memory nativeExecData_ = _encodeNativeTransfer(bob, nativeTransferAmount_);

        // Perform ERC20 transfer.
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, erc20ExecData_, dummyDelegationHash, address(0), redeemer);
        // Perform native transfer.
        multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, nativeExecData_, dummyDelegationHash, address(0), redeemer);

        // Verify available amounts for each token.
        (uint256 availableERC20_,,) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
        (uint256 availableNative_,,) = multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(0));
        assertEq(availableERC20_, erc20PeriodAmount - erc20TransferAmount_, "ERC20 allowance updated correctly");
        assertEq(availableNative_, nativePeriodAmount - nativeTransferAmount_, "Native allowance updated correctly");
    }

    /// @notice Integration: Confirms that different delegation hashes are tracked independently.
    function test_IntegrationMultipleDelegations() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        // Build two delegations with different salts.
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(multiTokenEnforcer), terms: terms_ });
        Delegation memory delegation1_ =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex"" });
        Delegation memory delegation2_ =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 1, signature: hex"" });
        delegation1_ = signDelegation(users.alice, delegation1_);
        delegation2_ = signDelegation(users.alice, delegation2_);
        bytes32 delHash1_ = EncoderLib._getDelegationHash(delegation1_);
        bytes32 delHash2_ = EncoderLib._getDelegationHash(delegation2_);

        // For delegation1_, transfer 600 tokens.
        bytes memory callData1_ = _encodeERC20Transfer(bob, 600);

        // Simulate a native transfer user operation.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation1_), Execution({ target: address(basicERC20), value: 0, callData: callData1_ })
        );

        // For delegation2_, transfer 900 tokens.
        bytes memory callData2_ = _encodeERC20Transfer(bob, 900);
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation2_), Execution({ target: address(basicERC20), value: 0, callData: callData2_ })
        );

        (uint256 available1_,,) =
            multiTokenEnforcer.getAvailableAmount(delHash1_, address(delegationManager), terms_, address(basicERC20));
        (uint256 available2_,,) =
            multiTokenEnforcer.getAvailableAmount(delHash2_, address(delegationManager), terms_, address(basicERC20));
        assertEq(available1_, erc20PeriodAmount - 600, "Delegation1 ERC20 allowance not updated correctly");
        assertEq(available2_, erc20PeriodAmount - 900, "Delegation2 ERC20 allowance not updated correctly");
    }

    /// @notice Simulation: Tests getAvailableAmount for ERC20 before and after initialization.
    function test_GetAvailableAmountSimulationBeforeInitializationErc20() public {
        uint256 futureStart_ = block.timestamp + 100;
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, futureStart_);
        (uint256 availableBefore_, bool isNewPeriodBefore_, uint256 currentPeriodBefore_) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
        assertEq(availableBefore_, 0, "Available should be 0 before start date");
        assertEq(isNewPeriodBefore_, false, "isNewPeriod false before start");
        assertEq(currentPeriodBefore_, 0, "Current period 0 before start");

        vm.warp(futureStart_ + 1);

        (uint256 availableAfter_, bool isNewPeriodAfter_, uint256 currentPeriodAfter_) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
        assertEq(availableAfter_, erc20PeriodAmount, "Available equals periodAmount after start");
        assertTrue(isNewPeriodAfter_, "isNewPeriod true after start");
        uint256 expectedPeriod_ = (block.timestamp - futureStart_) / erc20PeriodDuration + 1;
        assertEq(currentPeriodAfter_, expectedPeriod_, "Current period computed correctly after start");
    }

    /// @notice Simulation: Tests getAvailableAmount for native tokens before and after initialization.
    function test_GetAvailableAmountSimulationBeforeInitializationNative() public {
        uint256 futureStart_ = block.timestamp + 100;
        bytes memory terms_ = abi.encodePacked(address(0), nativePeriodAmount, nativePeriodDuration, futureStart_);
        (uint256 availableBefore_, bool isNewPeriodBefore_, uint256 currentPeriodBefore_) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(0));
        assertEq(availableBefore_, 0, "Available should be 0 before start");
        assertEq(isNewPeriodBefore_, false, "isNewPeriod false before start");
        assertEq(currentPeriodBefore_, 0, "Current period 0 before start");

        vm.warp(futureStart_ + 1);

        (uint256 availableAfter_, bool isNewPeriodAfter_, uint256 currentPeriodAfter_) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(0));
        assertEq(availableAfter_, nativePeriodAmount, "Available equals periodAmount after start");
        assertTrue(isNewPeriodAfter_, "isNewPeriod true after start");
        uint256 expectedPeriod_ = (block.timestamp - futureStart_) / nativePeriodDuration + 1;
        assertEq(currentPeriodAfter_, expectedPeriod_, "Current period computed correctly after start");
    }

    /// @notice Ensures getAllTermsInfo reverts if _terms length is not a multiple of 116 bytes.
    function test_GetAllTermsInfoInvalidTermsLength() public {
        bytes memory invalidTerms_ = new bytes(115); // Not a multiple of 116
        vm.expectRevert("MultiTokenPeriodEnforcer:invalid-terms-length");
        multiTokenEnforcer.getAllTermsInfo(invalidTerms_);
    }

    /// @notice Checks that getAllTermsInfo correctly decodes a single configuration.
    function test_GetAllTermsInfoSingleConfiguration() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);
        (address[] memory tokens_, uint256[] memory periodAmounts_, uint256[] memory periodDurations_, uint256[] memory startDates_)
        = multiTokenEnforcer.getAllTermsInfo(terms_);
        assertEq(tokens_.length, 1, "Expected one configuration");
        assertEq(tokens_[0], address(basicERC20), "Token address mismatch");
        assertEq(periodAmounts_[0], erc20PeriodAmount, "Period amount mismatch");
        assertEq(periodDurations_[0], erc20PeriodDuration, "Period duration mismatch");
        assertEq(startDates_[0], erc20StartDate, "Start date mismatch");
    }

    /// @notice Ensures getAllTermsInfo correctly decodes multiple configurations.
    function test_GetAllTermsInfoMultipleConfigurations() public {
        // Encode two configurations: one for basicERC20 and one for native token (address(0)).
        bytes memory terms_ = abi.encodePacked(
            address(basicERC20),
            erc20PeriodAmount,
            erc20PeriodDuration,
            erc20StartDate,
            address(0),
            nativePeriodAmount,
            nativePeriodDuration,
            nativeStartDate
        );
        (address[] memory tokens_, uint256[] memory periodAmounts_, uint256[] memory periodDurations_, uint256[] memory startDates_)
        = multiTokenEnforcer.getAllTermsInfo(terms_);
        assertEq(tokens_.length, 2, "Expected two configurations");

        // First configuration: ERC20 token.
        assertEq(tokens_[0], address(basicERC20), "First config: token address mismatch");
        assertEq(periodAmounts_[0], erc20PeriodAmount, "First config: period amount mismatch");
        assertEq(periodDurations_[0], erc20PeriodDuration, "First config: period duration mismatch");
        assertEq(startDates_[0], erc20StartDate, "First config: start date mismatch");

        // Second configuration: Native token.
        assertEq(tokens_[1], address(0), "Second config: token address mismatch");
        assertEq(periodAmounts_[1], nativePeriodAmount, "Second config: period amount mismatch");
        assertEq(periodDurations_[1], nativePeriodDuration, "Second config: period duration mismatch");
        assertEq(startDates_[1], nativeStartDate, "Second config: start date mismatch");
    }

    /// @notice Validates that getAllTermsInfo correctly decodes a mixed set of configurations.
    function test_GetAllTermsInfoMixedTokens() public {
        // Create three configurations: ERC20, Native, and a second ERC20 with different parameters.
        uint256 secondERC20Amount_ = erc20PeriodAmount + 100;
        uint256 secondERC20Duration_ = erc20PeriodDuration + 100;
        uint256 secondERC20Start_ = erc20StartDate + 50;
        bytes memory terms_ = abi.encodePacked(
            address(basicERC20),
            erc20PeriodAmount,
            erc20PeriodDuration,
            erc20StartDate,
            address(0),
            nativePeriodAmount,
            nativePeriodDuration,
            nativeStartDate,
            address(basicERC20),
            secondERC20Amount_,
            secondERC20Duration_,
            secondERC20Start_
        );
        (address[] memory tokens_, uint256[] memory periodAmounts_, uint256[] memory periodDurations_, uint256[] memory startDates_)
        = multiTokenEnforcer.getAllTermsInfo(terms_);
        assertEq(tokens_.length, 3, "Expected three configurations");

        // First configuration: Original ERC20.
        assertEq(tokens_[0], address(basicERC20), "Config0: token mismatch");
        assertEq(periodAmounts_[0], erc20PeriodAmount, "Config0: period amount mismatch");
        assertEq(periodDurations_[0], erc20PeriodDuration, "Config0: period duration mismatch");
        assertEq(startDates_[0], erc20StartDate, "Config0: start date mismatch");

        // Second configuration: Native token.
        assertEq(tokens_[1], address(0), "Config1: token mismatch");
        assertEq(periodAmounts_[1], nativePeriodAmount, "Config1: period amount mismatch");
        assertEq(periodDurations_[1], nativePeriodDuration, "Config1: period duration mismatch");
        assertEq(startDates_[1], nativeStartDate, "Config1: start date mismatch");

        // Third configuration: Second ERC20 config.
        assertEq(tokens_[2], address(basicERC20), "Config2: token mismatch");
        assertEq(periodAmounts_[2], secondERC20Amount_, "Config2: period amount mismatch");
        assertEq(periodDurations_[2], secondERC20Duration_, "Config2: period duration mismatch");
        assertEq(startDates_[2], secondERC20Start_, "Config2: start date mismatch");
    }

    /// @notice Tests multiple tokens (three configurations) with different settings.
    ///         It deploys a second ERC20 token (Token B) and sets up:
    ///         - Token A: an ERC20 token (basicERC20) with its configuration.
    ///         - Token B: an ERC20 token (basicERC20B) with a different configuration.
    ///         - Token C: a native token (address(0)) with its configuration.
    ///         All start dates are set in the past so that the beforeHook calls succeed.
    ///         Then, it verifies that getAvailableAmount returns the expected available amounts.
    function test_MultipleTokensBeforeHook() public {
        vm.warp(10000);

        // Define configuration for Token A (ERC20 - basicERC20)
        uint256 periodAmountA_ = 1000;
        uint256 periodDurationA_ = 100; // 100 seconds

        // Deploy a second ERC20 token for Token B.
        uint256 periodAmountB_ = 500;
        uint256 periodDurationB_ = 50; // 50 seconds

        // Define configuration for Token C (Native: address(0))
        uint256 periodAmountC_ = 1 ether;
        uint256 periodDurationC_ = 100; // 100 seconds

        // Build the _terms blob: concatenation of configurations for Token A, Token B, and Token C.
        bytes memory terms_ = abi.encodePacked(
            address(basicERC20),
            periodAmountA_,
            periodDurationA_,
            block.timestamp - 100, // Token A start date,
            address(basicERC20B),
            periodAmountB_,
            periodDurationB_,
            block.timestamp - 50, // Token B start date
            address(0),
            periodAmountC_,
            periodDurationC_,
            block.timestamp - 10 // Token C (native) start date
        );

        {
            // Call beforeHook for Token A (ERC20).
            bytes memory callDataA_ = _encodeERC20Transfer(bob, 300);
            bytes memory execDataA_ = _encodeSingleExecution(address(basicERC20), 0, callDataA_);
            multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execDataA_, dummyDelegationHash, address(0), redeemer);
        }

        {
            // Call beforeHook for Token B (ERC20).
            bytes memory callDataB_ = _encodeERC20Transfer(bob, 200);
            bytes memory execDataB_ = _encodeSingleExecution(address(basicERC20B), 0, callDataB_);
            multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execDataB_, dummyDelegationHash, address(0), redeemer);
        }
        {
            // Call beforeHook for Token C (Native).
            bytes memory execDataC_ = _encodeNativeTransfer(bob, 0.2 ether);
            multiTokenEnforcer.beforeHook(terms_, "", singleDefaultMode, execDataC_, dummyDelegationHash, address(0), redeemer);
        }
        {
            // Verify available amounts for each token.
            (uint256 availableA_,,) =
                multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));
            (uint256 availableB_,,) =
                multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20B));
            (uint256 availableC_,,) = multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(0));

            assertEq(availableA_, periodAmountA_ - 300, "Token A available amount incorrect");
            assertEq(availableB_, periodAmountB_ - 200, "Token B available amount incorrect");
            assertEq(availableC_, periodAmountC_ - 0.2 ether, "Token C available amount incorrect");
        }
    }

    /// @notice Tests getAvailableAmount for an ERC20 token when no beforeHook has been called,
    ///         so that the allowance is simulated from _terms.
    function test_GetAvailableAmountWithoutBeforeHookErc20() public {
        // Build an ERC20 configuration _terms blob.
        bytes memory terms_ = abi.encodePacked(address(basicERC20), erc20PeriodAmount, erc20PeriodDuration, erc20StartDate);

        // Call getAvailableAmount without any prior beforeHook call.
        (uint256 available_, bool isNewPeriod_, uint256 currentPeriod_) =
            multiTokenEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_, address(basicERC20));

        // Since no transfer has occurred, available amount should equal the periodAmount.
        assertEq(available_, erc20PeriodAmount, "Available amount should equal periodAmount when uninitialized");
        // If the block.timestamp is >= erc20StartDate, isNewPeriod_ should be true and currentPeriod_ computed properly.
        if (block.timestamp >= erc20StartDate) {
            assertTrue(isNewPeriod_, "isNewPeriod should be true after startDate");
            assertGt(currentPeriod_, 0, "Current period should be > 0 after startDate");
        } else {
            // If before the start date, available should be 0.
            assertEq(available_, 0, "Available should be 0 before start date");
            assertFalse(isNewPeriod_, "isNewPeriod should be false before start date");
            assertEq(currentPeriod_, 0, "Current period should be 0 before start date");
        }
    }

    ////////////////////// Helper Functions //////////////////////
    function _encodeERC20Transfer(address _to, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.transfer.selector, _to, _amount);
    }

    function _encodeSingleExecution(address _target, uint256 _value, bytes memory _callData) internal pure returns (bytes memory) {
        return abi.encodePacked(_target, _value, _callData);
    }

    function _encodeNativeTransfer(address _target, uint256 _value) internal pure returns (bytes memory) {
        // target (20 bytes) + value (32 bytes) + empty callData.
        return abi.encodePacked(_target, _value, "");
    }

    function toDelegationArray(Delegation memory _delegation) internal pure returns (Delegation[] memory) {
        Delegation[] memory arr_ = new Delegation[](1);
        arr_[0] = _delegation;
        return arr_;
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(multiTokenEnforcer));
    }
}
