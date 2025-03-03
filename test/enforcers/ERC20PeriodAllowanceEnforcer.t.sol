// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { ModeCode, Caveat, Delegation, Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC20PeriodAllowanceEnforcer } from "../../src/enforcers/ERC20PeriodAllowanceEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

contract ERC20PeriodAllowanceEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    ////////////////////////////// State //////////////////////////////
    ERC20PeriodAllowanceEnforcer public erc20PeriodAllowanceEnforcer;
    BasicERC20 public basicERC20;
    ModeCode public singleMode = ModeLib.encodeSimpleSingle();
    address public alice;
    address public bob;

    bytes32 delegationHash = keccak256("test-delegation");
    address redeemer = address(0x123);

    // Parameters for the periodic allowance.
    uint256 periodAmount = 1000;
    uint256 periodDuration = 1 days; // 86400 seconds
    uint256 startDate;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        erc20PeriodAllowanceEnforcer = new ERC20PeriodAllowanceEnforcer();
        vm.label(address(erc20PeriodAllowanceEnforcer), "ERC20 Periodic Claim Enforcer");

        alice = address(users.alice.deleGator);
        bob = address(users.bob.deleGator);

        basicERC20 = new BasicERC20(alice, "TestToken", "TestToken", 100 ether);

        startDate = block.timestamp; // set startDate to current block time
    }

    //////////////////// Error / Revert Tests //////////////////////

    /// @notice Ensures it reverts if _terms length is not exactly 116 bytes.
    function testInvalidTermsLength() public {
        bytes memory invalidTerms = new bytes(115); // one byte short
        vm.expectRevert("ERC20PeriodAllowanceEnforcer:invalid-terms-length");
        erc20PeriodAllowanceEnforcer.getTermsInfo(invalidTerms);
    }

    /// @notice Reverts if the start date is zero.
    function testInvalidZeroStartDate() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, uint256(0));

        bytes memory callData_ = _encodeERC20Transfer(bob, 100);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        vm.expectRevert("ERC20PeriodAllowanceEnforcer:invalid-zero-start-date");
        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData_, delegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the period duration is zero.
    function testInvalidZeroPeriodDuration() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, uint256(0), startDate);

        bytes memory callData_ = _encodeERC20Transfer(bob, 100);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        vm.expectRevert("ERC20PeriodAllowanceEnforcer:invalid-zero-period-duration");
        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData_, delegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the period amount is zero.
    function testInvalidZeroPeriodAmount() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), uint256(0), periodDuration, startDate);

        bytes memory callData_ = _encodeERC20Transfer(bob, 100);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
        vm.expectRevert("ERC20PeriodAllowanceEnforcer:invalid-zero-period-amount");
        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData_, delegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the claim period has not started yet.
    function testClaimNotStarted() public {
        uint256 futureStart = block.timestamp + 100;
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, futureStart);

        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        vm.expectRevert("ERC20PeriodAllowanceEnforcer:claim-not-started");
        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData_, delegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the execution call data length is not 68 bytes.
    function testInvalidExecutionLength() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // Create call data with invalid length (not 68 bytes)
        bytes memory invalidExecCallData = new bytes(67);
        vm.expectRevert("ERC20PeriodAllowanceEnforcer:invalid-execution-length");
        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, invalidExecCallData, delegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the target contract in execution data does not match the token in terms.
    function testInvalidContract() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);

        // Create execution call data with a wrong target (simulate by prepending a different address)
        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory invalidExecCallData = _encodeSingleExecution(address(0xdead), 0, callData_);

        vm.expectRevert("ERC20PeriodAllowanceEnforcer:invalid-contract");
        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, invalidExecCallData, delegationHash, address(0), redeemer);
    }

    /// @notice Reverts if the method selector in call data is not for IERC20.transfer.
    function testInvalidMethod() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // Create call data with an invalid function selector (not IERC20.transfer.selector)
        bytes memory invalidCallData = abi.encodeWithSelector(IERC20.transferFrom.selector, redeemer, 500);
        bytes memory invalidExecCallData = _encodeSingleExecution(address(basicERC20), 0, invalidCallData);

        vm.expectRevert("ERC20PeriodAllowanceEnforcer:invalid-method");
        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, invalidExecCallData, delegationHash, address(0), redeemer);
    }

    /// @notice Reverts if a claim exceeds the available allowance in the current period.
    function testClaimAmountExceeded() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);

        // First claim: 800 tokens.
        bytes memory callData1_ = _encodeERC20Transfer(bob, 800);
        bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);

        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData1_, delegationHash, address(0), redeemer);

        // Second claim: attempt to claim 300 tokens, which exceeds the remaining 200 tokens.
        bytes memory callData2_ = _encodeERC20Transfer(bob, 300);
        bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);

        vm.expectRevert("ERC20PeriodAllowanceEnforcer:claim-amount-exceeded");
        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData2_, delegationHash, address(0), redeemer);
    }

    /// @notice Tests a successful claim and verifies that the ClaimUpdated event is emitted correctly.
    function testSuccessfulClaimAndEvent() public {
        uint256 claimAmount = 500;

        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        bytes memory callData_ = _encodeERC20Transfer(bob, claimAmount);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        // Expect the ClaimUpdated event with matching parameters.
        vm.expectEmit(true, true, true, true);
        emit ERC20PeriodAllowanceEnforcer.ClaimUpdated(
            address(this),
            redeemer,
            delegationHash,
            address(basicERC20),
            periodAmount,
            periodDuration,
            startDate,
            claimAmount,
            block.timestamp
        );

        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData_, delegationHash, address(0), redeemer);

        // Verify available amount is reduced by the claimed amount.
        (uint256 available_,,) = erc20PeriodAllowanceEnforcer.getAvailableAmount(delegationHash, address(this));
        assertEq(available_, periodAmount - claimAmount);
    }

    /// @notice Tests multiple claims within the same period and confirms that an over-claim reverts.
    function testMultipleClaimsInSamePeriod() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // First claim: 400 tokens.
        bytes memory callData1_ = _encodeERC20Transfer(bob, 400);
        bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);

        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData1_, delegationHash, address(0), bob);

        // Second claim: 300 tokens.
        bytes memory callData2_ = _encodeERC20Transfer(bob, 300);
        bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);
        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData2_, delegationHash, address(0), bob);

        // Available tokens should now be 1000 - 400 - 300 = 300.
        (uint256 available_,,) = erc20PeriodAllowanceEnforcer.getAvailableAmount(delegationHash, address(this));
        assertEq(available_, 300);

        // Third claim: attempt to claim 400 tokens, which should exceed available amount.
        bytes memory callData3_ = _encodeERC20Transfer(bob, 400);
        bytes memory execData3_ = _encodeSingleExecution(address(basicERC20), 0, callData3_);
        vm.expectRevert("ERC20PeriodAllowanceEnforcer:claim-amount-exceeded");
        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData3_, delegationHash, address(0), bob);
    }

    /// @notice Tests that the allowance resets when a new period begins.
    function testNewPeriodResetsAllowance() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // First claim: 800 tokens.
        bytes memory callData1_ = _encodeERC20Transfer(bob, 800);
        bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);

        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData1_, delegationHash, address(0), redeemer);

        // Verify available tokens have been reduced.
        (uint256 availableAfter1,,) = erc20PeriodAllowanceEnforcer.getAvailableAmount(delegationHash, address(this));
        assertEq(availableAfter1, periodAmount - 800);

        // Warp to the next period.
        vm.warp(block.timestamp + periodDuration + 1);

        // Now the available amount should reset to the full periodAmount.
        (uint256 available, bool isNewPeriod,) = erc20PeriodAllowanceEnforcer.getAvailableAmount(delegationHash, address(this));
        assertEq(available, periodAmount);
        assertTrue(isNewPeriod);

        // Make a claim in the new period.
        bytes memory callData2_ = _encodeERC20Transfer(bob, 600);
        bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);

        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execData2_, delegationHash, address(0), redeemer);

        // Verify available tokens have been reduced.
        (uint256 availableAfter2,,) = erc20PeriodAllowanceEnforcer.getAvailableAmount(delegationHash, address(this));
        assertEq(availableAfter2, periodAmount - 600);
    }

    ////////////////////// Integration Tests //////////////////////

    /// @notice Integration: Successfully claim tokens within the allowance and update state.
    function test_integration_SuccessfulClaim() public {
        uint256 claimAmount = 500;
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // Build execution: transfer claimAmount from token to redeemer.
        bytes memory callData = _encodeERC20Transfer(bob, claimAmount);

        // Build and sign the delegation.
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ args: hex"", enforcer: address(erc20PeriodAllowanceEnforcer), terms: terms });
        Delegation memory delegation =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats, salt: 0, signature: hex"" });
        delegation = signDelegation(users.alice, delegation);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation);

        // Invoke the user operation via delegation manager.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: address(basicERC20), value: 0, callData: callData })
        );

        // After claiming, available tokens should reduce.
        (uint256 availableAfter,,) = erc20PeriodAllowanceEnforcer.getAvailableAmount(delegationHash_, address(delegationManager));
        assertEq(availableAfter, periodAmount - claimAmount, "Available reduced by claim amount");
    }

    /// @notice Integration: Fails if a claim exceeds the available tokens in the current period.
    function test_integration_OverClaimFails() public {
        uint256 claimAmount1 = 800;
        uint256 claimAmount2 = 300; // total would be 1100, over the periodAmount of 1000
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        bytes memory callData1 = _encodeERC20Transfer(bob, claimAmount1);

        // Build and sign delegation.
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ args: hex"", enforcer: address(erc20PeriodAllowanceEnforcer), terms: terms });
        Delegation memory delegation =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats, salt: 0, signature: hex"" });
        delegation = signDelegation(users.alice, delegation);
        bytes32 delHash = EncoderLib._getDelegationHash(delegation);

        // First claim succeeds.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: address(basicERC20), value: 0, callData: callData1 })
        );

        // Second claim should revert.
        bytes memory callData2 = _encodeERC20Transfer(bob, claimAmount2);
        bytes memory execCallData2 = _encodeSingleExecution(address(basicERC20), 0, callData2);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20PeriodAllowanceEnforcer:claim-amount-exceeded");
        erc20PeriodAllowanceEnforcer.beforeHook(terms, "", singleMode, execCallData2, delHash, address(0), redeemer);
    }

    /// @notice Integration: Verifies that the allowance resets in a new period.
    function test_integration_NewPeriodReset() public {
        uint256 claimAmount = 800;
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        bytes memory callData1 = _encodeERC20Transfer(bob, claimAmount);

        // Build and sign delegation.
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ args: hex"", enforcer: address(erc20PeriodAllowanceEnforcer), terms: terms });
        Delegation memory delegation =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats, salt: 0, signature: hex"" });
        delegation = signDelegation(users.alice, delegation);
        bytes32 delHash = EncoderLib._getDelegationHash(delegation);

        // First claim in current period.
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: address(basicERC20), value: 0, callData: callData1 })
        );

        (uint256 availableBefore,, uint256 currentPeriodBefore) =
            erc20PeriodAllowanceEnforcer.getAvailableAmount(delHash, address(delegationManager));
        assertEq(availableBefore, periodAmount - claimAmount, "Allowance reduced after claim");

        // Warp to next period.
        vm.warp(startDate + periodDuration + 1);

        (uint256 availableAfter, bool isNewPeriod, uint256 currentPeriodAfter) =
            erc20PeriodAllowanceEnforcer.getAvailableAmount(delHash, address(delegationManager));
        assertEq(availableAfter, periodAmount, "Allowance resets in new period");
        assertTrue(isNewPeriod, "isNewPeriod flag true");
        assertGt(currentPeriodAfter, currentPeriodBefore, "Period index increased");

        // Claim in new period.
        uint256 newClaim = 300;
        bytes memory callData2 = _encodeERC20Transfer(bob, newClaim);
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation), Execution({ target: address(basicERC20), value: 0, callData: callData2 })
        );
        (uint256 availableAfterClaim,,) = erc20PeriodAllowanceEnforcer.getAvailableAmount(delHash, address(delegationManager));
        assertEq(availableAfterClaim, periodAmount - newClaim, "New period allowance reduced by new claim");
    }

    /// @notice Integration: Confirms that different delegation hashes are tracked independently.
    function test_integration_MultipleDelegations() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);

        // Build two delegations with different hashes.
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ args: hex"", enforcer: address(erc20PeriodAllowanceEnforcer), terms: terms });
        Delegation memory delegation1 =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats, salt: 0, signature: hex"" });
        Delegation memory delegation2 =
            Delegation({ delegate: bob, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats, salt: 1, signature: hex"" });
        delegation1 = signDelegation(users.alice, delegation1);
        delegation2 = signDelegation(users.alice, delegation2);
        // Use the computed delegation hashes.
        bytes32 computedDelHash1 = EncoderLib._getDelegationHash(delegation1);
        bytes32 computedDelHash2 = EncoderLib._getDelegationHash(delegation2);

        // For delegation1, claim 600 tokens.
        bytes memory callData1 = _encodeERC20Transfer(bob, 600);
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation1), Execution({ target: address(basicERC20), value: 0, callData: callData1 })
        );

        // For delegation1, claim 600 tokens.
        bytes memory callData2 = _encodeERC20Transfer(bob, 900);
        invokeDelegation_UserOp(
            users.bob, toDelegationArray(delegation2), Execution({ target: address(basicERC20), value: 0, callData: callData2 })
        );

        // // delegation2 remains unused.
        (uint256 available1,,) = erc20PeriodAllowanceEnforcer.getAvailableAmount(computedDelHash1, address(delegationManager));
        (uint256 available2,,) = erc20PeriodAllowanceEnforcer.getAvailableAmount(computedDelHash2, address(delegationManager));
        assertEq(available1, periodAmount - 600, "Delegation1 allowance not reduced correctly");
        assertEq(available2, periodAmount - 900, "Delegation2 allowance not reduced correctly");
    }

    ////////////////////// Helper Functions //////////////////////

    /**
     * @dev Construct the callData_ for `IERC20.transfer(address,uint256)`.
     * @param to Recipient of the transfer
     * @param amount Amount to transfer
     */
    function _encodeERC20Transfer(address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.transfer.selector, to, amount);
    }

    /**
     * @dev Construct the callData_ for `IERC20.transfer(address,uint256)`.
     * @param amount Amount to transfer
     */
    function _encodeERC20Transfer(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.transfer.selector, redeemer, amount);
    }

    function _encodeSingleExecution(address target, uint256 value, bytes memory callData_) internal pure returns (bytes memory) {
        return abi.encodePacked(target, value, callData_);
    }

    /// @dev Helper to convert a single delegation to an array.
    function toDelegationArray(Delegation memory delegation) internal pure returns (Delegation[] memory) {
        Delegation[] memory arr = new Delegation[](1);
        arr[0] = delegation;
        return arr;
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(erc20PeriodAllowanceEnforcer));
    }
}
