// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { LogicalOrWrapperEnforcer } from "../../src/enforcers/LogicalOrWrapperEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { NativeTokenTransferAmountEnforcer } from "../../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { TimestampEnforcer } from "../../src/enforcers/TimestampEnforcer.sol";
import { ArgsEqualityCheckEnforcer } from "../../src/enforcers/ArgsEqualityCheckEnforcer.sol";
import { ERC20PeriodTransferEnforcer } from "../../src/enforcers/ERC20PeriodTransferEnforcer.sol";
import { NativeTokenPeriodTransferEnforcer } from "../../src/enforcers/NativeTokenPeriodTransferEnforcer.sol";
import { LimitedCallsEnforcer } from "../../src/enforcers/LimitedCallsEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import "forge-std/Test.sol";

contract LogicalOrWrapperEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////

    LogicalOrWrapperEnforcer public logicalOrWrapperEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    TimestampEnforcer public timestampEnforcer;
    ArgsEqualityCheckEnforcer public argsEqualityCheckEnforcer;
    NativeTokenTransferAmountEnforcer public nativeTokenTransferAmountEnforcer;
    ERC20PeriodTransferEnforcer public erc20PeriodTransferEnforcer;
    NativeTokenPeriodTransferEnforcer public nativeTokenPeriodTransferEnforcer;
    LimitedCallsEnforcer public limitedCallsEnforcer;

    address[] tokens = new address[](3);

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer(delegationManager);
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        timestampEnforcer = new TimestampEnforcer();
        argsEqualityCheckEnforcer = new ArgsEqualityCheckEnforcer();
        nativeTokenTransferAmountEnforcer = new NativeTokenTransferAmountEnforcer();
        erc20PeriodTransferEnforcer = new ERC20PeriodTransferEnforcer();
        nativeTokenPeriodTransferEnforcer = new NativeTokenPeriodTransferEnforcer();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        vm.label(address(logicalOrWrapperEnforcer), "Logical OR Wrapper Enforcer");
        vm.label(address(allowedMethodsEnforcer), "Allowed Methods Enforcer");
        vm.label(address(timestampEnforcer), "Timestamp Enforcer");
        vm.label(address(argsEqualityCheckEnforcer), "Args Equality Check Enforcer");
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");
        vm.label(address(nativeTokenTransferAmountEnforcer), "Native Token Transfer Amount Enforcer");
        vm.label(address(erc20PeriodTransferEnforcer), "ERC20 Period Transfer Enforcer");
        vm.label(address(nativeTokenPeriodTransferEnforcer), "Native Token Period Transfer Enforcer");
        vm.label(address(limitedCallsEnforcer), "Limited Calls Enforcer");
    }

    ////////////////////// Helper Functions //////////////////////

    function _createCaveatGroup(
        address[] memory _enforcers,
        bytes[] memory _terms
    )
        internal
        pure
        returns (LogicalOrWrapperEnforcer.CaveatGroup memory)
    {
        require(_enforcers.length == _terms.length, "LogicalOrWrapperEnforcerTest:invalid-input-length");
        Caveat[] memory caveats = new Caveat[](_enforcers.length);
        for (uint256 i = 0; i < _enforcers.length; ++i) {
            caveats[i] = Caveat({ enforcer: _enforcers[i], terms: _terms[i], args: hex"" });
        }
        return LogicalOrWrapperEnforcer.CaveatGroup({ caveats: caveats });
    }

    function _createSelectedGroup(
        uint256 _groupIndex,
        bytes[] memory _caveatArgs
    )
        internal
        pure
        returns (LogicalOrWrapperEnforcer.SelectedGroup memory)
    {
        return LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: _groupIndex, caveatArgs: _caveatArgs });
    }

    ////////////////////// Valid cases //////////////////////

    /// @notice Tests that a single caveat group with one caveat works correctly by verifying that a group with a single allowed
    /// methods caveat can be evaluated
    function test_singleCaveatGroupWithSingleCaveat() public {
        // Create a group with a single caveat (allowed methods)
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(allowedMethodsEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encodePacked(Counter.increment.selector);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs_);

        // Call the hook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that a single caveat group with multiple caveats works correctly by verifying that a group with both allowed
    /// methods and timestamp caveats can be evaluated
    function test_singleCaveatGroupWithMultipleCaveats() public {
        // Create a group with multiple caveats (allowed methods and timestamp)
        address[] memory enforcers_ = new address[](2);
        enforcers_[0] = address(allowedMethodsEnforcer);
        enforcers_[1] = address(timestampEnforcer);
        bytes[] memory terms_ = new bytes[](2);
        terms_[0] = abi.encodePacked(Counter.increment.selector);
        terms_[1] = abi.encode(block.timestamp + 1 days);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](2);
        caveatArgs_[0] = hex"";
        caveatArgs_[1] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs_);

        // Call the hook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that multiple caveat groups can be evaluated independently by verifying that different groups with different
    /// caveats can be selected and evaluated
    function test_multipleCaveatGroups() public {
        // Create two groups with different caveats
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);

        // First group: allowed methods
        address[] memory enforcers1_ = new address[](1);
        enforcers1_[0] = address(allowedMethodsEnforcer);
        bytes[] memory terms1_ = new bytes[](1);
        terms1_[0] = abi.encodePacked(Counter.increment.selector);
        groups_[0] = _createCaveatGroup(enforcers1_, terms1_);

        // Second group: timestamp
        address[] memory enforcers2_ = new address[](1);
        enforcers2_[0] = address(timestampEnforcer);
        bytes[] memory terms2_ = new bytes[](1);
        terms2_[0] = abi.encode(block.timestamp + 1 days);
        groups_[1] = _createCaveatGroup(enforcers2_, terms2_);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Test first group
        bytes[] memory caveatArgs1_ = new bytes[](1);
        caveatArgs1_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup1_ = _createSelectedGroup(0, caveatArgs1_);

        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup1_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Test second group
        bytes[] memory caveatArgs2_ = new bytes[](1);
        caveatArgs2_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup2_ = _createSelectedGroup(1, caveatArgs2_);

        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup2_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that the ArgsEqualityCheckEnforcer works correctly when terms match args through the LogicalOrWrapperEnforcer
    function test_argsEqualityCheckEnforcerSuccess() public {
        // Create a group with a single caveat (args equality check)
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(argsEqualityCheckEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encode("test123"); // Terms to match against
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with matching args
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = abi.encode("test123"); // Args that match the terms
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs_);

        // Call the hook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that the ArgsEqualityCheckEnforcer fails when terms don't match args through the LogicalOrWrapperEnforcer
    function test_argsEqualityCheckEnforcerFailure() public {
        // Create a group with a single caveat (args equality check)
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(argsEqualityCheckEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encode("test123"); // Terms to match against
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with non-matching args
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = abi.encode("different"); // Args that don't match the terms
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs_);

        // Call the hook
        vm.prank(address(delegationManager));
        vm.expectRevert("ArgsEqualityCheckEnforcer:different-args-and-terms");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that multiple groups with NativeTokenPeriodTransferEnforcer work correctly through the redemption flow
    function test_multipleNativeTokenPeriodTransferGroups() public {
        vm.warp(block.timestamp + 1 days);
        // Create 3 groups with different period transfer limits
        address[] memory enforcers = new address[](1);
        enforcers[0] = address(nativeTokenPeriodTransferEnforcer);

        bytes[] memory terms1_ = new bytes[](1);
        terms1_[0] = abi.encode(1 ether, 1 days, block.timestamp); // 1 ETH per day

        bytes[] memory terms2_ = new bytes[](1);
        terms2_[0] = abi.encode(1 ether, 2 days, block.timestamp); // 2 ETH per 2 days

        bytes[] memory terms3_ = new bytes[](1);
        terms3_[0] = abi.encode(1 ether, 3 days, block.timestamp); // 3 ETH per 3 days

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](3);
        groups_[0] = _createCaveatGroup(enforcers, terms1_);
        groups_[1] = _createCaveatGroup(enforcers, terms2_);
        groups_[2] = _createCaveatGroup(enforcers, terms3_);

        // Create and sign delegation
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_), args: hex"" });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);
        // bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        // Verify initial balance
        uint256 recipientInitialBalance_ = address(0x123).balance;
        for (uint256 i = 0; i < groups_.length; i++) {
            // Create execution data for a 1 ETH transfer
            Execution memory execution_ = Execution({ target: payable(address(0x123)), value: 1 ether, callData: hex"" });

            // Create selected group using group index 1 (2 ETH per 2 days)
            // bytes[] memory caveatArgs_ = new bytes[](1);
            // caveatArgs_[0] = hex""; // No args needed for NativeTokenPeriodTransferEnforcer
            LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(i, new bytes[](1));
            delegation_.caveats[0].args = abi.encode(selectedGroup_);

            // Execute Bob's UserOp
            Delegation[] memory delegations_ = new Delegation[](1);
            delegations_[0] = delegation_;

            uint256 recipientBalanceBefore_ = address(0x123).balance;

            // Execute the delegation
            invokeDelegation_UserOp(users.bob, delegations_, execution_);

            (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_) = nativeTokenPeriodTransferEnforcer
                .getAvailableAmount(
                logicalOrWrapperEnforcer.getLogicalOrDelegationHash(
                    EncoderLib._getDelegationHash(delegation_), selectedGroup_.groupIndex
                ),
                address(logicalOrWrapperEnforcer),
                groups_[selectedGroup_.groupIndex].caveats[0].terms
            );
            assertEq(availableAmount_, 0, "Available amount should be 0");
            assertEq(isNewPeriod_, false, "Is new period should be false");
            assertEq(currentPeriod_, 1, "Current period should be 1");

            // Verify the transfer occurred
            assertEq(address(0x123).balance, recipientBalanceBefore_ + 1 ether, "Transfer should have occurred with 1 ether");
        }
        // Verify the transfer occurred
        assertEq(address(0x123).balance, recipientInitialBalance_ + 3 ether, "Transfer should have occurred with 3 ether");
    }

    /// @notice Tests that multiple ERC20 period transfer groups work correctly by verifying that transfers within different period
    /// limits succeed
    function test_multipleERC20PeriodTransferGroups() public {
        vm.warp(block.timestamp + 1 days);

        // Create test token and mint initial balance
        // address[] memory tokens_ = new address[](3);
        tokens[0] = address(new BasicERC20(address(users.alice.deleGator), "TEST1", "TEST1", 100 ether));
        tokens[1] = address(new BasicERC20(address(users.alice.deleGator), "TEST2", "TEST2", 100 ether));
        tokens[2] = address(new BasicERC20(address(users.alice.deleGator), "TEST2", "TEST2", 100 ether));

        // Create groups with different period transfer limits
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20PeriodTransferEnforcer);
        bytes[] memory terms1_ = new bytes[](1);
        terms1_[0] = abi.encodePacked(address(tokens[0]), uint256(1 ether), uint256(1 days), block.timestamp); // 1 ETH per day

        bytes[] memory terms2_ = new bytes[](1);
        terms2_[0] = abi.encodePacked(address(tokens[1]), uint256(1 ether), uint256(2 days), block.timestamp); // 1 ETH per 2 days

        bytes[] memory terms3_ = new bytes[](1);
        terms3_[0] = abi.encodePacked(address(tokens[2]), uint256(1 ether), uint256(3 days), block.timestamp); // 1 ETH per 3 days

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](3);
        groups_[0] = _createCaveatGroup(enforcers_, terms1_);
        groups_[1] = _createCaveatGroup(enforcers_, terms2_);
        groups_[2] = _createCaveatGroup(enforcers_, terms3_);

        // Create the caveat with the groups
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_), args: hex"" });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        for (uint256 i = 0; i < groups_.length; i++) {
            LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(i, new bytes[](1));
            delegation_.caveats[0].args = abi.encode(selectedGroup_);

            // Execute Bob's UserOp
            Delegation[] memory delegations_ = new Delegation[](1);
            delegations_[0] = delegation_;

            uint256 recipientBalanceBefore_ = IERC20(tokens[i]).balanceOf(address(0x123));

            // Execute the delegation
            invokeDelegation_UserOp(
                users.bob,
                delegations_,
                Execution({
                    target: address(tokens[i]),
                    value: 0,
                    callData: abi.encodeWithSelector(IERC20.transfer.selector, address(0x123), 1 ether)
                })
            );

            (uint256 availableAmount_, bool isNewPeriod_, uint256 currentPeriod_) = erc20PeriodTransferEnforcer.getAvailableAmount(
                logicalOrWrapperEnforcer.getLogicalOrDelegationHash(
                    EncoderLib._getDelegationHash(delegation_), selectedGroup_.groupIndex
                ),
                address(logicalOrWrapperEnforcer),
                groups_[selectedGroup_.groupIndex].caveats[0].terms
            );
            assertEq(availableAmount_, 0, "Available amount should be 0");
            assertEq(isNewPeriod_, false, "Is new period should be false");
            assertEq(currentPeriod_, 1, "Current period should be 1");

            // Verify the transfer occurred
            assertEq(
                IERC20(tokens[i]).balanceOf(address(0x123)),
                recipientBalanceBefore_ + 1 ether,
                "Transfer should have occurred with 1 ether"
            );
        }
        // Verify the total transfers occurred
        assertEq(IERC20(tokens[0]).balanceOf(address(0x123)), 1 ether, "Transfer should have occurred with 1 ether");
        assertEq(IERC20(tokens[1]).balanceOf(address(0x123)), 1 ether, "Transfer should have occurred with 1 ether");
        assertEq(IERC20(tokens[2]).balanceOf(address(0x123)), 1 ether, "Transfer should have occurred with 1 ether");
    }

    /// @notice Tests that two CaveatGroups with LimitedCallsEnforcer can be redeemed successfully
    function test_twoGroupsWithLimitedCallsEnforcer() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create two groups with LimitedCallsEnforcer
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(limitedCallsEnforcer);

        // Group 0: Allow 2 calls to increment
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encodePacked(uint256(2)); // Allow 2 calls
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Group 1: Allow 1 call to increment
        bytes[] memory terms1_ = new bytes[](1);
        terms1_[0] = abi.encodePacked(uint256(1)); // Allow 1 call
        groups_[1] = _createCaveatGroup(enforcers_, terms1_);

        // Create execution for counter increment
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Create caveat for the logical OR wrapper
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_), args: hex"" });

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Execute Bob's UserOp for first group (2 calls)
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        delegations_[0].caveats[0].args = abi.encode(_createSelectedGroup(0, new bytes[](1)));

        // First call using group 0
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertEq(aliceDeleGatorCounter.count(), initialValue_ + 1, "First call should increment counter");

        // Second call using group 0
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertEq(aliceDeleGatorCounter.count(), initialValue_ + 2, "Second call should increment counter");

        // Third call using group 1 should fail
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertEq(aliceDeleGatorCounter.count(), initialValue_ + 2, "Third call should not increment counter");

        // Switch to group 1 (1 call allowed)
        delegations_[0].caveats[0].args = abi.encode(_createSelectedGroup(1, new bytes[](1)));

        // Fourth call using group 1
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertEq(aliceDeleGatorCounter.count(), initialValue_ + 3, "Fourth call should increment counter");

        // Fifth call using group 1 should fail
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertEq(aliceDeleGatorCounter.count(), initialValue_ + 3, "Fifth call should not increment counter");
    }

    ////////////////////// Invalid cases //////////////////////

    /// @notice Tests that an invalid group index reverts with the expected error by verifying that selecting a group index beyond
    /// the available groups reverts
    function test_invalidGroupIndex() public {
        // Create a single group
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(allowedMethodsEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encodePacked(Counter.increment.selector);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with invalid index
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(1, caveatArgs_);

        // Call the hook
        vm.prank(address(delegationManager));
        vm.expectRevert("LogicalOrWrapperEnforcer:invalid-group-index");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that mismatched caveat arguments length reverts with the expected error by verifying that providing incorrect
    /// number of arguments for caveats reverts
    function test_invalidCaveatArgsLength() public {
        // Create a group with two caveats
        address[] memory enforcers_ = new address[](2);
        enforcers_[0] = address(allowedMethodsEnforcer);
        enforcers_[1] = address(timestampEnforcer);
        bytes[] memory terms_ = new bytes[](2);
        terms_[0] = abi.encodePacked(Counter.increment.selector);
        terms_[1] = abi.encode(block.timestamp + 1 days);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with wrong number of arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs_);

        // Call the hook
        vm.prank(address(delegationManager));
        vm.expectRevert("LogicalOrWrapperEnforcer:invalid-caveat-args-length");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that invalid execution mode reverts with the expected error by verifying that non-default execution modes are
    /// not allowed
    function test_invalidExecutionMode() public {
        // Create a group with a single caveat
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(allowedMethodsEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encodePacked(Counter.increment.selector);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution data
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs_);

        // Call the hook with invalid singleTryMode
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup_),
            singleTryMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that only the delegation manager can call the hooks by verifying that calls from non-delegation
    /// manager addresses revert with the expected error
    function test_onlyDelegationManager() public {
        // Call the hook from a non-delegation manager address
        vm.startPrank(address(0x1234));
        vm.expectRevert("LogicalOrWrapperEnforcer:only-delegation-manager");
        logicalOrWrapperEnforcer.beforeHook(hex"", hex"", singleDefaultMode, hex"", keccak256(""), address(0), address(0));

        vm.expectRevert("LogicalOrWrapperEnforcer:only-delegation-manager");
        logicalOrWrapperEnforcer.beforeAllHook(hex"", hex"", singleDefaultMode, hex"", keccak256(""), address(0), address(0));

        vm.expectRevert("LogicalOrWrapperEnforcer:only-delegation-manager");
        logicalOrWrapperEnforcer.afterHook(hex"", hex"", singleDefaultMode, hex"", keccak256(""), address(0), address(0));

        vm.expectRevert("LogicalOrWrapperEnforcer:only-delegation-manager");
        logicalOrWrapperEnforcer.afterAllHook(hex"", hex"", singleDefaultMode, hex"", keccak256(""), address(0), address(0));

        vm.stopPrank();
    }

    ////////////////////// Integration //////////////////////

    /// @notice Tests the integration of the logical OR wrapper with the delegation framework by verifying that the enforcer works
    /// correctly in a real delegation scenario
    function test_integrationWithDelegation() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create a group with multiple caveats
        address[] memory enforcers_ = new address[](2);
        enforcers_[0] = address(allowedMethodsEnforcer);
        enforcers_[1] = address(timestampEnforcer);
        bytes[] memory terms_ = new bytes[](2);
        terms_[0] = abi.encodePacked(Counter.increment.selector);
        terms_[1] = abi.encode(block.timestamp + 1 days);
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Create caveat for the logical OR wrapper
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(logicalOrWrapperEnforcer),
            terms: abi.encode(groups_),
            args: abi.encode(_createSelectedGroup(0, new bytes[](2)))
        });

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Enforcer allows the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Get count
        uint256 valueAfter_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(valueAfter_, initialValue_ + 1);
    }

    /// @notice Tests the integration of the logical OR wrapper with method/target permissions and ETH transfers
    function test_integrationWithMethodAndEthTransfer() public {
        // Record initial balances
        uint256 initialAliceBalance_ = address(users.alice.deleGator).balance;
        uint256 initialCarolBalance_ = address(users.carol.deleGator).balance;
        uint256 initialCounterValue_ = aliceDeleGatorCounter.count();

        // Create two caveat groups
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);

        // Group 0: Allow increment method on counter
        address[] memory enforcers0_ = new address[](2);
        enforcers0_[0] = address(allowedMethodsEnforcer);
        enforcers0_[1] = address(allowedTargetsEnforcer);
        bytes[] memory terms0_ = new bytes[](2);
        terms0_[0] = abi.encodePacked(Counter.increment.selector);
        terms0_[1] = abi.encodePacked(address(aliceDeleGatorCounter));
        groups_[0] = _createCaveatGroup(enforcers0_, terms0_);

        // Group 1: Allow ETH transfer up to 1 ether
        address[] memory enforcers1_ = new address[](1);
        enforcers1_[0] = address(nativeTokenTransferAmountEnforcer);
        bytes[] memory terms1_ = new bytes[](1);
        terms1_[0] = abi.encode(1 ether);
        groups_[1] = _createCaveatGroup(enforcers1_, terms1_);

        // Create execution for counter increment
        Execution memory counterExecution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Create execution for ETH transfer to Carol
        Execution memory ethExecution_ = Execution({ target: address(users.carol.deleGator), value: 0.5 ether, callData: hex"" });

        // Create caveat for the logical OR wrapper
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(logicalOrWrapperEnforcer),
            terms: abi.encode(groups_),
            args: abi.encode(_createSelectedGroup(0, new bytes[](2))) // Use group 0 for counter
         });

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Execute Bob's UserOp for counter increment
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        invokeDelegation_UserOp(users.bob, delegations_, counterExecution_);

        // Update caveat args to use group 1 for ETH transfer
        delegations_[0].caveats[0].args = abi.encode(_createSelectedGroup(1, new bytes[](1)));

        // Execute Bob's UserOp for ETH transfer to Carol
        invokeDelegation_UserOp(users.bob, delegations_, ethExecution_);

        // Validate results
        assertEq(aliceDeleGatorCounter.count(), initialCounterValue_ + 1, "Counter should increment");
        assertEq(
            address(users.alice.deleGator).balance, initialAliceBalance_ - 0.5 ether, "Alice's balance should decrease by 0.5 ether"
        );
        assertEq(
            address(users.carol.deleGator).balance, initialCarolBalance_ + 0.5 ether, "Carol's balance should increase by 0.5 ether"
        );
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(logicalOrWrapperEnforcer));
    }
}
