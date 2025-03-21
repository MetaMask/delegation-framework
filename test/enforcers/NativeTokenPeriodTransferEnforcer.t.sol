// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Caveat, Delegation, Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { NativeTokenPeriodTransferEnforcer } from "../../src/enforcers/NativeTokenPeriodTransferEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

contract NativeTokenPeriodTransferEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    NativeTokenPeriodTransferEnforcer public nativeEnforcer;
    address public delegator;
    address public redeemer;
    address public beneficiary; // target of the ETH transfer

    // We'll use a dummy delegation hash for simulation.
    bytes32 public dummyDelegationHash = keccak256("test-delegation");

    // Parameters for the allowance (in wei).
    uint256 public periodAmount = 1 ether;
    uint256 public periodDuration = 1 days; // 86400 seconds
    uint256 public startDate;

    ////////////////////// Set up //////////////////////
    function setUp() public override {
        super.setUp();
        nativeEnforcer = new NativeTokenPeriodTransferEnforcer();
        vm.label(address(nativeEnforcer), "Native Token Period Allowance Enforcer");

        // For testing, we use these addresses.
        delegator = address(users.alice.deleGator);

        redeemer = address(users.bob.deleGator);
        beneficiary = address(users.bob.deleGator);

        // Set the start date to the current time.
        startDate = block.timestamp;

        // Give the delegator an initial ETH balance.
        vm.deal(delegator, 100 ether);
    }

    //////////////////// Error / Revert Tests //////////////////////

    /// @notice Ensures it reverts if _terms length is not exactly 96 bytes.
    function testInvalidTermsLength() public {
        bytes memory invalidTerms_ = new bytes(95); // one byte short
        vm.expectRevert("NativeTokenPeriodTransferEnforcer:invalid-terms-length");
        nativeEnforcer.getTermsInfo(invalidTerms_);
    }

    /// @notice Reverts if the start date is zero.
    function testInvalidZeroStartDate() public {
        bytes memory terms_ = abi.encodePacked(periodAmount, periodDuration, uint256(0));
        // Build execution call data: encode native transfer with beneficiary as target and 0.5 ether value.
        bytes memory execData_ = _encodeNativeTransfer(beneficiary, 0.5 ether);
        vm.expectRevert("NativeTokenPeriodTransferEnforcer:invalid-zero-start-date");
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the period duration is zero.
    function testInvalidZeroPeriodDuration() public {
        bytes memory terms_ = abi.encodePacked(periodAmount, uint256(0), startDate);
        bytes memory execData_ = _encodeNativeTransfer(beneficiary, 0.5 ether);
        vm.expectRevert("NativeTokenPeriodTransferEnforcer:invalid-zero-period-duration");
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the period amount is zero.
    function testInvalidZeroPeriodAmount() public {
        bytes memory terms_ = abi.encodePacked(uint256(0), periodDuration, startDate);
        bytes memory execData_ = _encodeNativeTransfer(beneficiary, 0.5 ether);
        vm.expectRevert("NativeTokenPeriodTransferEnforcer:invalid-zero-period-amount");
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the transfer period has not started yet.
    function testTransferNotStarted() public {
        uint256 futureStart_ = block.timestamp + 100;
        bytes memory terms_ = abi.encodePacked(periodAmount, periodDuration, futureStart_);
        bytes memory execData_ = _encodeNativeTransfer(beneficiary, 0.5 ether);
        vm.expectRevert("NativeTokenPeriodTransferEnforcer:transfer-not-started");
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if a transfer exceeds the available ETH allowance.
    function testTransferAmount_Exceeded() public {
        bytes memory terms_ = abi.encodePacked(periodAmount, periodDuration, startDate);
        // First transfer: 0.8 ether.
        bytes memory execData1_ = _encodeNativeTransfer(beneficiary, 0.8 ether);
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        // Second transfer: attempt to transfer 0.3 ether, which exceeds remaining 0.2 ether.
        bytes memory execData2_ = _encodeNativeTransfer(beneficiary, 0.3 ether);
        vm.expectRevert("NativeTokenPeriodTransferEnforcer:transfer-amount-exceeded");
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);
    }

    ////////////////////// Successful and Multiple Transfers //////////////////////

    /// @notice Tests a successful native ETH transfer and verifies that the TransferredInPeriod event is emitted.
    function testSuccessfulTransferAndEvent() public {
        uint256 transferAmount_ = 0.5 ether;
        bytes memory terms_ = abi.encodePacked(periodAmount, periodDuration, startDate);
        bytes memory execData_ = _encodeNativeTransfer(beneficiary, transferAmount_);

        vm.expectEmit(true, true, true, true);
        emit NativeTokenPeriodTransferEnforcer.TransferredInPeriod(
            address(this), redeemer, dummyDelegationHash, periodAmount, periodDuration, startDate, transferAmount_, block.timestamp
        );

        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);

        (uint256 availableAfter_,,) = nativeEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(availableAfter_, periodAmount - transferAmount_, "Available reduced by transfer");
    }

    /// @notice Tests multiple native ETH transfers within the same period and confirms that an over-transfer reverts.
    function testMultipleTransfersInSamePeriod() public {
        bytes memory terms_ = abi.encodePacked(periodAmount, periodDuration, startDate);
        // First transfer: 0.4 ether.
        bytes memory execData1_ = _encodeNativeTransfer(beneficiary, 0.4 ether);
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        // Second transfer: 0.3 ether.
        bytes memory execData2_ = _encodeNativeTransfer(beneficiary, 0.3 ether);
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);

        (uint256 available_,,) = nativeEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        // Expected remaining: 1 ether - 0.4 ether - 0.3 ether = 0.3 ether.
        assertEq(available_, 0.3 ether, "Remaining allowance should be 0.3 ETH");

        // Third transfer: attempt to transfer 0.4 ether, which should revert.
        bytes memory execData3_ = _encodeNativeTransfer(beneficiary, 0.4 ether);
        vm.expectRevert("NativeTokenPeriodTransferEnforcer:transfer-amount-exceeded");
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData3_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Tests that the allowance resets when a new period begins.
    function testNewPeriodResetsAllowance() public {
        bytes memory terms_ = abi.encodePacked(periodAmount, periodDuration, startDate);
        // First transfer: 0.8 ether.
        bytes memory execData1_ = _encodeNativeTransfer(beneficiary, 0.8 ether);
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        (uint256 availableBefore_,, uint256 periodBefore_) =
            nativeEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(availableBefore_, periodAmount - 0.8 ether, "Allowance reduced after transfer");

        // Warp time to next period.
        vm.warp(startDate + periodDuration + 1);
        (uint256 availableAfter_, bool isPeriodNew_, uint256 periodAfter_) =
            nativeEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(availableAfter_, periodAmount, "Allowance resets in new period");
        assertTrue(isPeriodNew_, "isNewPeriod flag true");
        assertGt(periodAfter_, periodBefore_, "Period index increased");

        // Transfer in new period: 0.3 ether.
        bytes memory execData2_ = _encodeNativeTransfer(beneficiary, 0.3 ether);
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);
        (uint256 availableAfterTransfer_,,) = nativeEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(availableAfterTransfer_, periodAmount - 0.3 ether, "New period allowance reduced by new transfer");
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        nativeEnforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        nativeEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration Tests //////////////////////

    /// @notice Integration: Simulates a full native ETH transfer via delegation and verifies allowance update.
    function test_integration_SuccessfulTransfer() public {
        uint256 transferAmount_ = 0.5 ether;
        bytes memory terms_ = abi.encodePacked(periodAmount, periodDuration, startDate);

        // Build and sign the delegation.
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(nativeEnforcer), terms: terms_ });
        Delegation memory delegation = Delegation({
            delegate: beneficiary,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation = signDelegation(users.alice, delegation);
        bytes32 delHash = EncoderLib._getDelegationHash(delegation);

        // Simulate a native transfer user operation.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: beneficiary, value: transferAmount_, callData: hex"" })
        );

        (uint256 availableAfter_,,) = nativeEnforcer.getAvailableAmount(delHash, address(delegationManager), terms_);
        assertEq(availableAfter_, periodAmount - transferAmount_, "Available reduced by transfer");
    }

    /// @notice Integration: Fails if a native transfer exceeds the available ETH allowance.
    function test_integration_OverTransferFails() public {
        uint256 transferAmount_1 = 0.8 ether;
        uint256 transferAmount_2 = 0.3 ether; // total 1.1 ether, exceeds periodAmount = 1 ether
        bytes memory terms_ = abi.encodePacked(periodAmount, periodDuration, startDate);

        // Build and sign delegation.
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(nativeEnforcer), terms: terms_ });
        Delegation memory delegation = Delegation({
            delegate: beneficiary,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation = signDelegation(users.alice, delegation);
        bytes32 delHash = EncoderLib._getDelegationHash(delegation);

        // First transfer succeeds.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: beneficiary, value: transferAmount_1, callData: hex"" })
        );

        // Second transfer should revert.
        bytes memory execData2_ = _encodeNativeTransfer(beneficiary, transferAmount_2);
        vm.prank(address(delegationManager));
        vm.expectRevert("NativeTokenPeriodTransferEnforcer:transfer-amount-exceeded");
        nativeEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, delHash, address(0), redeemer);
    }

    /// @notice Integration: Verifies that the allowance resets in a new period for native transfers.
    function test_integration_NewPeriodReset() public {
        uint256 transferAmount_ = 0.8 ether;
        bytes memory terms_ = abi.encodePacked(periodAmount, periodDuration, startDate);

        // Build and sign delegation.
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(nativeEnforcer), terms: terms_ });
        Delegation memory delegation = Delegation({
            delegate: beneficiary,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation = signDelegation(users.alice, delegation);
        bytes32 delHash = EncoderLib._getDelegationHash(delegation);

        // First transfer in current period.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: beneficiary, value: transferAmount_, callData: hex"" })
        );

        (uint256 availableBefore_,, uint256 periodBefore_) =
            nativeEnforcer.getAvailableAmount(delHash, address(delegationManager), terms_);
        assertEq(availableBefore_, periodAmount - transferAmount_, "Allowance reduced after transfer");

        // Warp to next period.
        vm.warp(startDate + periodDuration + 1);
        (uint256 availableAfter_, bool isNew, uint256 periodAfter_) =
            nativeEnforcer.getAvailableAmount(delHash, address(delegationManager), terms_);
        assertEq(availableAfter_, periodAmount, "Allowance resets in new period");
        assertTrue(isNew, "isNewPeriod flag true");
        assertGt(periodAfter_, periodBefore_, "Period index increased");

        // Transfer in new period.
        uint256 newTransfer_ = 0.3 ether;
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: beneficiary, value: newTransfer_, callData: hex"" })
        );
        (uint256 availableAfterTransfer_,,) = nativeEnforcer.getAvailableAmount(delHash, address(delegationManager), terms_);
        assertEq(availableAfterTransfer_, periodAmount - newTransfer_, "New period allowance reduced by new transfer");
    }

    /// @notice Integration: Confirms that different delegation hashes are tracked independently.
    function test_integration_MultipleDelegations() public {
        bytes memory terms_ = abi.encodePacked(periodAmount, periodDuration, startDate);

        // Build two delegations with different salts (thus different hashes).
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(nativeEnforcer), terms: terms_ });
        Delegation memory delegation1_ = Delegation({
            delegate: beneficiary,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        Delegation memory delegation2_ = Delegation({
            delegate: beneficiary,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 1,
            signature: hex""
        });
        delegation1_ = signDelegation(users.alice, delegation1_);
        delegation2_ = signDelegation(users.alice, delegation2_);
        bytes32 computedDelHash1_ = EncoderLib._getDelegationHash(delegation1_);
        bytes32 computedDelHash2_ = EncoderLib._getDelegationHash(delegation2_);

        // For delegation1_, transfer 0.6 ether.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation1_), Execution({ target: beneficiary, value: 0.6 ether, callData: hex"" })
        );

        // For delegation2_, transfer 0.9 ether.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation2_), Execution({ target: beneficiary, value: 0.9 ether, callData: hex"" })
        );

        (uint256 available1_,,) = nativeEnforcer.getAvailableAmount(computedDelHash1_, address(delegationManager), terms_);
        (uint256 available2_,,) = nativeEnforcer.getAvailableAmount(computedDelHash2_, address(delegationManager), terms_);
        assertEq(available1_, periodAmount - 0.6 ether, "Delegation1 allowance updated correctly");
        assertEq(available2_, periodAmount - 0.9 ether, "Delegation2 allowance updated correctly");
    }

    ////////////////////// New Simulation Tests //////////////////////

    /// @notice Tests simulation of getAvailableAmount when no allowance is stored.
    ///         Initially, if the start date is in the future, available amount is zero;
    ///         after warping time past the start, available equals periodAmount.
    function test_getAvailableAmountSimulationBeforeInitialization() public {
        uint256 futureStart_ = block.timestamp + 100;
        bytes memory terms_ = abi.encodePacked(periodAmount, periodDuration, futureStart_);

        // Before the start date, available should be 0.
        (uint256 availableBefore_, bool isNewPeriodBefore, uint256 currentPeriodBefore) =
            nativeEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(availableBefore_, 0, "Available should be 0 before start");
        assertEq(isNewPeriodBefore, false, "isNewPeriod false before start");
        assertEq(currentPeriodBefore, 0, "Period index 0 before start");

        // Warp time to after the start date.
        vm.warp(futureStart_ + 1);

        // Now, with no transfer made, available amount should equal periodAmount.
        (uint256 availableAfter_, bool isNewPeriodAfter_, uint256 currentPeriodAfter_) =
            nativeEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(availableAfter_, periodAmount, "Available equals periodAmount after start");

        // Since no transfer was made, lastTransferPeriod remains 0 so currentPeriod should be > 0 => isNewPeriodAfter_ true.
        assertTrue(isNewPeriodAfter_, "isNewPeriod should be true after start");

        // Optionally, verify the current period calculation.
        uint256 expectedPeriod_ = (block.timestamp - futureStart_) / periodDuration + 1;
        assertEq(currentPeriodAfter_, expectedPeriod_, "Current period computed incorrectly after start date");
    }

    ////////////////////// Helper Functions //////////////////////

    /// @dev Constructs the execution call data for a native ETH transfer.
    ///      It encodes the target and value; callData is expected to be empty.
    function _encodeNativeTransfer(address _target, uint256 _value) internal pure returns (bytes memory) {
        return abi.encodePacked(_target, _value, ""); // target (20 bytes) + value (32 bytes) + empty callData
    }

    /// @dev Helper to convert a single delegation to an array.
    function toDelegationArray(Delegation memory _delegation) internal pure returns (Delegation[] memory) {
        Delegation[] memory arr = new Delegation[](1);
        arr[0] = _delegation;
        return arr;
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(nativeEnforcer));
    }
}
