// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC20RoyaltyEnforcer } from "../../src/enforcers/ERC20RoyaltyEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

/**
 * @title ERC20RoyaltyEnforcerTest
 * @notice Test suite for ERC20RoyaltyEnforcer contract
 * @dev Tests royalty distribution functionality for ERC20 token delegations
 */
contract ERC20RoyaltyEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC20RoyaltyEnforcer public enforcer;
    BasicERC20 public token;
    ModeCode public mode = ModeLib.encodeSimpleSingle();

    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    ////////////////////////////// Set up //////////////////////////////

    /// @notice Deploy contracts and set up test environment
    function setUp() public override {
        super.setUp();
        enforcer = new ERC20RoyaltyEnforcer();
        token = new BasicERC20(address(this), "TEST", "TEST", 0);
        vm.label(address(enforcer), "ERC20 Royalty Enforcer");
        vm.label(address(token), "Test Token");
    }

    //////////////////// Valid cases //////////////////////

    /// @notice Validates that terms and args are decoded correctly
    /// @dev Tests the decoding of royalty recipients, amounts, and redeemer address
    function test_decodedTheTerms() public {
        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));

        (ERC20RoyaltyEnforcer.RoyaltyInfo[] memory royalties) = enforcer.getTermsInfo(terms);

        assertEq(royalties.length, 2);
        assertEq(royalties[0].recipient, address(users.carol.deleGator));
        assertEq(royalties[0].amount, 200);
        assertEq(royalties[1].recipient, address(users.dave.deleGator));
        assertEq(royalties[1].amount, 100);
    }

    /// @notice Tests a complete valid royalty execution flow
    /// @dev Verifies token transfers and final balances for all parties
    function test_validRoyaltyExecution() public {
        uint256 initialAmount = 1000;

        token.mint(address(users.alice.deleGator), initialAmount);

        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));
        bytes memory args = hex"";

        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(enforcer), initialAmount)
        });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        vm.startPrank(address(delegationManager));
        enforcer.beforeHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );

        vm.startPrank(address(users.alice.deleGator));
        token.transfer(address(enforcer), initialAmount);

        vm.startPrank(address(delegationManager));
        enforcer.afterHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );

        assertEq(token.balanceOf(address(users.carol.deleGator)), 200);
        assertEq(token.balanceOf(address(users.dave.deleGator)), 100);
        assertEq(token.balanceOf(address(users.bob.deleGator)), 700);
    }

    /// @notice Tests the enforcer's locking mechanism
    /// @dev Verifies lock/unlock behavior and revert on locked state
    function test_enforcerLocking() public {
        uint256 initialAmount = 1000;

        token.mint(address(users.alice.deleGator), initialAmount);

        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));
        bytes memory args = hex"";

        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(enforcer), initialAmount)
        });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        bytes32 delegationHash_ = keccak256("test");

        vm.startPrank(address(delegationManager));
        enforcer.beforeHook(
            terms, args, mode, executionCallData, delegationHash_, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        bytes32 hashKey_ = keccak256(abi.encode(address(users.alice.deleGator), address(token), delegationHash_));
        assertTrue(enforcer.isLocked(hashKey_));

        vm.expectRevert("ERC20RoyaltyEnforcer:enforcer-is-locked");
        enforcer.beforeHook(
            terms, args, mode, executionCallData, delegationHash_, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        vm.startPrank(address(users.alice.deleGator));
        token.transfer(address(enforcer), initialAmount);

        vm.startPrank(address(delegationManager));
        enforcer.afterHook(
            terms, args, mode, executionCallData, delegationHash_, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        assertFalse(enforcer.isLocked(hashKey_));
    }

    /// @notice Tests balance caching functionality
    /// @dev Verifies balances are properly cached in beforeHook
    function test_balanceCaching() public {
        uint256 initialAmount = 1000;

        token.mint(address(users.alice.deleGator), initialAmount);

        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));
        bytes memory args = hex"";

        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(enforcer), initialAmount)
        });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        bytes32 delegationHash = keccak256("test");
        bytes32 hashKey = keccak256(abi.encode(address(users.alice.deleGator), address(token), delegationHash));

        vm.startPrank(address(delegationManager));
        enforcer.beforeHook(
            terms, args, mode, executionCallData, delegationHash, address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Verify cached balances
        assertEq(enforcer.delegatorBalanceCache(hashKey), initialAmount, "Delegator balance not cached correctly");
        assertEq(enforcer.enforcerBalanceCache(hashKey), 0, "Enforcer balance not cached correctly");
    }

    //////////////////// Invalid cases //////////////////////

    /// @notice Tests reversion on invalid execution mode
    /// @dev Should revert when using batch mode instead of single
    function test_revertOnInvalidMode() public {
        ModeCode invalidMode = ModeLib.encodeSimpleBatch();
        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200));
        bytes memory args = abi.encode(address(users.eve.deleGator));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        enforcer.beforeHook(
            terms, args, invalidMode, hex"", bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );
    }

    /// @notice Tests reversion on invalid terms length
    /// @dev Terms must be multiple of 64 bytes (address + uint256)
    function test_revertOnInvalidTermsLength() public {
        bytes memory invalidTerms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator));

        vm.expectRevert("ERC20RoyaltyEnforcer:invalid-terms-length");
        enforcer.getTermsInfo(invalidTerms);
    }

    /// @notice Tests reversion on empty royalties array
    /// @dev Should revert when no royalty recipients are specified
    function test_revertOnEmptyRoyalties() public {
        uint256 initialAmount = 1000;
        token.mint(address(users.alice.deleGator), initialAmount);

        // Create empty terms (no royalty recipients)
        bytes memory terms = bytes("");
        bytes memory args = hex"";

        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(enforcer), initialAmount)
        });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("ERC20RoyaltyEnforcer:invalid-royalties-length");
        enforcer.beforeHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );
    }

    /// @notice Tests reversion on invalid transfer recipient
    /// @dev Should revert when transfer recipient is not the enforcer
    function test_revertOnInvalidRecipient() public {
        uint256 initialAmount = 1000;
        token.mint(address(users.alice.deleGator), initialAmount);

        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));
        bytes memory args = abi.encode(address(users.eve.deleGator));

        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.frank.deleGator), initialAmount) // Wrong
                // recipient
         });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("ERC20RoyaltyEnforcer:invalid-recipient");
        enforcer.beforeHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );
    }

    /// @notice Tests reversion on invalid redeemer address
    /// @dev Should revert when redeemer is zero address
    function test_revertOnInvalidRedeemer() public {
        uint256 initialAmount = 1000;
        token.mint(address(users.alice.deleGator), initialAmount);

        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200));
        bytes memory args = hex"";

        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(enforcer), initialAmount)
        });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("ERC20RoyaltyEnforcer:invalid-redeemer");
        enforcer.beforeHook(
            terms,
            args,
            mode,
            executionCallData,
            bytes32(0),
            address(users.alice.deleGator),
            address(0) // Zero address redeemer
        );
    }

    /// @notice Tests reversion on insufficient transfer amount
    /// @dev Should revert when transfer amount is less than total royalties
    function test_revertOnInsufficientAmount() public {
        uint256 initialAmount = 200; // Less than total royalties (300)
        token.mint(address(users.alice.deleGator), initialAmount);

        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));
        bytes memory args = hex"";

        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(enforcer), initialAmount)
        });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("ERC20RoyaltyEnforcer:insufficient-amount");
        enforcer.beforeHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );
    }

    /// @notice Tests reversion on invalid transfer execution
    /// @dev Should revert when token transfer fails in afterHook
    function test_revertOnInvalidTransfer() public {
        uint256 initialAmount = 300;

        token.mint(address(users.alice.deleGator), initialAmount);

        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));
        bytes memory args = hex"";

        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(enforcer), initialAmount)
        });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        vm.startPrank(address(delegationManager));
        enforcer.beforeHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );

        vm.startPrank(address(users.alice.deleGator));
        token.transfer(address(enforcer), initialAmount - 100); // transfer less than total royalties (trying to invoke a failed
            // transfer)

        vm.startPrank(address(delegationManager));
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientBalance.selector, address(enforcer), 0, 100));
        enforcer.afterHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );
    }

    /// @notice Tests reversion on invalid selector
    /// @dev Should revert when using non-transfer selector
    function test_revertOnInvalidSelector() public {
        uint256 initialAmount = 1000;

        token.mint(address(users.alice.deleGator), initialAmount);

        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));
        bytes memory args = hex"";

        // Use approve selector instead of transfer
        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(enforcer), initialAmount)
        });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("ERC20RoyaltyEnforcer:invalid-selector");
        enforcer.beforeHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );
    }

    /// @notice Tests reversion on non-zero value
    /// @dev Should revert when execution includes ETH value
    function test_revertOnNonZeroValue() public {
        uint256 initialAmount = 1000;

        token.mint(address(users.alice.deleGator), initialAmount);

        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));
        bytes memory args = hex"";

        Execution memory execution = Execution({
            target: address(token),
            value: 1 ether, // Non-zero value
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(enforcer), initialAmount)
        });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("ERC20RoyaltyEnforcer:non-zero-value");
        enforcer.beforeHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );
    }

    /// @notice Tests reversion on invalid calldata length
    /// @dev Should revert when calldata is too short
    function test_revertOnInvalidCalldataLength() public {
        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));
        bytes memory args = hex"";

        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: hex"12" // Invalid short calldata
         });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("ERC20RoyaltyEnforcer:invalid-calldata-length");
        enforcer.beforeHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );
    }

    // Test failed transfer to royalty recipient
    function test_revertOnRoyaltyTransferFail() public {
        uint256 initialAmount = 1000;
        token.mint(address(users.alice.deleGator), initialAmount);

        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));
        bytes memory args = abi.encode(address(users.eve.deleGator));

        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(enforcer), initialAmount)
        });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        // Make transfer fail
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(false));

        vm.startPrank(address(delegationManager));
        enforcer.beforeHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );

        vm.expectRevert("ERC20RoyaltyEnforcer:invalid-transfer");
        enforcer.afterHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );
    }

    // Test zero remaining balance
    function test_noRemainingBalance() public {
        uint256 initialAmount = 300; // Exact royalty amount
        token.mint(address(users.alice.deleGator), initialAmount);

        bytes memory terms = abi.encode(address(users.carol.deleGator), uint256(200), address(users.dave.deleGator), uint256(100));
        bytes memory args = abi.encode(address(users.eve.deleGator));

        Execution memory execution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(enforcer), initialAmount)
        });
        bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

        vm.startPrank(address(delegationManager));
        enforcer.beforeHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );
        vm.startPrank(address(users.alice.deleGator));
        token.transfer(address(enforcer), initialAmount);
        enforcer.afterHook(
            terms, args, mode, executionCallData, bytes32(0), address(users.alice.deleGator), address(users.bob.deleGator)
        );

        // Verify no remaining balance transfer occurred
        assertEq(token.balanceOf(address(users.eve.deleGator)), 0);
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /// @notice Returns the enforcer instance for base test contract
    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
