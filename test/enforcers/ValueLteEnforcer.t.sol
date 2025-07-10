// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import "../../src/utils/Types.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ValueLteEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ValueLteEnforcer public enforcer;
    BasicERC20 public token;
    address delegator;

    ////////////////////////////// Events //////////////////////////////

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        enforcer = new ValueLteEnforcer();
        vm.label(address(enforcer), "Value LTE Enforcer");
    }

    ////////////////////// Basic Functionality //////////////////////

    // Validates the terms get decoded correctly
    function test_allow_decodeTerms() public {
        bytes memory terms_;
        uint256 amount_;

        // 0
        terms_ = abi.encodePacked(uint256(0));
        amount_ = enforcer.getTermsInfo(terms_);
        assertEq(amount_, 0);

        // 1 ether
        terms_ = abi.encodePacked(uint256(1 ether));
        amount_ = enforcer.getTermsInfo(terms_);
        assertEq(amount_, uint256(1 ether));

        // Max
        terms_ = abi.encodePacked(type(uint256).max);
        amount_ = enforcer.getTermsInfo(terms_);
        assertEq(amount_, type(uint256).max);
    }

    // Validates that valid values don't revert
    function test_allow_valueLte() public view {
        // Equal
        bytes memory terms_ = abi.encode(uint256(1 ether));
        Execution memory execution_ = Execution({
            target: address(users.alice.deleGator),
            value: 1 ether,
            callData: abi.encodeWithSignature("test_valueLteIsAllowed()")
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Should not revert
        enforcer.beforeHook(terms_, "", singleDefaultMode, executionCallData_, bytes32(0), address(0), address(0));

        // Less than
        execution_ = Execution({
            target: address(users.alice.deleGator),
            value: 0.1 ether,
            callData: abi.encodeWithSignature("test_valueLteIsAllowed()")
        });
        executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Should not revert
        enforcer.beforeHook(terms_, "", singleDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    //////////////////////// Errors ////////////////////////

    // Validates that invalid values revert
    function test_notAllow_valueGt() public {
        // Gt
        bytes memory terms_ = abi.encodePacked(uint256(1 ether));
        Execution memory execution_ = Execution({
            target: address(users.alice.deleGator),
            value: 2 ether,
            callData: abi.encodeWithSignature("test_valueLteIsAllowed()")
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Should not revert
        vm.expectRevert(bytes("ValueLteEnforcer:value-too-high"));
        enforcer.beforeHook(terms_, "", singleDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // Validates the terms are well formed
    function test_notAllow_decodeTerms() public {
        bytes memory terms_;

        // Too small
        terms_ = abi.encodePacked(uint8(100), address(token));
        vm.expectRevert(bytes("ValueLteEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large
        terms_ = abi.encodePacked(uint256(100), uint256(100));
        vm.expectRevert(bytes("ValueLteEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        enforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
