// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { BasicCF721 } from "../utils/BasicCF721.t.sol";
import { BasicERC1155 } from "../utils/BasicERC1155.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { LogicalOrWrapperEnforcer } from "../../src/enforcers/LogicalOrWrapperEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { NativeTokenTransferAmountEnforcer } from "../../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { TimestampEnforcer } from "../../src/enforcers/TimestampEnforcer.sol";
import { ArgsEqualityCheckEnforcer } from "../../src/enforcers/ArgsEqualityCheckEnforcer.sol";
import { ERC20BalanceChangeEnforcer } from "../../src/enforcers/ERC20BalanceChangeEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { ERC721BalanceChangeEnforcer } from "../../src/enforcers/ERC721BalanceChangeEnforcer.sol";
import { NativeBalanceChangeEnforcer } from "../../src/enforcers/NativeBalanceChangeEnforcer.sol";
import { ERC20StreamingEnforcer } from "../../src/enforcers/ERC20StreamingEnforcer.sol";
import { ERC20PeriodTransferEnforcer } from "../../src/enforcers/ERC20PeriodTransferEnforcer.sol";
import { ERC721TransferEnforcer } from "../../src/enforcers/ERC721TransferEnforcer.sol";
import { ERC20MultiOperationIncreaseBalanceEnforcer } from "../../src/enforcers/ERC20MultiOperationIncreaseBalanceEnforcer.sol";
import { NativeTokenMultiOperationIncreaseBalanceEnforcer } from
    "../../src/enforcers/NativeTokenMultiOperationIncreaseBalanceEnforcer.sol";
import { ERC721MultiOperationIncreaseBalanceEnforcer } from "../../src/enforcers/ERC721MultiOperationIncreaseBalanceEnforcer.sol";
import { ERC1155MultiOperationIncreaseBalanceEnforcer } from "../../src/enforcers/ERC1155MultiOperationIncreaseBalanceEnforcer.sol";
import { MultiTokenPeriodEnforcer } from "../../src/enforcers/MultiTokenPeriodEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

/**
 * @title LogicalOrWrapperEnforcerTest
 * @notice Comprehensive test suite for LogicalOrWrapperEnforcer
 * @dev Tests the LogicalOrWrapperEnforcer with various caveat enforcers to verify logical OR functionality,
 *      state management, and integration with the delegation framework. Includes both unit tests for core
 *      functionality and comprehensive tests with all major enforcer types.
 */
