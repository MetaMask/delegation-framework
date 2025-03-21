// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { CALLTYPE_SINGLE, EXECTYPE_DEFAULT, EXECTYPE_TRY, MODE_DEFAULT, ModePayload, ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";

/**
 * @title ERC20 Transfer Spending Limit Test
 */
contract ERC20TransferAmountEnforcerTest is CaveatEnforcerBaseTest {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;

    // Enforcer contracts
    ERC20TransferAmountEnforcer public erc20TransferAmountEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;

    // Tokens
    BasicERC20 public basicERC20;
    BasicERC20 public invalidERC20;
    // Added mock token for spending limit test
    MockERC20 public mockToken;

    // Test parameter
    uint256 constant TRANSFER_LIMIT = 1000 ether;

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    function setUp() public override {
        super.setUp();
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        vm.label(address(erc20TransferAmountEnforcer), "ERC20TransferAmountEnforcer");
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();

        basicERC20 = new BasicERC20(address(users.alice.deleGator), "TestToken", "TestToken", 100 ether);
        invalidERC20 = new BasicERC20(address(users.alice.addr), "InvalidToken", "IT", 100 ether);

        // Deploy and set up the mock token for integration testing of spending limits
        mockToken = new MockERC20("Mock Token", "MOCK");
        mockToken.mint(address(users.alice.deleGator), 2000 ether);

        // Fund wallets with ETH for gas
        vm.deal(address(users.alice.deleGator), 10 ether);
        vm.deal(address(users.bob.deleGator), 10 ether);

        // Labels
        vm.label(address(allowedTargetsEnforcer), "AllowedTargetsEnforcer");
        vm.label(address(allowedMethodsEnforcer), "AllowedMethodsEnforcer");
        vm.label(address(basicERC20), "BasicERC20");
        vm.label(address(invalidERC20), "InvalidERC20");
        vm.label(address(mockToken), "MockToken");
    }

    //////////////////// Valid cases //////////////////////

    // should SUCCEED to INVOKE transfer BELOW enforcer allowance
    function test_transferSucceedsIfCalledBelowAllowance() public {
        uint256 spendingLimit_ = 1 ether;
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), spendingLimit_)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = abi.encodePacked(address(basicERC20), spendingLimit_);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(erc20TransferAmountEnforcer));
        emit ERC20TransferAmountEnforcer.IncreasedSpentMap(
            address(delegationManager), address(0), delegationHash_, spendingLimit_, 1 ether
        );
        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), spendingLimit_);
    }
    ////////////////////// Invalid cases //////////////////////

    // should FAIL to INVOKE transfer ABOVE enforcer allowance
    function test_transferFailsIfCalledAboveAllowance() public {
        uint256 spendingLimit_ = 1 ether;
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), spendingLimit_ + 1)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = abi.encodePacked(address(basicERC20), spendingLimit_);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:allowance-exceeded");
        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
    }

    ////////////////////// Integration //////////////////////

    // should FAIL to INVOKE invalid ERC20-contract
    function test_methodFailsIfInvokesInvalidContract() public {
        uint256 spendingLimit_ = 1 ether;
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), spendingLimit_)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = abi.encodePacked(address(invalidERC20), spendingLimit_);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:invalid-contract");
        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
    }

    // should FAIL to INVOKE invalid execution data length
    function test_notAllow_invalidExecutionLength() public {
        uint256 spendingLimit_ = 1 ether;
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC20.transferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), spendingLimit_
            )
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = abi.encodePacked(address(basicERC20), spendingLimit_);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:invalid-execution-length");
        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
    }

    // should FAIL to INVOKE invalid method
    function test_methodFailsIfInvokesInvalidMethod() public {
        uint256 spendingLimit_ = 1 ether;
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transferFrom.selector, address(users.bob.deleGator), spendingLimit_)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = abi.encodePacked(address(basicERC20), spendingLimit_);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:invalid-method");
        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
    }

    // should FAIL to INVOKE invalid terms length
    function test_methodFailsIfInvokesInvalidTermsLength() public {
        uint256 spendingLimit_ = 1 ether;
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), spendingLimit_)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = abi.encodePacked(address(basicERC20));
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:invalid-terms-length");
        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
    }

    // should NOT transfer when max allowance is reached
    function test_transferFailsAboveAllowance() public {
        uint256 spendingLimit_ = 2 ether;
        assertEq(basicERC20.balanceOf(address(users.alice.deleGator)), 100 ether);
        assertEq(basicERC20.balanceOf(address(users.bob.deleGator)), 0);

        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 1 ether)
        });
        bytes memory inputTerms_ = abi.encodePacked(address(basicERC20), spendingLimit_);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        assertEq(_getFtBalanceOf(address(users.alice.deleGator)), 99 ether);
        assertEq(_getFtBalanceOf(address(users.bob.deleGator)), 1 ether);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 1 ether);

        // Reuse delegation_ while allowance remains
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertEq(_getFtBalanceOf(address(users.alice.deleGator)), 98 ether);
        assertEq(_getFtBalanceOf(address(users.bob.deleGator)), 2 ether);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), spendingLimit_);

        // Attempt transfer above allowance: balances should remain unchanged
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertEq(_getFtBalanceOf(address(users.alice.deleGator)), 98 ether);
        assertEq(_getFtBalanceOf(address(users.bob.deleGator)), 2 ether);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), spendingLimit_);
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        erc20TransferAmountEnforcer.beforeHook(
            hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0)
        );
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        erc20TransferAmountEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    // Integration test: Failing transfer does not increase spent amount.
    function test_transferFailsButSpentLimitIncreases() public {
        // Use the mock token for this integration test.
        uint256 spendingLimit_ = TRANSFER_LIMIT;
        // Prepare streaming-like terms: token and spending limit.
        bytes memory inputTerms_ = abi.encodePacked(address(mockToken), spendingLimit_);
        Caveat[] memory caveats_ = new Caveat[](3);
        // Allow only the token.
        caveats_[0] =
            Caveat({ enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(mockToken)), args: hex"" });
        // Allow only transfer.
        caveats_[1] =
            Caveat({ enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IERC20.transfer.selector), args: hex"" });
        // Enforce spending limit.
        caveats_[2] = Caveat({ enforcer: address(erc20TransferAmountEnforcer), terms: inputTerms_, args: hex"" });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        uint256 initialSpent_ = erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_);
        assertEq(initialSpent_, 0, "Initial spent should be 0");

        // Get initial token balances for mockToken.
        uint256 aliceInitialBalance_ = mockToken.balanceOf(address(users.alice.deleGator));
        uint256 bobInitialBalance_ = mockToken.balanceOf(address(users.bob.addr));

        // Set transfer amount.
        uint256 amountToTransfer_ = 500 ether;

        // First, successful transfer.
        {
            mockToken.setHaltTransfer(false);
            Execution memory execution_ = Execution({
                target: address(mockToken),
                value: 0,
                callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.addr), amountToTransfer_)
            });
            execute_UserOp(
                users.bob,
                abi.encodeWithSelector(
                    delegationManager.redeemDelegations.selector,
                    createPermissionContexts(delegation_),
                    createModes(singleDefaultMode),
                    createExecutionCallDatas(execution_)
                )
            );
            uint256 aliceBalanceAfterSuccess_ = mockToken.balanceOf(address(users.alice.deleGator));
            uint256 bobBalanceAfterSuccess_ = mockToken.balanceOf(address(users.bob.addr));
            uint256 spentAfterSuccess_ = erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_);
            assertEq(spentAfterSuccess_, amountToTransfer_, "Spent amount should update on successful transfer");
            assertEq(aliceBalanceAfterSuccess_, aliceInitialBalance_ - amountToTransfer_);
            assertEq(bobBalanceAfterSuccess_, bobInitialBalance_ + amountToTransfer_);
        }

        // Then, simulate a failed transfer.
        {
            mockToken.setHaltTransfer(true);
            Execution memory execution_ = Execution({
                target: address(mockToken),
                value: 0,
                callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.addr), amountToTransfer_)
            });
            // Record spent before failure.
            uint256 spentBeforeFailure_ = erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_);
            execute_UserOp(
                users.bob,
                abi.encodeWithSelector(
                    delegationManager.redeemDelegations.selector,
                    createPermissionContexts(delegation_),
                    createModes(singleTryMode),
                    createExecutionCallDatas(execution_)
                )
            );
            uint256 spentAfterFailure_ = erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_);
            assertEq(spentBeforeFailure_, spentAfterFailure_, "Spent amount must be the same as before");

            // In try mode, a failed transfer should not increase the spent amount.
            assertEq(spentAfterFailure_, amountToTransfer_, "Spent amount should not increase after failed transfer");
            // Verify balances remain as after the successful transfer.
            uint256 aliceBalanceAfterFailure_ = mockToken.balanceOf(address(users.alice.deleGator));
            uint256 bobBalanceAfterFailure_ = mockToken.balanceOf(address(users.bob.addr));
            assertEq(aliceBalanceAfterFailure_, aliceInitialBalance_ - amountToTransfer_);
            assertEq(bobBalanceAfterFailure_, bobInitialBalance_ + amountToTransfer_);
        }
    }

    // Helper function: returns basic ERC20 balance.
    function _getFtBalanceOf(address _user) internal view returns (uint256) {
        return basicERC20.balanceOf(_user);
    }

    function createPermissionContexts(Delegation memory del) internal pure returns (bytes[] memory) {
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = del;
        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegations);
        return permissionContexts;
    }

    function createExecutionCallDatas(Execution memory execution) internal pure returns (bytes[] memory) {
        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);
        return executionCallDatas;
    }

    function createModes(ModeCode _mode) internal pure returns (ModeCode[] memory) {
        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = _mode;
        return modes;
    }

    // Override helper from BaseTest.
    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(erc20TransferAmountEnforcer));
    }
}

/// @notice A mock token that allows us to simulate failed transfers.
contract MockERC20 is ERC20 {
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
        if (haltTransfers) {
            return false; // Fail silently
        }
        return super.transfer(to, amount);
    }
}
