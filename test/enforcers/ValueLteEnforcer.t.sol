// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

import "../../src/utils/Types.sol";
import { Action } from "../../src/utils/Types.sol";
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
    function test_allow_valueLte() public {
        // Equal
        bytes memory terms_ = abi.encodePacked(uint256(1 ether));
        Action memory action_ = Action({
            to: address(users.alice.deleGator),
            value: 1 ether,
            data: abi.encodeWithSignature("test_valueLteIsAllowed()")
        });

        // Should not revert
        enforcer.beforeHook(terms_, "", action_, bytes32(0), address(0), address(0));

        // Less than
        action_ = Action({
            to: address(users.alice.deleGator),
            value: 0.1 ether,
            data: abi.encodeWithSignature("test_valueLteIsAllowed()")
        });

        // Should not revert
        enforcer.beforeHook(terms_, "", action_, bytes32(0), address(0), address(0));
    }

    //////////////////////// Errors ////////////////////////

    // Validates that invalid values revert
    function test_notAllow_valueGt() public {
        // Gt
        bytes memory terms_ = abi.encodePacked(uint256(1 ether));
        Action memory action_ = Action({
            to: address(users.alice.deleGator),
            value: 2 ether,
            data: abi.encodeWithSignature("test_valueLteIsAllowed()")
        });

        // Should not revert
        vm.expectRevert(bytes("ValueLteEnforcer:value-too-high"));
        enforcer.beforeHook(terms_, "", action_, bytes32(0), address(0), address(0));
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

    //////////////////////  Integration  //////////////////////

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