contract LogicalOrWrapperEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////

    LogicalOrWrapperEnforcer public logicalOrWrapperEnforcer;

    // Basic enforcers for core functionality tests
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    TimestampEnforcer public timestampEnforcer;
    ArgsEqualityCheckEnforcer public argsEqualityCheckEnforcer;
    NativeTokenTransferAmountEnforcer public nativeTokenTransferAmountEnforcer;

    // Comprehensive test enforcers
    ERC20BalanceChangeEnforcer public erc20BalanceChangeEnforcer;
    ERC20TransferAmountEnforcer public erc20TransferAmountEnforcer;
    ERC721BalanceChangeEnforcer public erc721BalanceChangeEnforcer;
    NativeBalanceChangeEnforcer public nativeBalanceChangeEnforcer;
    ERC20StreamingEnforcer public erc20StreamingEnforcer;
    ERC20PeriodTransferEnforcer public erc20PeriodTransferEnforcer;
    ERC721TransferEnforcer public erc721TransferEnforcer;
    ERC20MultiOperationIncreaseBalanceEnforcer public erc20MultiOpIncreaseBalanceEnforcer;
    NativeTokenMultiOperationIncreaseBalanceEnforcer public nativeMultiOpIncreaseBalanceEnforcer;
    ERC721MultiOperationIncreaseBalanceEnforcer public erc721MultiOpIncreaseBalanceEnforcer;
    ERC1155MultiOperationIncreaseBalanceEnforcer public erc1155MultiOpIncreaseBalanceEnforcer;
    MultiTokenPeriodEnforcer public multiTokenPeriodEnforcer;

    // Test tokens and contracts
    BasicERC20 public mockToken;
    BasicERC20 public mockToken2; // Second ERC20 token for multi-enforcer tests
    BasicCF721 public mockNft;
    BasicERC1155 public mockERC1155;
    Counter public mockCounter;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();

        // Deploy LogicalOrWrapperEnforcer
        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer(delegationManager);

        // Deploy basic enforcers for core functionality tests
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        timestampEnforcer = new TimestampEnforcer();
        argsEqualityCheckEnforcer = new ArgsEqualityCheckEnforcer();
        nativeTokenTransferAmountEnforcer = new NativeTokenTransferAmountEnforcer();

        // Deploy comprehensive test enforcers
        erc20BalanceChangeEnforcer = new ERC20BalanceChangeEnforcer();
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        erc721BalanceChangeEnforcer = new ERC721BalanceChangeEnforcer();
        nativeBalanceChangeEnforcer = new NativeBalanceChangeEnforcer();
        erc20StreamingEnforcer = new ERC20StreamingEnforcer();
        erc20PeriodTransferEnforcer = new ERC20PeriodTransferEnforcer();
        erc721TransferEnforcer = new ERC721TransferEnforcer();
        erc20MultiOpIncreaseBalanceEnforcer = new ERC20MultiOperationIncreaseBalanceEnforcer();
        nativeMultiOpIncreaseBalanceEnforcer = new NativeTokenMultiOperationIncreaseBalanceEnforcer();
        erc721MultiOpIncreaseBalanceEnforcer = new ERC721MultiOperationIncreaseBalanceEnforcer();
        erc1155MultiOpIncreaseBalanceEnforcer = new ERC1155MultiOperationIncreaseBalanceEnforcer();
        multiTokenPeriodEnforcer = new MultiTokenPeriodEnforcer();

        // Deploy test contracts
        mockToken = new BasicERC20(address(users.alice.deleGator), "MockToken", "MOCK", 1000 ether);
        mockToken2 = new BasicERC20(address(users.alice.deleGator), "MockToken2", "MOCK2", 1000 ether);
        mockNft = new BasicCF721(address(users.alice.deleGator), "MockNFT", "MNFT", "");
        mockERC1155 = new BasicERC1155(address(users.alice.deleGator), "MockERC1155", "M1155", "");
        mockCounter = new Counter(address(users.alice.deleGator));

        // Set up NFT for testing
        vm.prank(address(users.alice.deleGator));
        mockNft.selfMint(); // Token ID 0

        // Set up ERC1155 for testing
        vm.prank(address(users.alice.deleGator));
        mockERC1155.mint(address(users.alice.deleGator), 1, 100, "");

        // Labels for core enforcers
        vm.label(address(logicalOrWrapperEnforcer), "Logical OR Wrapper Enforcer");
        vm.label(address(allowedMethodsEnforcer), "Allowed Methods Enforcer");
        vm.label(address(timestampEnforcer), "Timestamp Enforcer");
        vm.label(address(argsEqualityCheckEnforcer), "Args Equality Check Enforcer");
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");
        vm.label(address(nativeTokenTransferAmountEnforcer), "Native Token Transfer Amount Enforcer");

        // Labels for comprehensive test enforcers
        vm.label(address(erc20BalanceChangeEnforcer), "ERC20BalanceChangeEnforcer");
        vm.label(address(erc20TransferAmountEnforcer), "ERC20TransferAmountEnforcer");
        vm.label(address(erc721BalanceChangeEnforcer), "ERC721BalanceChangeEnforcer");
        vm.label(address(nativeBalanceChangeEnforcer), "NativeBalanceChangeEnforcer");
        vm.label(address(erc20StreamingEnforcer), "ERC20StreamingEnforcer");
        vm.label(address(erc20PeriodTransferEnforcer), "ERC20PeriodTransferEnforcer");
        vm.label(address(erc721TransferEnforcer), "ERC721TransferEnforcer");
        vm.label(address(mockToken), "MockToken");
        vm.label(address(mockNft), "MockNFT");
        vm.label(address(mockCounter), "MockCounter");
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

    ////////////////////// Comprehensive Enforcer Tests //////////////////////

    /// @notice Tests successful ERC20 balance increase through LogicalOrWrapperEnforcer
    function test_erc20BalanceChange_success() public {
        // Create a group with ERC20 balance change enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20BalanceChangeEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [increase=false, token, recipient, amount=100]
        terms_[0] = abi.encodePacked(false, address(mockToken), address(users.bob.deleGator), uint256(100 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to mint tokens
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(mockToken.mint.selector, address(users.bob.deleGator), 150 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook
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

        // Validate state: balance cache should be locked during execution_
        bytes32 hashKey_ = erc20BalanceChangeEnforcer.getHashKey(
            address(logicalOrWrapperEnforcer), // LogicalOrWrapperEnforcer is the caller
            address(mockToken),
            keccak256("")
        );
        assertTrue(erc20BalanceChangeEnforcer.isLocked(hashKey_), "Balance cache should be locked during execution_");
        // Verify the cached balance is stored
        uint256 cachedBalance_ = erc20BalanceChangeEnforcer.balanceCache(hashKey_);
        assertEq(cachedBalance_, 0, "Initial balance should be 0 for Bob");

        // Simulate the mint
        vm.prank(address(users.alice.deleGator));
        mockToken.mint(address(users.bob.deleGator), 150 ether);

        // Call afterHook - should succeed because balance increased by 150 > 100
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.afterHook(
            abi.encode(groups_),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: balance cache should be cleared after successful afterHook
        bytes32 afterHashKey_ = erc20BalanceChangeEnforcer.getHashKey(
            address(logicalOrWrapperEnforcer), // LogicalOrWrapperEnforcer is the caller
            address(mockToken),
            keccak256("")
        );
        assertFalse(erc20BalanceChangeEnforcer.isLocked(afterHashKey_), "Balance cache should be unlocked after afterHook");
        // Note: balanceCache is not cleared, but isLocked is false, so it can be reused
    }

    /// @notice Tests ERC20 balance change failure through LogicalOrWrapperEnforcer
    function test_erc20BalanceChange_failure() public {
        // Create a group with ERC20 balance change enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20BalanceChangeEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [increase=false, token, recipient, amount=200]
        terms_[0] = abi.encodePacked(false, address(mockToken), address(users.bob.deleGator), uint256(200 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to mint tokens
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(mockToken.mint.selector, address(users.bob.deleGator), 100 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook
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

        // Simulate the mint (only 100 tokens, less than required 200)
        vm.prank(address(users.alice.deleGator));
        mockToken.mint(address(users.bob.deleGator), 100 ether);

        // Call afterHook - should fail because balance only increased by 100 < 200
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20BalanceChangeEnforcer:insufficient-balance-increase");
        logicalOrWrapperEnforcer.afterHook(
            abi.encode(groups_),
            abi.encode(selectedGroup_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests successful ERC20 transfer amount enforcement through LogicalOrWrapperEnforcer
    function test_erc20TransferAmount_success() public {
        // Create a group with ERC20 transfer amount enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20TransferAmountEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, maxAmount=100]
        terms_[0] = abi.encodePacked(address(mockToken), uint256(100 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to transfer 50 tokens (within limit)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 50 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook - should succeed because 50 <= 100
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: spentMap should track the transfer amount
        uint256 spentAmount_ = erc20TransferAmountEnforcer.spentMap(
            address(logicalOrWrapperEnforcer), // LogicalOrWrapperEnforcer is the delegationManager
            keccak256("")
        );
        assertEq(spentAmount_, 50 ether, "SpentMap should track 50 ether spent");

        // Validate remaining allowance
        uint256 remainingAllowance_ = 100 ether - spentAmount_;
        assertEq(remainingAllowance_, 50 ether, "Remaining allowance should be 50 ether");
    }

    /// @notice Tests ERC20 transfer amount enforcement: first use at limit, second use fails (consumed)
    function test_erc20TransferAmount_consumed() public {
        // Create a group with ERC20 transfer amount enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20TransferAmountEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, maxAmount=50]
        terms_[0] = abi.encodePacked(address(mockToken), uint256(50 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to transfer 50 tokens (exact limit)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 50 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // First call beforeHook - should succeed (50 == 50)
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state after first transfer
        uint256 spentAfterFirst_ = erc20TransferAmountEnforcer.spentMap(address(logicalOrWrapperEnforcer), keccak256(""));
        assertEq(spentAfterFirst_, 50 ether, "SpentMap should show 50 ether spent after first transfer");

        // Simulate the transfer (would be done by the actual execution_ in prod)
        vm.prank(address(users.alice.deleGator));
        mockToken.transfer(address(users.bob.deleGator), 50 ether);

        // Second call: try to transfer 1 more token (should fail, allowance consumed)
        Execution memory execution2_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 1 ether)
        });
        bytes memory executionCallData2 = ExecutionLib.encodeSingle(execution2_.target, execution2_.value, execution2_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:allowance-exceeded");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData2,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests ERC20 MultiOperation increase balance enforcement success through LogicalOrWrapperEnforcer
    function test_erc20MultiOpIncreaseBalance_success() public {
        // Create a group with ERC20 MultiOperation increase balance enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20MultiOpIncreaseBalanceEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, recipient, expectedIncrease] - expect balance to increase by 50 ether
        terms_[0] = abi.encodePacked(address(mockToken), address(users.bob.deleGator), uint256(50 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Create execution_: mint 75 ether to Bob (should satisfy the 50 ether requirement)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(mockToken.mint.selector, address(users.bob.deleGator), 75 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Call beforeAllHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: balance tracker should be initialized
        bytes32 hashKey_ = erc20MultiOpIncreaseBalanceEnforcer.getHashKey(
            address(logicalOrWrapperEnforcer), address(mockToken), address(users.bob.deleGator)
        );
        (uint256 balanceBefore, uint256 expectedIncrease, uint256 validationRemaining) =
            erc20MultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, 0, "Initial balance should be 0 for Bob");
        assertEq(expectedIncrease, 50 ether, "Expected increase should be 50 ether");
        assertEq(validationRemaining, 1, "Validation remaining should be 1");

        // Simulate the mint execution_
        vm.prank(address(users.alice.deleGator));
        mockToken.mint(address(users.bob.deleGator), 75 ether);

        // Call afterAllHook - should succeed because balance increased by 75 > 50
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.afterAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: balance tracker should be cleared after successful validation
        (balanceBefore, expectedIncrease, validationRemaining) = erc20MultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, 0, "Balance before should be cleared");
        assertEq(expectedIncrease, 0, "Expected increase should be cleared");
        assertEq(validationRemaining, 0, "Validation remaining should be cleared");
    }

    /// @notice Tests ERC20 MultiOperation increase balance enforcement failure through LogicalOrWrapperEnforcer
    function test_erc20MultiOpIncreaseBalance_failure() public {
        // Create a group with ERC20 MultiOperation increase balance enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20MultiOpIncreaseBalanceEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, recipient, expectedIncrease] - expect balance to increase by 100 ether
        terms_[0] = abi.encodePacked(address(mockToken), address(users.bob.deleGator), uint256(100 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Create execution_ that doesn't increase balance enough
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(mockToken.mint.selector, address(users.bob.deleGator), 50 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Call beforeAllHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Simulate insufficient mint (only 50 ether instead of required 100)
        vm.prank(address(users.alice.deleGator));
        mockToken.mint(address(users.bob.deleGator), 50 ether);

        // Call afterAllHook - should fail because balance only increased by 50 < 100
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase");
        logicalOrWrapperEnforcer.afterAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests successful ERC721 balance increase through LogicalOrWrapperEnforcer
    function test_erc721BalanceChange_success() public {
        // Create a group with ERC721 balance change enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc721BalanceChangeEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [increase=false, token, recipient, amount=1]
        terms_[0] = abi.encodePacked(false, address(mockNft), address(users.bob.deleGator), uint256(1));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to mint NFT
        Execution memory execution_ = Execution({
            target: address(mockNft),
            value: 0,
            callData: abi.encodeWithSelector(mockNft.mint.selector, address(users.bob.deleGator))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Simulate the mint
        vm.prank(address(users.alice.deleGator));
        mockNft.mint(address(users.bob.deleGator));

        // Call afterHook - should succeed because balance increased by 1
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.afterHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: ERC721 balance cache should be unlocked after successful afterHook
        bytes32 hashKey_ = erc721BalanceChangeEnforcer.getHashKey(
            address(logicalOrWrapperEnforcer), // LogicalOrWrapperEnforcer is the caller
            address(mockNft),
            address(users.bob.deleGator),
            keccak256("")
        );
        assertFalse(erc721BalanceChangeEnforcer.isLocked(hashKey_), "ERC721 balance cache should be unlocked after afterHook");
    }

    /// @notice Tests ERC721 balance change failure through LogicalOrWrapperEnforcer
    function test_erc721BalanceChange_failure() public {
        // Create a group with ERC721 balance change enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc721BalanceChangeEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [increase=false, token, recipient, amount=2]
        terms_[0] = abi.encodePacked(false, address(mockNft), address(users.bob.deleGator), uint256(2));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to mint NFT
        Execution memory execution_ = Execution({
            target: address(mockNft),
            value: 0,
            callData: abi.encodeWithSelector(mockNft.mint.selector, address(users.bob.deleGator))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Simulate the mint (only increases by 1, but needs 2)
        vm.prank(address(users.alice.deleGator));
        mockNft.mint(address(users.bob.deleGator));

        // Call afterHook - should fail because balance only increased by 1 < 2
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC721BalanceChangeEnforcer:insufficient-balance-increase");
        logicalOrWrapperEnforcer.afterHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests successful native balance increase through LogicalOrWrapperEnforcer
    function test_nativeBalanceChange_success() public {
        // Create a group with native balance change enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(nativeBalanceChangeEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [increase=false, recipient, amount=1 ether]
        terms_[0] = abi.encodePacked(false, address(users.bob.deleGator), uint256(1 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data (dummy)
        Execution memory execution_ = Execution({ target: address(0), value: 0, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Simulate balance increase (give 2 ether to Bob)
        vm.deal(address(users.bob.deleGator), address(users.bob.deleGator).balance + 2 ether);

        // Call afterHook - should succeed because balance increased by 2 ether > 1 ether
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.afterHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: Native balance cache should be unlocked after successful afterHook
        bytes32 hashKey_ = nativeBalanceChangeEnforcer.getHashKey(
            address(logicalOrWrapperEnforcer), // LogicalOrWrapperEnforcer is the caller
            keccak256("")
        );
        assertFalse(nativeBalanceChangeEnforcer.isLocked(hashKey_), "Native balance cache should be unlocked after afterHook");
    }

    /// @notice Tests native balance change failure through LogicalOrWrapperEnforcer
    function test_nativeBalanceChange_failure() public {
        // Create a group with native balance change enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(nativeBalanceChangeEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [increase=false, recipient, amount=2 ether]
        terms_[0] = abi.encodePacked(false, address(users.bob.deleGator), uint256(2 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data (dummy)
        Execution memory execution_ = Execution({ target: address(0), value: 0, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Simulate balance increase (give only 1 ether to Bob, less than required 2 ether)
        vm.deal(address(users.bob.deleGator), address(users.bob.deleGator).balance + 1 ether);

        // Call afterHook - should fail because balance only increased by 1 ether < 2 ether
        vm.prank(address(delegationManager));
        vm.expectRevert("NativeBalanceChangeEnforcer:insufficient-balance-increase");
        logicalOrWrapperEnforcer.afterHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Integration test for ERC20 MultiOperation increase balance enforcer with delegation flow
    function test_integration_erc20MultiOpIncreaseBalance() public {
        _testERC20MultiOpIntegration();
    }

    /// @notice Tests successful ERC721 transfer enforcement through LogicalOrWrapperEnforcer
    function test_erc721Transfer_success() public {
        // Create a group with ERC721 transfer enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc721TransferEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [contract, tokenId]
        terms_[0] = abi.encodePacked(address(mockNft), uint256(0));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to transfer NFT token 0
        Execution memory execution_ = Execution({
            target: address(mockNft),
            value: 0,
            callData: abi.encodeWithSelector(
                mockNft.transferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), 0
            )
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook - should succeed because transferring correct token
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests ERC721 transfer enforcement failure through LogicalOrWrapperEnforcer
    function test_erc721Transfer_failure() public {
        // Create a group with ERC721 transfer enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc721TransferEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [contract, tokenId=0]
        terms_[0] = abi.encodePacked(address(mockNft), uint256(0));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to transfer NFT token 1 (wrong token ID)
        Execution memory execution_ = Execution({
            target: address(mockNft),
            value: 0,
            callData: abi.encodeWithSelector(
                mockNft.transferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), 1
            )
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook - should fail because transferring wrong token ID
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC721TransferEnforcer:unauthorized-token-id");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests multiple caveat groups_ where first group fails but second succeeds
    function test_multipleGroups_firstFailsSecondSucceeds() public {
        // Create two groups_
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);

        // First group: ERC20 transfer with low limit (will fail)
        address[] memory enforcers1_ = new address[](1);
        enforcers1_[0] = address(erc20TransferAmountEnforcer);
        bytes[] memory terms1_ = new bytes[](1);
        terms1_[0] = abi.encodePacked(address(mockToken), uint256(10 ether)); // low limit
        groups_[0] = _createCaveatGroup(enforcers1_, terms1_);

        // Second group: ERC20 transfer with high limit (will succeed)
        address[] memory enforcers2_ = new address[](1);
        enforcers2_[0] = address(erc20TransferAmountEnforcer);
        bytes[] memory terms2_ = new bytes[](1);
        terms2_[0] = abi.encodePacked(address(mockToken), uint256(100 ether)); // high limit
        groups_[1] = _createCaveatGroup(enforcers2_, terms2_);

        // Create execution_ data to transfer 50 tokens
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 50 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Try first group (should fail)
        bytes[] memory caveatArgs1_ = new bytes[](1);
        caveatArgs1_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup1_ = _createSelectedGroup(0, caveatArgs1_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:allowance-exceeded");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup1_),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Try second group (should succeed)
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

    /// @notice Tests state persistence - shows how enforcer state accumulates across calls
    function test_statePersistence() public {
        // Setup simple transfer enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20TransferAmountEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encodePacked(address(mockToken), uint256(100 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        bytes32 delegationHash_ = keccak256("test-persistence");

        // First transfer: 30 ether
        bytes memory callData_ = abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 30 ether);
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(address(mockToken), 0, callData_);

        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            delegationHash_,
            address(0),
            address(0)
        );

        // Validate state after first call
        assertEq(
            erc20TransferAmountEnforcer.spentMap(address(logicalOrWrapperEnforcer), delegationHash_),
            30 ether,
            "Should have 30 ether spent after first call"
        );

        // Second transfer: 50 ether more (total 80 ether)
        callData_ = abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 50 ether);
        executionCallData_ = ExecutionLib.encodeSingle(address(mockToken), 0, callData_);

        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            delegationHash_,
            address(0),
            address(0)
        );

        // Validate final state
        assertEq(
            erc20TransferAmountEnforcer.spentMap(address(logicalOrWrapperEnforcer), delegationHash_),
            80 ether,
            "Should have 80 ether spent after second call"
        );
    }

    /// @notice Tests successful ERC20 streaming enforcement through LogicalOrWrapperEnforcer
    function test_erc20Streaming_success() public {
        // Create a group with ERC20 streaming enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20StreamingEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, initialAmount=10, maxAmount=100, amountPerSecond=1, startTime=now]
        terms_[0] = abi.encodePacked(
            address(mockToken),
            uint256(10 ether), // initial
            uint256(100 ether), // max
            uint256(1 ether), // per second
            uint256(block.timestamp) // start time
        );

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to transfer 5 tokens (within initial amount)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 5 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook - should succeed because 5 <= 10 (initial amount)
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: streaming allowance should be initialized and track spent amount
        (,,,, uint256 spent_) = erc20StreamingEnforcer.streamingAllowances(
            address(logicalOrWrapperEnforcer), // LogicalOrWrapperEnforcer is the delegationManager
            keccak256("")
        );
        assertEq(spent_, 5 ether, "Spent amount should be 5 ether");
    }

    /// @notice Tests ERC20 streaming enforcement failure through LogicalOrWrapperEnforcer
    function test_erc20Streaming_failure() public {
        // Create a group with ERC20 streaming enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20StreamingEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, initialAmount=5, maxAmount=100, amountPerSecond=1, startTime=now]
        terms_[0] = abi.encodePacked(
            address(mockToken),
            uint256(5 ether), // initial
            uint256(100 ether), // max
            uint256(1 ether), // per second
            uint256(block.timestamp) // start time
        );

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to transfer 10 tokens (exceeds initial amount)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 10 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook - should fail because 10 > 5 (initial amount)
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20StreamingEnforcer:allowance-exceeded");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests successful ERC20 period transfer enforcement through LogicalOrWrapperEnforcer
    function test_erc20PeriodTransfer_success() public {
        // Create a group with ERC20 period transfer enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20PeriodTransferEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, periodAmount=100, periodDuration=1day, startDate=now]
        terms_[0] = abi.encodePacked(
            address(mockToken),
            uint256(100 ether), // period amount
            uint256(1 days), // period duration
            uint256(block.timestamp) // start date
        );

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to transfer 50 tokens (within period limit)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 50 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook - should succeed because 50 <= 100 (period amount)
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: periodic allowance should be initialized and track transferred amount
        (,,, uint256 lastTransferPeriod_, uint256 transferredInCurrentPeriod_) = erc20PeriodTransferEnforcer.periodicAllowances(
            address(logicalOrWrapperEnforcer), // LogicalOrWrapperEnforcer is the delegationManager
            keccak256("")
        );
        assertEq(lastTransferPeriod_, 1, "Last transfer period should be 1 (current period)");
        assertEq(transferredInCurrentPeriod_, 50 ether, "Transferred in current period should be 50 ether");
    }

    /// @notice Tests ERC20 period transfer enforcement failure through LogicalOrWrapperEnforcer
    function test_erc20PeriodTransfer_failure() public {
        // Create a group with ERC20 period transfer enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20PeriodTransferEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, periodAmount=50, periodDuration=1day, startDate=now]
        terms_[0] = abi.encodePacked(
            address(mockToken),
            uint256(50 ether), // period amount
            uint256(1 days), // period duration
            uint256(block.timestamp) // start date
        );

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution_ data to transfer 100 tokens (exceeds period limit)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 100 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook - should fail because 100 > 50 (period amount)
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20PeriodTransferEnforcer:transfer-amount-exceeded");
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests Native Token MultiOperation increase balance enforcement success through LogicalOrWrapperEnforcer
    function test_nativeMultiOpIncreaseBalance_success() public {
        // Create a group with Native MultiOperation increase balance enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(nativeMultiOpIncreaseBalanceEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [recipient, expectedIncrease] - expect balance to increase by 1 ether
        terms_[0] = abi.encodePacked(address(users.bob.deleGator), uint256(1 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        uint256 initialBobBalance = address(users.bob.deleGator).balance;

        // Create execution_ that will increase balance
        Execution memory execution_ = Execution({
            target: address(users.bob.deleGator),
            value: 2 ether, // Send 2 ether (should satisfy the 1 ether requirement)
            callData: hex""
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Call beforeAllHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: balance tracker should be initialized
        bytes32 hashKey_ =
            nativeMultiOpIncreaseBalanceEnforcer.getHashKey(address(logicalOrWrapperEnforcer), address(users.bob.deleGator));
        (uint256 balanceBefore, uint256 expectedIncrease, uint256 validationRemaining) =
            nativeMultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, initialBobBalance, "Initial balance should match Bob's current balance");
        assertEq(expectedIncrease, 1 ether, "Expected increase should be 1 ether");
        assertEq(validationRemaining, 1, "Validation remaining should be 1");

        // Simulate the balance increase (send ETH to Bob)
        vm.deal(address(users.bob.deleGator), initialBobBalance + 2 ether);

        // Call afterAllHook - should succeed because balance increased by 2 > 1
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.afterAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: balance tracker should be cleared after successful validation
        (balanceBefore, expectedIncrease, validationRemaining) = nativeMultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, 0, "Balance before should be cleared");
        assertEq(expectedIncrease, 0, "Expected increase should be cleared");
        assertEq(validationRemaining, 0, "Validation remaining should be cleared");
    }

    /// @notice Tests Native Token MultiOperation increase balance enforcement failure through LogicalOrWrapperEnforcer
    function test_nativeMultiOpIncreaseBalance_failure() public {
        // Create a group with Native MultiOperation increase balance enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(nativeMultiOpIncreaseBalanceEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [recipient, expectedIncrease] - expect balance to increase by 2 ether
        terms_[0] = abi.encodePacked(address(users.bob.deleGator), uint256(2 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        uint256 initialBobBalance = address(users.bob.deleGator).balance;

        // Create execution_ that won't increase balance enough
        Execution memory execution_ = Execution({
            target: address(users.bob.deleGator),
            value: 1 ether, // Only 1 ether but requirement is 2 ether
            callData: hex""
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Call beforeAllHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Simulate insufficient balance increase (only 1 ether instead of required 2)
        vm.deal(address(users.bob.deleGator), initialBobBalance + 1 ether);

        // Call afterAllHook - should fail because balance only increased by 1 < 2
        vm.prank(address(delegationManager));
        vm.expectRevert("NativeTokenMultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase");
        logicalOrWrapperEnforcer.afterAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests complex multi-enforcer group with all enforcers succeeding
    function test_complexMultiEnforcerGroup_allSuccess() public {
        // Create a complex group with multiple enforcers that should all pass
        address[] memory enforcers_ = new address[](3);
        enforcers_[0] = address(erc20TransferAmountEnforcer);
        enforcers_[1] = address(erc20BalanceChangeEnforcer);
        enforcers_[2] = address(erc721BalanceChangeEnforcer);

        bytes[] memory terms_ = new bytes[](3);
        // ERC20 transfer limit: 100 tokens
        terms_[0] = abi.encodePacked(address(mockToken), uint256(100 ether));
        // ERC20 balance increase: at least 50 tokens for Bob
        terms_[1] = abi.encodePacked(false, address(mockToken), address(users.bob.deleGator), uint256(50 ether));
        // ERC721 balance increase: at least 1 NFT for Bob
        terms_[2] = abi.encodePacked(false, address(mockNft), address(users.bob.deleGator), uint256(1));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        // Create execution data to transfer 75 tokens (within limit)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 75 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Create selected group with no arguments for all enforcers
        bytes[] memory caveatArgs_ = new bytes[](3);
        caveatArgs_[0] = hex"";
        caveatArgs_[1] = hex"";
        caveatArgs_[2] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Call beforeHook - first two enforcers should be checked
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Simulate the token transfer (ERC20 balance increase)
        vm.prank(address(users.alice.deleGator));
        mockToken.transfer(address(users.bob.deleGator), 75 ether);

        // Simulate NFT mint (ERC721 balance increase)
        vm.prank(address(users.alice.deleGator));
        mockNft.mint(address(users.bob.deleGator));

        // Call afterHook - all enforcers should pass
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.afterHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: Check spent amount
        assertEq(
            erc20TransferAmountEnforcer.spentMap(address(logicalOrWrapperEnforcer), keccak256("")),
            75 ether,
            "ERC20 transfer enforcer should track 75 ether spent"
        );

        // Verify actual balance changes occurred
        assertEq(mockToken.balanceOf(address(users.bob.deleGator)), 75 ether, "Bob should have 75 ether in tokens");
        assertEq(mockNft.balanceOf(address(users.bob.deleGator)), 1, "Bob should have 1 NFT");
    }

    /// @notice Tests ERC721 MultiOperation increase balance enforcement success through LogicalOrWrapperEnforcer
    function test_erc721MultiOpIncreaseBalance_success() public {
        // Create a group with ERC721 MultiOperation increase balance enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc721MultiOpIncreaseBalanceEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, recipient, expectedIncrease] - expect balance to increase by 1 NFT
        terms_[0] = abi.encodePacked(address(mockNft), address(users.bob.deleGator), uint256(1));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        uint256 initialBobBalance = mockNft.balanceOf(address(users.bob.deleGator));

        // Create execution_ that will mint NFT
        Execution memory execution_ = Execution({
            target: address(mockNft),
            value: 0,
            callData: abi.encodeWithSelector(BasicCF721.mint.selector, address(users.bob.deleGator))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Call beforeAllHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: balance tracker should be initialized
        bytes32 hashKey_ = erc721MultiOpIncreaseBalanceEnforcer.getHashKey(
            address(logicalOrWrapperEnforcer), address(mockNft), address(users.bob.deleGator)
        );
        (uint256 balanceBefore, uint256 expectedIncrease, uint256 validationRemaining) =
            erc721MultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, initialBobBalance, "Initial balance should match Bob's current NFT balance");
        assertEq(expectedIncrease, 1, "Expected increase should be 1");
        assertEq(validationRemaining, 1, "Validation remaining should be 1");

        // Simulate the NFT mint
        vm.prank(address(users.alice.deleGator));
        mockNft.mint(address(users.bob.deleGator));

        // Call afterAllHook - should succeed because balance increased by 1 >= 1
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.afterAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: balance tracker should be cleared after successful validation
        (balanceBefore, expectedIncrease, validationRemaining) = erc721MultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, 0, "Balance before should be cleared");
        assertEq(expectedIncrease, 0, "Expected increase should be cleared");
        assertEq(validationRemaining, 0, "Validation remaining should be cleared");
    }

    /// @notice Tests ERC721 MultiOperation increase balance enforcement failure through LogicalOrWrapperEnforcer
    function test_erc721MultiOpIncreaseBalance_failure() public {
        // Create a group with ERC721 MultiOperation increase balance enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc721MultiOpIncreaseBalanceEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, recipient, expectedIncrease] - expect balance to increase by 2 NFTs
        terms_[0] = abi.encodePacked(address(mockNft), address(users.bob.deleGator), uint256(2));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Create execution_ that will only mint 1 NFT (less than required 2)
        Execution memory execution_ = Execution({
            target: address(mockNft),
            value: 0,
            callData: abi.encodeWithSelector(BasicCF721.mint.selector, address(users.bob.deleGator))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Call beforeAllHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Simulate insufficient NFT increase (only 1 instead of required 2)
        vm.prank(address(users.alice.deleGator));
        mockNft.mint(address(users.bob.deleGator));

        // Call afterAllHook - should fail because balance only increased by 1 < 2
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC721MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase");
        logicalOrWrapperEnforcer.afterAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests ERC1155 MultiOperation increase balance enforcement success through LogicalOrWrapperEnforcer
    function test_erc1155MultiOpIncreaseBalance_success() public {
        // Create a group with ERC1155 MultiOperation increase balance enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc1155MultiOpIncreaseBalanceEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, recipient, tokenId, expectedIncrease] - expect balance to increase by 50 tokens
        terms_[0] = abi.encodePacked(address(mockERC1155), address(users.bob.deleGator), uint256(1), uint256(50));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Create execution_: mint 75 ERC1155 tokens to Bob (should satisfy the 50 token requirement)
        Execution memory execution_ = Execution({
            target: address(mockERC1155),
            value: 0,
            callData: abi.encodeWithSelector(mockERC1155.mint.selector, address(users.bob.deleGator), uint256(1), uint256(75), "")
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Call beforeAllHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: balance tracker should be initialized
        bytes32 hashKey_ = erc1155MultiOpIncreaseBalanceEnforcer.getHashKey(
            address(logicalOrWrapperEnforcer), address(mockERC1155), address(users.bob.deleGator), uint256(1)
        );
        (uint256 balanceBefore, uint256 expectedIncrease, uint256 validationRemaining) =
            erc1155MultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, 0, "Initial balance should be 0");
        assertEq(expectedIncrease, 50, "Expected increase should be 50");
        assertEq(validationRemaining, 1, "Validation remaining should be 1");

        // Simulate the ERC1155 mint
        vm.prank(address(users.alice.deleGator));
        mockERC1155.mint(address(users.bob.deleGator), 1, 75, "");

        // Call afterAllHook - should succeed because balance increased by 75 >= 50
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.afterAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Validate state: balance tracker should be cleared after successful validation
        (balanceBefore, expectedIncrease, validationRemaining) = erc1155MultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, 0, "Balance before should be cleared");
        assertEq(expectedIncrease, 0, "Expected increase should be cleared");
        assertEq(validationRemaining, 0, "Validation remaining should be cleared");
    }

    /// @notice Tests ERC1155 MultiOperation increase balance enforcement failure through LogicalOrWrapperEnforcer
    function test_erc1155MultiOpIncreaseBalance_failure() public {
        // Create a group with ERC1155 MultiOperation increase balance enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc1155MultiOpIncreaseBalanceEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        // Terms: [token, recipient, tokenId, expectedIncrease] - expect balance to increase by 100 tokens
        terms_[0] = abi.encodePacked(address(mockERC1155), address(users.bob.deleGator), uint256(1), uint256(100));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        // Create execution_ that doesn't increase balance enough
        Execution memory execution_ = Execution({
            target: address(mockERC1155),
            value: 0,
            callData: abi.encodeWithSelector(mockERC1155.mint.selector, address(users.bob.deleGator), uint256(1), uint256(50), "")
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Call beforeAllHook
        vm.prank(address(delegationManager));
        logicalOrWrapperEnforcer.beforeAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Simulate insufficient ERC1155 increase (only 50 instead of required 100)
        vm.prank(address(users.alice.deleGator));
        mockERC1155.mint(address(users.bob.deleGator), 1, 50, "");

        // Call afterAllHook - should fail because balance only increased by 50 < 100
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase");
        logicalOrWrapperEnforcer.afterAllHook(
            abi.encode(groups_),
            abi.encode(selectedGroup),
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Integration test for Native MultiOperation increase balance enforcer with delegation flow
    function test_integration_nativeMultiOpIncreaseBalance() public {
        _testNativeMultiOpIntegration();
    }

    /// @notice Integration test for ERC20 Period Transfer enforcer with delegation flow
    function test_integration_erc20PeriodTransfer() public {
        _testERC20PeriodIntegration();
    }

    /// @notice Integration test for ERC20 Streaming enforcer with delegation flow
    function test_integration_erc20Streaming() public {
        _testERC20StreamingIntegration();
    }

    /// @notice Integration test for MultiToken Period enforcer with delegation flow
    function test_integration_multiTokenPeriod() public {
        _testMultiTokenPeriodIntegration();
    }

    /// @notice Integration test combining multiple different enforcers in LogicalOrWrapperEnforcer
    function test_integration_multiEnforcerLogicalOr() public {
        _testMultiEnforcerLogicalOrIntegration();
    }

    ////////////////////// Integration Test Helpers //////////////////////

    function _testERC20MultiOpIntegration() internal {
        // Create delegation with LogicalOrWrapperEnforcer wrapping ERC20 MultiOp enforcer
        Delegation memory delegation = _createDelegationForERC20MultiOp();

        // Execute delegation: mint 100 tokens (requirement: 50 minimum increase)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(mockToken.mint.selector, address(users.bob.deleGator), 100 ether)
        });

        uint256 initialBalance = mockToken.balanceOf(address(users.bob.deleGator));

        // Execute delegation
        invokeDelegation_UserOp(users.bob, _toDelegationArray(delegation), execution_);

        // Validate results
        uint256 finalBalance = mockToken.balanceOf(address(users.bob.deleGator));
        assertEq(finalBalance - initialBalance, 100 ether, "Balance should have increased by 100 ether");

        // Validate enforcer state is cleared (LogicalOrWrapperEnforcer acts as delegationManager for wrapped enforcer)
        bytes32 hashKey_ = erc20MultiOpIncreaseBalanceEnforcer.getHashKey(
            address(logicalOrWrapperEnforcer), address(mockToken), address(users.bob.deleGator)
        );
        (uint256 balanceBefore, uint256 expectedIncrease, uint256 validationRemaining) =
            erc20MultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, 0, "State should be cleared");
        assertEq(expectedIncrease, 0, "State should be cleared");
        assertEq(validationRemaining, 0, "State should be cleared");
    }

    function _testMultiEnforcerLogicalOrIntegration() internal {
        // Test Scenario 1: Native Token Path
        _testNativeTokenPath();

        // Test Scenario 2: ERC20 Token 1 Path
        _testERC20Token1Path();

        // Test Scenario 3: ERC20 Token 2 Path
        _testERC20Token2Path();
    }

    function _testNativeTokenPath() internal {
        // Use group index 0 for Native token enforcer
        Delegation memory delegation = _createDelegationWithGroupIndex(0, 100);

        uint256 initialBalance = address(users.bob.deleGator).balance;

        Execution memory execution_ = Execution({ target: address(users.bob.deleGator), value: 1.5 ether, callData: hex"" });

        invokeDelegation_UserOp(users.bob, _toDelegationArray(delegation), execution_);

        uint256 finalBalance = address(users.bob.deleGator).balance;
        assertGe(finalBalance - initialBalance, 1.4 ether, "Native balance should increase");

        // Validate state cleared
        bytes32 hashKey_ =
            nativeMultiOpIncreaseBalanceEnforcer.getHashKey(address(logicalOrWrapperEnforcer), address(users.bob.deleGator));
        (uint256 balanceBefore,,) = nativeMultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, 0, "State should be cleared");
    }

    function _testERC20Token1Path() internal {
        // Use group index 1 for ERC20 token 1 enforcer
        Delegation memory delegation = _createDelegationWithGroupIndex(1, 101);

        uint256 initialBalance = mockToken.balanceOf(address(users.bob.deleGator));

        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(mockToken.mint.selector, address(users.bob.deleGator), 75 ether)
        });

        invokeDelegation_UserOp(users.bob, _toDelegationArray(delegation), execution_);

        uint256 finalBalance = mockToken.balanceOf(address(users.bob.deleGator));
        assertEq(finalBalance - initialBalance, 75 ether, "Token1 balance should increase by 75 ether");

        // Validate state cleared
        bytes32 hashKey_ = erc20MultiOpIncreaseBalanceEnforcer.getHashKey(
            address(logicalOrWrapperEnforcer), address(mockToken), address(users.bob.deleGator)
        );
        (uint256 balanceBefore,,) = erc20MultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, 0, "State should be cleared");
    }

    function _testERC20Token2Path() internal {
        // Use group index 2 for ERC20 token 2 enforcer
        Delegation memory delegation = _createDelegationWithGroupIndex(2, 102);

        uint256 initialBalance = mockToken2.balanceOf(address(users.bob.deleGator));

        Execution memory execution_ = Execution({
            target: address(mockToken2),
            value: 0,
            callData: abi.encodeWithSelector(mockToken2.mint.selector, address(users.bob.deleGator), 100 ether)
        });

        invokeDelegation_UserOp(users.bob, _toDelegationArray(delegation), execution_);

        uint256 finalBalance = mockToken2.balanceOf(address(users.bob.deleGator));
        assertEq(finalBalance - initialBalance, 100 ether, "Token2 balance should increase by 100 ether");

        // Validate state cleared
        bytes32 hashKey_ = erc20MultiOpIncreaseBalanceEnforcer.getHashKey(
            address(logicalOrWrapperEnforcer), address(mockToken2), address(users.bob.deleGator)
        );
        (uint256 balanceBefore,,) = erc20MultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, 0, "State should be cleared");
    }

    function _testNativeMultiOpIntegration() internal {
        // Create delegation with LogicalOrWrapperEnforcer wrapping Native MultiOp enforcer
        Delegation memory delegation = _createDelegationForNativeMultiOp();

        uint256 initialBobBalance = address(users.bob.deleGator).balance;

        // Execute delegation: send 2 ether (requirement: 1 ether minimum increase)
        Execution memory execution_ = Execution({ target: address(users.bob.deleGator), value: 2 ether, callData: hex"" });

        // Execute delegation
        invokeDelegation_UserOp(users.bob, _toDelegationArray(delegation), execution_);

        // Validate results (account for gas costs by checking minimum increase)
        uint256 finalBobBalance = address(users.bob.deleGator).balance;
        uint256 actualIncrease = finalBobBalance - initialBobBalance;
        assertGe(actualIncrease, 1.9 ether, "Balance should have increased by at least 1.9 ether (accounting for gas)");
        assertLe(actualIncrease, 2 ether, "Balance should not have increased by more than 2 ether");

        // Validate enforcer state is cleared (LogicalOrWrapperEnforcer acts as delegationManager for wrapped enforcer)
        bytes32 hashKey_ =
            nativeMultiOpIncreaseBalanceEnforcer.getHashKey(address(logicalOrWrapperEnforcer), address(users.bob.deleGator));
        (uint256 balanceBefore, uint256 expectedIncrease, uint256 validationRemaining) =
            nativeMultiOpIncreaseBalanceEnforcer.balanceTracker(hashKey_);
        assertEq(balanceBefore, 0, "State should be cleared");
        assertEq(expectedIncrease, 0, "State should be cleared");
        assertEq(validationRemaining, 0, "State should be cleared");
    }

    function _testERC20PeriodIntegration() internal {
        // Create delegation with LogicalOrWrapperEnforcer wrapping ERC20 Period Transfer enforcer
        Delegation memory delegation = _createDelegationForERC20Period();

        // Execute delegation: transfer 30 ether (within 50 ether period limit)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 30 ether)
        });

        uint256 initialBobBalance = mockToken.balanceOf(address(users.bob.deleGator));

        // Execute delegation
        invokeDelegation_UserOp(users.bob, _toDelegationArray(delegation), execution_);

        // Validate results
        uint256 finalBobBalance = mockToken.balanceOf(address(users.bob.deleGator));
        assertEq(finalBobBalance - initialBobBalance, 30 ether, "Bob should receive 30 ether");

        // Validate enforcer state (LogicalOrWrapperEnforcer acts as delegationManager for wrapped enforcer)
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation);
        (,,, uint256 lastTransferPeriod, uint256 transferredInCurrentPeriod) =
            erc20PeriodTransferEnforcer.periodicAllowances(address(logicalOrWrapperEnforcer), delegationHash_);
        assertEq(lastTransferPeriod, 1, "Should be in first period");
        assertEq(transferredInCurrentPeriod, 30 ether, "Should track 30 ether transferred");
    }

    function _testERC20StreamingIntegration() internal {
        // Create delegation with LogicalOrWrapperEnforcer wrapping ERC20 Streaming enforcer
        Delegation memory delegation = _createDelegationForERC20Streaming();

        // Execute delegation: transfer 5 ether (exactly the initial amount available)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 5 ether)
        });

        uint256 initialBobBalance = mockToken.balanceOf(address(users.bob.deleGator));

        // Execute delegation
        invokeDelegation_UserOp(users.bob, _toDelegationArray(delegation), execution_);

        // Validate results
        uint256 finalBobBalance = mockToken.balanceOf(address(users.bob.deleGator));
        assertEq(finalBobBalance - initialBobBalance, 5 ether, "Bob should receive 5 ether");

        // Validate enforcer state (LogicalOrWrapperEnforcer acts as delegationManager for wrapped enforcer)
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation);
        (,,,, uint256 spent) = erc20StreamingEnforcer.streamingAllowances(address(logicalOrWrapperEnforcer), delegationHash_);
        assertEq(spent, 5 ether, "Should track 5 ether spent");
    }

    function _testMultiTokenPeriodIntegration() internal {
        // Create delegation with LogicalOrWrapperEnforcer wrapping MultiToken Period enforcer
        Delegation memory delegation = _createDelegationForMultiTokenPeriod();

        // Execute delegation: transfer 20 ether (within 50 ether period limit for token index 0)
        Execution memory execution_ = Execution({
            target: address(mockToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 20 ether)
        });

        uint256 initialBobBalance = mockToken.balanceOf(address(users.bob.deleGator));

        // Execute delegation
        invokeDelegation_UserOp(users.bob, _toDelegationArray(delegation), execution_);

        // Validate results
        uint256 finalBobBalance = mockToken.balanceOf(address(users.bob.deleGator));
        assertEq(finalBobBalance - initialBobBalance, 20 ether, "Bob should receive 20 ether");

        // Validate enforcer state (LogicalOrWrapperEnforcer acts as delegationManager for wrapped enforcer)
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation);
        bytes memory terms_ = abi.encodePacked(address(mockToken), uint256(50 ether), uint256(1 days), block.timestamp);
        bytes memory args = abi.encode(uint256(0));
        (uint256 available,,) =
            multiTokenPeriodEnforcer.getAvailableAmount(delegationHash_, address(logicalOrWrapperEnforcer), terms_, args);
        assertEq(available, 30 ether, "Should have 30 ether remaining (50 - 20)");
    }

    ////////////////////// Delegation Creation Helpers //////////////////////////////

    function _createDelegationForERC20MultiOp() internal view returns (Delegation memory) {
        // Setup LogicalOrWrapperEnforcer with ERC20 MultiOp enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20MultiOpIncreaseBalanceEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encodePacked(address(mockToken), address(users.bob.deleGator), uint256(50 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] =
            Caveat({ args: abi.encode(selectedGroup), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        return signDelegation(users.alice, delegation);
    }

    function _createDelegationForNativeMultiOp() internal view returns (Delegation memory) {
        // Setup LogicalOrWrapperEnforcer with Native MultiOp enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(nativeMultiOpIncreaseBalanceEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encodePacked(address(users.bob.deleGator), uint256(1 ether));

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] =
            Caveat({ args: abi.encode(selectedGroup), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 1,
            signature: hex""
        });

        return signDelegation(users.alice, delegation);
    }

    function _createDelegationForERC20Period() internal view returns (Delegation memory) {
        // Setup LogicalOrWrapperEnforcer with ERC20 Period Transfer enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20PeriodTransferEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encodePacked(address(mockToken), uint256(50 ether), uint256(1 days), block.timestamp);

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] =
            Caveat({ args: abi.encode(selectedGroup), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 2,
            signature: hex""
        });

        return signDelegation(users.alice, delegation);
    }

    function _createDelegationForERC20Streaming() internal view returns (Delegation memory) {
        // Setup LogicalOrWrapperEnforcer with ERC20 Streaming enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(erc20StreamingEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encodePacked(
            address(mockToken),
            uint256(5 ether), // initial amount
            uint256(100 ether), // max amount
            uint256(1 ether), // amount per second
            block.timestamp // start time
        );

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] =
            Caveat({ args: abi.encode(selectedGroup), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 3,
            signature: hex""
        });

        return signDelegation(users.alice, delegation);
    }

    function _createDelegationForMultiTokenPeriod() internal view returns (Delegation memory) {
        // Setup LogicalOrWrapperEnforcer with MultiToken Period enforcer
        address[] memory enforcers_ = new address[](1);
        enforcers_[0] = address(multiTokenPeriodEnforcer);
        bytes[] memory terms_ = new bytes[](1);
        terms_[0] = abi.encodePacked(address(mockToken), uint256(50 ether), uint256(1 days), block.timestamp);

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](1);
        groups_[0] = _createCaveatGroup(enforcers_, terms_);

        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = abi.encode(uint256(0)); // token index 0
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup = _createSelectedGroup(0, caveatArgs_);

        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] =
            Caveat({ args: abi.encode(selectedGroup), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 4,
            signature: hex""
        });

        return signDelegation(users.alice, delegation);
    }

    function _createMultiEnforcerLogicalOrGroups() internal view returns (LogicalOrWrapperEnforcer.CaveatGroup[] memory) {
        // Setup LogicalOrWrapperEnforcer with 3 different group options (each with a single enforcer)
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](3);

        // Group 0: Native token enforcer
        Caveat[] memory nativeCaveats = new Caveat[](1);
        nativeCaveats[0] = Caveat({
            enforcer: address(nativeMultiOpIncreaseBalanceEnforcer),
            terms: abi.encodePacked(address(users.bob.deleGator), uint256(1 ether)),
            args: hex""
        });
        groups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: nativeCaveats });

        // Group 1: ERC20 token 1 enforcer
        Caveat[] memory token1Caveats = new Caveat[](1);
        token1Caveats[0] = Caveat({
            enforcer: address(erc20MultiOpIncreaseBalanceEnforcer),
            terms: abi.encodePacked(address(mockToken), address(users.bob.deleGator), uint256(50 ether)),
            args: hex""
        });
        groups_[1] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: token1Caveats });

        // Group 2: ERC20 token 2 enforcer
        Caveat[] memory token2Caveats = new Caveat[](1);
        token2Caveats[0] = Caveat({
            enforcer: address(erc20MultiOpIncreaseBalanceEnforcer),
            terms: abi.encodePacked(address(mockToken2), address(users.bob.deleGator), uint256(75 ether)),
            args: hex""
        });
        groups_[2] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: token2Caveats });

        return groups_;
    }

    function _createDelegationWithGroupIndex(uint256 groupIndex, uint256 salt) internal view returns (Delegation memory) {
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = _createMultiEnforcerLogicalOrGroups();

        // All groups_ use the same caveat args structure (single hex"" argument)
        bytes[] memory caveatArgs_ = new bytes[](1);
        caveatArgs_[0] = hex"";

        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup =
            LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: groupIndex, caveatArgs: caveatArgs_ });

        Caveat[] memory mainCaveats = new Caveat[](1);
        mainCaveats[0] =
            Caveat({ args: abi.encode(selectedGroup), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: mainCaveats,
            salt: salt,
            signature: hex""
        });

        return signDelegation(users.alice, delegation);
    }

    function _toDelegationArray(Delegation memory delegation) internal pure returns (Delegation[] memory) {
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;
        return delegations;
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(logicalOrWrapperEnforcer));
    }
}
