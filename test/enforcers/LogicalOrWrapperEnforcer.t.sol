// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

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

contract LogicalOrWrapperEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////

    LogicalOrWrapperEnforcer public logicalOrWrapperEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    TimestampEnforcer public timestampEnforcer;
    ArgsEqualityCheckEnforcer public argsEqualityCheckEnforcer;
    NativeTokenTransferAmountEnforcer public nativeTokenTransferAmountEnforcer;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer(delegationManager);
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        timestampEnforcer = new TimestampEnforcer();
        argsEqualityCheckEnforcer = new ArgsEqualityCheckEnforcer();
        nativeTokenTransferAmountEnforcer = new NativeTokenTransferAmountEnforcer();
        vm.label(address(logicalOrWrapperEnforcer), "Logical OR Wrapper Enforcer");
        vm.label(address(allowedMethodsEnforcer), "Allowed Methods Enforcer");
        vm.label(address(timestampEnforcer), "Timestamp Enforcer");
        vm.label(address(argsEqualityCheckEnforcer), "Args Equality Check Enforcer");
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");
        vm.label(address(nativeTokenTransferAmountEnforcer), "Native Token Transfer Amount Enforcer");
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

    /// @notice Tests that only the delegation manager can call the beforeHook function by verifying that calls from non-delegation
    /// manager addresses revert with the expected error
    function test_onlyDelegationManager() public {
        // Call the hook from a non-delegation manager address
        vm.prank(address(0x1234));
        vm.expectRevert("LogicalOrWrapperEnforcer:only-delegation-manager");
        logicalOrWrapperEnforcer.beforeHook(hex"", hex"", singleDefaultMode, hex"", keccak256(""), address(0), address(0));
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
