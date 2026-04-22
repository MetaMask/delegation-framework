// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { ERC20AllowanceRevocationEnforcer } from "../../src/enforcers/ERC20AllowanceRevocationEnforcer.sol";

/**
 * @title ERC20AllowanceRevocationEnforcer Test
 */
contract ERC20AllowanceRevocationEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////

    ERC20AllowanceRevocationEnforcer public enforcer;
    BasicERC20 public token;

    address public delegator;
    address public spender;

    ////////////////////////////// Set up //////////////////////////////

    function setUp() public override {
        super.setUp();
        enforcer = new ERC20AllowanceRevocationEnforcer();
        vm.label(address(enforcer), "ERC20AllowanceRevocationEnforcer");

        delegator = address(users.alice.deleGator);
        spender = address(users.bob.deleGator);

        token = new BasicERC20(delegator, "TestToken", "TT", 100 ether);
        vm.label(address(token), "BasicERC20");

        vm.prank(delegator);
        token.approve(spender, 42 ether);
    }

    ////////////////////////////// Helpers //////////////////////////////

    function _approveCallData(address _spender, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.approve.selector, _spender, _amount);
    }

    function _encodeSingle(address _target, uint256 _value, bytes memory _callData) internal pure returns (bytes memory) {
        return ExecutionLib.encodeSingle(_target, _value, _callData);
    }

    function _callBeforeHook(bytes memory _executionCallData) internal {
        vm.prank(address(delegationManager));
        enforcer.beforeHook(hex"", hex"", singleDefaultMode, _executionCallData, bytes32(0), delegator, address(0));
    }

    ////////////////////////////// Valid cases //////////////////////////////

    // should SUCCEED when revoking an existing allowance
    function test_revokeSucceedsForExistingAllowance() public {
        bytes memory executionCallData_ = _encodeSingle(address(token), 0, _approveCallData(spender, 0));
        _callBeforeHook(executionCallData_);
    }

    // should SUCCEED for any non-zero allowance amount (1 wei)
    function test_revokeSucceedsForMinimalAllowance() public {
        address otherSpender_ = address(users.carol.deleGator);
        vm.prank(delegator);
        token.approve(otherSpender_, 1);

        bytes memory executionCallData_ = _encodeSingle(address(token), 0, _approveCallData(otherSpender_, 0));
        _callBeforeHook(executionCallData_);
    }

    ////////////////////////////// Invalid cases //////////////////////////////

    // should FAIL when the execution transfers native value
    function test_revertOnNonZeroValue() public {
        bytes memory executionCallData_ = _encodeSingle(address(token), 1, _approveCallData(spender, 0));
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20AllowanceRevocationEnforcer:invalid-value");
        enforcer.beforeHook(hex"", hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    // should FAIL when the calldata length differs from approve(address,uint256)
    function test_revertOnInvalidExecutionLength() public {
        bytes memory shortCallData_ = abi.encodePacked(IERC20.approve.selector, bytes32(uint256(uint160(spender))));
        bytes memory executionCallData_ = _encodeSingle(address(token), 0, shortCallData_);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20AllowanceRevocationEnforcer:invalid-execution-length");
        enforcer.beforeHook(hex"", hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    // should FAIL when the calldata length is longer than expected (extra trailing bytes)
    function test_revertOnInvalidExecutionLengthTooLong() public {
        bytes memory longCallData_ = abi.encodePacked(_approveCallData(spender, 0), bytes1(0x00));
        bytes memory executionCallData_ = _encodeSingle(address(token), 0, longCallData_);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20AllowanceRevocationEnforcer:invalid-execution-length");
        enforcer.beforeHook(hex"", hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    // should FAIL when the selector is not approve(address,uint256)
    function test_revertOnInvalidMethod() public {
        bytes memory wrongMethodCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, spender, uint256(0));
        bytes memory executionCallData_ = _encodeSingle(address(token), 0, wrongMethodCallData_);
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20AllowanceRevocationEnforcer:invalid-method");
        enforcer.beforeHook(hex"", hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    // should FAIL when the approved amount is non-zero (i.e. not a revocation)
    function test_revertOnNonZeroAmount() public {
        bytes memory executionCallData_ = _encodeSingle(address(token), 0, _approveCallData(spender, 1));
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20AllowanceRevocationEnforcer:non-zero-amount");
        enforcer.beforeHook(hex"", hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    // should FAIL when the current allowance is already zero (nothing to revoke)
    function test_revertWhenNoAllowanceToRevoke() public {
        address otherSpender_ = address(users.dave.deleGator);
        assertEq(token.allowance(delegator, otherSpender_), 0);

        bytes memory executionCallData_ = _encodeSingle(address(token), 0, _approveCallData(otherSpender_, 0));
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20AllowanceRevocationEnforcer:no-allowance-to-revoke");
        enforcer.beforeHook(hex"", hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    // should FAIL when the execution target does not implement allowance(address,address)
    function test_revertWhenAllowanceCallFails() public {
        // A contract address with code but no allowance() implementation — the enforcer contract itself.
        address noAllowanceTarget_ = address(enforcer);
        bytes memory executionCallData_ = _encodeSingle(noAllowanceTarget_, 0, _approveCallData(spender, 0));
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20AllowanceRevocationEnforcer:allowance-call-failed");
        enforcer.beforeHook(hex"", hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    // should FAIL when the execution target is an EOA (no code)
    function test_revertWhenTargetHasNoCode() public {
        address eoa_ = address(0xBEEF);
        require(eoa_.code.length == 0);
        bytes memory executionCallData_ = _encodeSingle(eoa_, 0, _approveCallData(spender, 0));
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC20AllowanceRevocationEnforcer:allowance-call-failed");
        enforcer.beforeHook(hex"", hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    // should FAIL with invalid call type mode (batch instead of single)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        enforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    // should FAIL with invalid execution mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), delegator, address(0));
    }

    ////////////////////////////// Integration //////////////////////////////

    // should revoke an existing allowance through the full delegation redemption path
    function test_revokeIntegration() public {
        assertEq(token.allowance(delegator, spender), 42 ether);

        Execution memory execution_ =
            Execution({ target: address(token), value: 0, callData: _approveCallData(spender, 0) });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: hex"" });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        assertEq(token.allowance(delegator, spender), 0);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
