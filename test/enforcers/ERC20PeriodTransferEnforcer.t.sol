// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Caveat, Delegation, Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC20PeriodTransferEnforcer } from "../../src/enforcers/ERC20PeriodTransferEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

contract ERC20PeriodTransferEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC20PeriodTransferEnforcer public erc20PeriodTransferEnforcer;
    BasicERC20 public basicERC20;
    address public alice;
    address public bob;

    bytes32 dummyDelegationHash = keccak256("test-delegation");
    address redeemer = address(0x123);

    // Parameters for the periodic allowance.
    uint256 periodAmount = 1000;
    uint256 periodDuration = 1 days; // 86400 seconds
    uint256 startDate;

    ////////////////////// Set up //////////////////////
    function setUp() public override {
        super.setUp();
        erc20PeriodTransferEnforcer = new ERC20PeriodTransferEnforcer();
        vm.label(address(erc20PeriodTransferEnforcer), "ERC20 Periodic Claim Enforcer");

        alice = address(users.alice.deleGator);
        bob = address(users.bob.deleGator);

        basicERC20 = new BasicERC20(alice, "TestToken", "TestToken", 100 ether);

        startDate = block.timestamp; // set startDate to current block time
    }

    //////////////////// Error / Revert Tests //////////////////////

    /// @notice Ensures it reverts if _terms length is not exactly 116 bytes.
    function testInvalidTermsLength() public {
        bytes memory invalidTerms_ = new bytes(115); // one byte short
        vm.expectRevert("ERC20PeriodTransferEnforcer:invalid-terms-length");
        erc20PeriodTransferEnforcer.getTermsInfo(invalidTerms_);
    }

    /// @notice Reverts if the start date is zero.
    function testInvalidZeroStartDate() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, uint256(0));
        bytes memory callData_ = _encodeERC20Transfer(bob, 100);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        vm.expectRevert("ERC20PeriodTransferEnforcer:invalid-zero-start-date");
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the period duration is zero.
    function testInvalidZeroPeriodDuration() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, uint256(0), startDate);
        bytes memory callData_ = _encodeERC20Transfer(bob, 100);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        vm.expectRevert("ERC20PeriodTransferEnforcer:invalid-zero-period-duration");
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the period amount is zero.
    function testInvalidZeroPeriodAmount() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), uint256(0), periodDuration, startDate);
        bytes memory callData_ = _encodeERC20Transfer(bob, 100);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        vm.expectRevert("ERC20PeriodTransferEnforcer:invalid-zero-period-amount");
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the transfer period has not started yet.
    function testTransferNotStarted() public {
        uint256 futureStart_ = block.timestamp + 100;
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, futureStart_);
        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        vm.expectRevert("ERC20PeriodTransferEnforcer:transfer-not-started");
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the execution call data length is not 68 bytes.
    function testInvalidExecutionLength() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        bytes memory invalidExecCallData_ = new bytes(67);
        vm.expectRevert("ERC20PeriodTransferEnforcer:invalid-execution-length");
        erc20PeriodTransferEnforcer.beforeHook(
            terms_, "", singleDefaultMode, invalidExecCallData_, dummyDelegationHash, address(0), redeemer
        );
    }

    /// @notice Reverts if the target contract in execution data does not match the token in terms_.
    function testInvalidContract() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory invalidExecCallData_ = _encodeSingleExecution(address(0xdead), 0, callData_);
        vm.expectRevert("ERC20PeriodTransferEnforcer:invalid-contract");
        erc20PeriodTransferEnforcer.beforeHook(
            terms_, "", singleDefaultMode, invalidExecCallData_, dummyDelegationHash, address(0), redeemer
        );
    }

    /// @notice Reverts if the method selector in call data is not for IERC20.transfer.
    function testInvalidMethod() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        bytes memory invalidCallData_ = abi.encodeWithSelector(IERC20.transferFrom.selector, redeemer, 500);
        bytes memory invalidExecCallData_ = _encodeSingleExecution(address(basicERC20), 0, invalidCallData_);
        vm.expectRevert("ERC20PeriodTransferEnforcer:invalid-method");
        erc20PeriodTransferEnforcer.beforeHook(
            terms_, "", singleDefaultMode, invalidExecCallData_, dummyDelegationHash, address(0), redeemer
        );
    }

    /// @notice Reverts if a transfer exceeds the available allowance in the current period.
    function testTransferAmountExceeded() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // First transfer: 800 tokens.
        bytes memory callData1_ = _encodeERC20Transfer(bob, 800);
        bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        // Second transfer: attempt to transfer 300 tokens, which exceeds the remaining 200 tokens.
        bytes memory callData2_ = _encodeERC20Transfer(bob, 300);
        bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);
        vm.expectRevert("ERC20PeriodTransferEnforcer:transfer-amount-exceeded");
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);
    }

    /// @notice Tests a successful transfer and verifies that the TransferredInPeriod event is emitted correctly.
    function testSuccessfulTransferAndEvent() public {
        uint256 transferAmount_ = 500;
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        bytes memory callData_ = _encodeERC20Transfer(bob, transferAmount_);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        vm.expectEmit(true, true, true, true);
        emit ERC20PeriodTransferEnforcer.TransferredInPeriod(
            address(this),
            redeemer,
            dummyDelegationHash,
            address(basicERC20),
            periodAmount,
            periodDuration,
            startDate,
            transferAmount_,
            block.timestamp
        );

        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData_, dummyDelegationHash, address(0), redeemer);

        // Verify available tokens are reduced by the transferred amount.
        (uint256 available_,,) = erc20PeriodTransferEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(available_, periodAmount - transferAmount_);
    }

    /// @notice Tests multiple transfers within the same period and confirms that an over-transfer reverts.
    function testMultipleTransfersInSamePeriod() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // First transfer: 400 tokens.
        bytes memory callData1_ = _encodeERC20Transfer(bob, 400);
        bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), bob);

        // Second transfer: 300 tokens.
        bytes memory callData2_ = _encodeERC20Transfer(bob, 300);
        bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), bob);

        // Available tokens should now be 1000 - 400 - 300 = 300.
        (uint256 available_,,) = erc20PeriodTransferEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(available_, 300);

        // Third transfer: attempt to transfer 400 tokens, which should exceed the available amount.
        bytes memory callData3_ = _encodeERC20Transfer(bob, 400);
        bytes memory execData3_ = _encodeSingleExecution(address(basicERC20), 0, callData3_);
        vm.expectRevert("ERC20PeriodTransferEnforcer:transfer-amount-exceeded");
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData3_, dummyDelegationHash, address(0), bob);
    }

    /// @notice Tests that the allowance resets when a new period begins.
    function testNewPeriodResetsAllowance() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // First transfer: 800 tokens.
        bytes memory callData1_ = _encodeERC20Transfer(bob, 800);
        bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData1_, dummyDelegationHash, address(0), redeemer);

        // Verify available tokens have been reduced.
        (uint256 availableAfter1,,) = erc20PeriodTransferEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(availableAfter1, periodAmount - 800);

        // Warp to the next period.
        vm.warp(block.timestamp + periodDuration + 1);

        // Now the available amount should reset to the full periodAmount.
        (uint256 available_, bool isNewPeriod_,) =
            erc20PeriodTransferEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(available_, periodAmount);
        assertTrue(isNewPeriod_);

        // Make a transfer in the new period.
        bytes memory callData2_ = _encodeERC20Transfer(bob, 600);
        bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execData2_, dummyDelegationHash, address(0), redeemer);

        // Verify available tokens have been reduced.
        (uint256 availableAfter2,,) = erc20PeriodTransferEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(availableAfter2, periodAmount - 600);
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        erc20PeriodTransferEnforcer.beforeHook(
            hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0)
        );
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        erc20PeriodTransferEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration Tests //////////////////////

    /// @notice Integration: Successfully transfer tokens within the allowance and update state.
    function test_integration_SuccessfulTransfer() public {
        uint256 transferAmount_ = 500;
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // Build execution: transfer transferAmount_ from token to redeemer.
        bytes memory callData_ = _encodeERC20Transfer(bob, transferAmount_);

        // Build and sign the delegation.
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20PeriodTransferEnforcer), terms: terms_ });
        Delegation memory delegation =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex"" });
        delegation = signDelegation(users.alice, delegation);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation);

        // Invoke the user operation via delegation manager.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: address(basicERC20), value: 0, callData: callData_ })
        );

        // After transferring, available tokens should be reduced.
        (uint256 availableAfter_,,) =
            erc20PeriodTransferEnforcer.getAvailableAmount(delegationHash_, address(delegationManager), terms_);
        assertEq(availableAfter_, periodAmount - transferAmount_, "Available reduced by transfer amount");
    }

    /// @notice Integration: Fails if a transfer exceeds the available tokens in the current period.
    function test_integration_OverTransferFails() public {
        uint256 transferAmount1_ = 800;
        uint256 transferAmount2_ = 300; // total would be 1100, over the periodAmount of 1000
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        bytes memory callData1_ = _encodeERC20Transfer(bob, transferAmount1_);

        // Build and sign delegation.
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20PeriodTransferEnforcer), terms: terms_ });
        Delegation memory delegation =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex"" });
        delegation = signDelegation(users.alice, delegation);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation);

        // First transfer succeeds.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: address(basicERC20), value: 0, callData: callData1_ })
        );

        // Second transfer should revert.
        bytes memory callData2_ = _encodeERC20Transfer(bob, transferAmount2_);
        bytes memory execCallData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20PeriodTransferEnforcer:transfer-amount-exceeded");
        erc20PeriodTransferEnforcer.beforeHook(terms_, "", singleDefaultMode, execCallData2_, delegationHash_, address(0), redeemer);
    }

    /// @notice Integration: Verifies that the allowance resets in a new period.
    function test_integration_NewPeriodReset() public {
        uint256 transferAmount_ = 800;
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        bytes memory callData_ = _encodeERC20Transfer(bob, transferAmount_);

        // Build and sign delegation.
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20PeriodTransferEnforcer), terms: terms_ });
        Delegation memory delegation =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex"" });
        delegation = signDelegation(users.alice, delegation);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation);

        // First transfer in current period.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: address(basicERC20), value: 0, callData: callData_ })
        );

        (uint256 availableBefore_,, uint256 currentPeriodBefore_) =
            erc20PeriodTransferEnforcer.getAvailableAmount(delegationHash_, address(delegationManager), terms_);
        assertEq(availableBefore_, periodAmount - transferAmount_, "Allowance reduced after transfer");

        // Warp to next period.
        vm.warp(startDate + periodDuration + 1);

        (uint256 availableAfter_, bool isNewPeriod_, uint256 currentPeriodAfter_) =
            erc20PeriodTransferEnforcer.getAvailableAmount(delegationHash_, address(delegationManager), terms_);
        assertEq(availableAfter_, periodAmount, "Allowance resets in new period");
        assertTrue(isNewPeriod_, "isNewPeriod_ flag true");
        assertGt(currentPeriodAfter_, currentPeriodBefore_, "Period index increased");

        // Transfer in new period.
        callData_ = _encodeERC20Transfer(bob, 300);
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: address(basicERC20), value: 0, callData: callData_ })
        );
        (uint256 availableAfterTransfer,,) =
            erc20PeriodTransferEnforcer.getAvailableAmount(delegationHash_, address(delegationManager), terms_);
        assertEq(availableAfterTransfer, periodAmount - 300, "New period allowance reduced by new transfer");
    }

    /// @notice Integration: Confirms that different delegation hashes are tracked independently.
    function test_integration_MultipleDelegations() public {
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);

        // Build two delegations with different salts (hence different hashes).
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20PeriodTransferEnforcer), terms: terms_ });
        Delegation memory delegation1 =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex"" });
        Delegation memory delegation2 =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 1, signature: hex"" });
        delegation1 = signDelegation(users.alice, delegation1);
        delegation2 = signDelegation(users.alice, delegation2);
        // Use the computed delegation hashes.
        bytes32 computedDelHash1_ = EncoderLib._getDelegationHash(delegation1);
        bytes32 computedDelHash2_ = EncoderLib._getDelegationHash(delegation2);

        // For delegation1, transfer 600 tokens.
        bytes memory callData1_ = _encodeERC20Transfer(bob, 600);
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation1), Execution({ target: address(basicERC20), value: 0, callData: callData1_ })
        );

        // For delegation2, transfer 900 tokens.
        bytes memory callData2_ = _encodeERC20Transfer(bob, 900);
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation2), Execution({ target: address(basicERC20), value: 0, callData: callData2_ })
        );

        (uint256 available1_,,) =
            erc20PeriodTransferEnforcer.getAvailableAmount(computedDelHash1_, address(delegationManager), terms_);
        (uint256 available2_,,) =
            erc20PeriodTransferEnforcer.getAvailableAmount(computedDelHash2_, address(delegationManager), terms_);
        assertEq(available1_, periodAmount - 600, "Delegation1 allowance not reduced correctly");
        assertEq(available2_, periodAmount - 900, "Delegation2 allowance not reduced correctly");
    }

    ////////////////////// New Simulation Tests //////////////////////

    /// @notice Tests simulation of getAvailableAmount before and after the start date.
    ///         Initially, when the start date is in the future, the available amount is zero.
    ///         After warping time past the start date, the available amount equals periodAmount.
    function test_getAvailableAmountSimulationBeforeInitialization() public {
        // Set start date in the future.
        uint256 futureStart_ = block.timestamp + 100;
        bytes memory terms_ = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, futureStart_);

        // Before the start date, available amount should be 0.
        (uint256 availableBefore_, bool isNewPeriodBefore_, uint256 currentPeriodBefore_) =
            erc20PeriodTransferEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(availableBefore_, 0, "Available amount should be zero before start date");
        assertEq(isNewPeriodBefore_, false, "isNewPeriod_ should be false before start date");
        assertEq(currentPeriodBefore_, 0, "Current period should be 0 before start date");

        // Warp time to after the future start date.
        vm.warp(futureStart_ + 1);

        // Now, with no transfers, available amount should equal periodAmount.
        (uint256 availableAfter_, bool isNewPeriodAfter_, uint256 currentPeriodAfter_) =
            erc20PeriodTransferEnforcer.getAvailableAmount(dummyDelegationHash, address(this), terms_);
        assertEq(availableAfter_, periodAmount, "Available amount should equal periodAmount after start date");
        assertEq(isNewPeriodAfter_, true, "isNewPeriod_ should be true after start date");

        // Optionally, verify the current period calculation.
        uint256 expectedPeriod_ = (block.timestamp - futureStart_) / periodDuration + 1;
        assertEq(currentPeriodAfter_, expectedPeriod_, "Current period computed incorrectly after start date");
    }

    ////////////////////// Helper Functions //////////////////////

    /// @dev Construct the callData for `IERC20.transfer(address,uint256)`.
    /// @param _to Recipient of the transfer.
    /// @param _amount Amount to transfer.
    function _encodeERC20Transfer(address _to, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.transfer.selector, _to, _amount);
    }

    /// @dev Construct the callData for `IERC20.transfer(address,uint256)` using a preset redeemer.
    /// @param _amount Amount to transfer.
    function _encodeERC20Transfer(uint256 _amount) internal view returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.transfer.selector, redeemer, _amount);
    }

    function _encodeSingleExecution(address _target, uint256 _value, bytes memory _callData) internal pure returns (bytes memory) {
        return abi.encodePacked(_target, _value, _callData);
    }

    /// @dev Helper to convert a single delegation to an array.
    function toDelegationArray(Delegation memory _delegation) internal pure returns (Delegation[] memory) {
        Delegation[] memory arr = new Delegation[](1);
        arr[0] = _delegation;
        return arr;
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(erc20PeriodTransferEnforcer));
    }
}
