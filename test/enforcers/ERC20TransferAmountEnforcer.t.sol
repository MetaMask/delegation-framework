// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC20TransferAmountEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    ////////////////////////////// State //////////////////////////////
    ERC20TransferAmountEnforcer public erc20TransferAmountEnforcer;
    BasicERC20 public basicERC20;
    BasicERC20 public invalidERC20;
    ModeCode public mode = ModeLib.encodeSimpleSingle();

    ////////////////////////////// Events //////////////////////////////
    event IncreasedSpentMap(
        address indexed sender, address indexed redeemer, bytes32 indexed delegationHash, uint256 limit, uint256 spent
    );
    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        vm.label(address(erc20TransferAmountEnforcer), "ERC20 Transfer Amount Enforcer");
        basicERC20 = new BasicERC20(address(users.alice.deleGator), "TestToken", "TestToken", 100 ether);
        invalidERC20 = new BasicERC20(address(users.alice.addr), "InvalidToken", "IT", 100 ether);
    }

    //////////////////// Valid cases //////////////////////

    // should SUCCEED to INVOKE transfer BELOW enforcer allowance
    function test_transferSucceedsIfCalledBelowAllowance() public {
        uint256 spendingLimit_ = 1 ether;

        // Create the execution that would be executed
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
        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(erc20TransferAmountEnforcer));
        emit IncreasedSpentMap(address(delegationManager), address(0), delegationHash_, spendingLimit_, 1 ether);
        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", mode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), spendingLimit_);
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to INVOKE transfer ABOVE enforcer allowance
    function test_transferFailsIfCalledAboveAllowance() public {
        uint256 spendingLimit_ = 1 ether;

        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(spendingLimit_ + 1))
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
        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:allowance-exceeded");

        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", mode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
    }

    ////////////////////// Integration //////////////////////

    // should FAIL to INVOKE invalid ERC20-contract
    function test_methodFailsIfInvokesInvalidContract() public {
        uint256 spendingLimit_ = 1 ether;

        // Create the execution_ that would be executed
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
        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:invalid-contract");
        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", mode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
    }

    // should FAIL to INVOKE invalid execution data length
    function test_notAllow_invalidExecutionLength() public {
        uint256 spendingLimit_ = 1 ether;

        // Create the execution_ that would be executed
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
        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:invalid-execution-length");
        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", mode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
    }

    // should FAIL to INVOKE invalid method
    function test_methodFailsIfInvokesInvalidMethod() public {
        uint256 spendingLimit_ = 1 ether;

        // Create the execution_ that would be executed
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
        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:invalid-method");

        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", mode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
    }

    // should FAIL to INVOKE invalid terms length
    function test_methodFailsIfInvokesInvalidTermsLength() public {
        uint256 spendingLimit_ = 1 ether;

        // Create the execution_ that would be executed
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(spendingLimit_))
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
        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20TransferAmountEnforcer:invalid-terms-length");

        erc20TransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", mode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
    }

    // should NOT transfer when max allowance is reached
    function test_transferFailsAboveAllowance() public {
        uint256 spendingLimit_ = 2 ether;
        assertEq(basicERC20.balanceOf(address(users.alice.deleGator)), 100 ether);
        assertEq(basicERC20.balanceOf(address(users.bob.deleGator)), 0);

        // Create the execution_ that would be executed
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

        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Validate Alice balance 99 ether
        assertEq(_getFtBalanceOf(address(users.alice.deleGator)), 99 ether);
        // Validate Bob balance 1 ether
        assertEq(_getFtBalanceOf(address(users.bob.deleGator)), 1 ether);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 1 ether);

        // The delegation can be reused while the allowance is enough
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        // Validate Alice balance 98 ether
        assertEq(_getFtBalanceOf(address(users.alice.deleGator)), 98 ether);
        // Validate Bob balance 1 ether
        assertEq(_getFtBalanceOf(address(users.bob.deleGator)), 2 ether);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), spendingLimit_);

        // If allowance is not enough the transfer should not work
        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        // Validate Balances did not change when transfer are above the allowance
        assertEq(_getFtBalanceOf(address(users.alice.deleGator)), 98 ether);
        assertEq(_getFtBalanceOf(address(users.bob.deleGator)), 2 ether);
        assertEq(erc20TransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), spendingLimit_);
    }

    function _getFtBalanceOf(address _user) internal view returns (uint256) {
        return basicERC20.balanceOf(_user);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(erc20TransferAmountEnforcer));
    }
}
