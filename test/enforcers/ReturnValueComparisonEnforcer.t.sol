// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeCode } from "../../src/utils/Types.sol";
import { ReturnValueComparisonEnforcer, ComparisonOperator, ValueType } from "../../src/enforcers/ReturnValueComparisonEnforcer.sol";

contract DummyReader {
    uint256 public value;
    int256 public ivalue;
    uint128 public u128value;
    int128 public i128value;
    bool public bvalue;

    function set(uint256 v) external {
        value = v;
    }

    function seti(int256 v) external {
        ivalue = v;
    }

    function setu128(uint128 v) external {
        u128value = v;
    }

    function seti128(int128 v) external {
        i128value = v;
    }

    function setb(bool v) external {
        bvalue = v;
    }

    function read() external view returns (uint256) {
        return value;
    }

    function readi() external view returns (int256) {
        return ivalue;
    }

    function readu128() external view returns (uint128) {
        return u128value;
    }

    function readi128() external view returns (int128) {
        return i128value;
    }

    function readb() external view returns (bool) {
        return bvalue;
    }
}

contract ReturnValueComparisonEnforcerTest is Test {
    ReturnValueComparisonEnforcer public enforcer;
    DummyReader public reader;

    function setUp() public {
        enforcer = new ReturnValueComparisonEnforcer();
        reader = new DummyReader();
    }

    function testEQ_uint256() public {
        reader.set(42);
        bytes memory callData = abi.encodeWithSignature("read()");
        bytes memory terms =
            abi.encode(address(reader), callData, ComparisonOperator.EQ, ValueType.UINT256, abi.encode(uint256(42)));
        enforcer.beforeHook(terms, "", ModeCode.wrap(bytes32(0)), "", bytes32(0), address(0), address(0));
    }

    function testNEQ_uint256() public {
        reader.set(43);
        bytes memory callData = abi.encodeWithSignature("read()");
        bytes memory terms =
            abi.encode(address(reader), callData, ComparisonOperator.NEQ, ValueType.UINT256, abi.encode(uint256(42)));
        enforcer.beforeHook(terms, "", ModeCode.wrap(bytes32(0)), "", bytes32(0), address(0), address(0));
    }

    function testGTE_uint256() public {
        reader.set(100);
        bytes memory callData = abi.encodeWithSignature("read()");
        bytes memory terms =
            abi.encode(address(reader), callData, ComparisonOperator.GTE, ValueType.UINT256, abi.encode(uint256(42)));
        enforcer.beforeHook(terms, "", ModeCode.wrap(bytes32(0)), "", bytes32(0), address(0), address(0));
    }

    function testLTE_uint256() public {
        reader.set(10);
        bytes memory callData = abi.encodeWithSignature("read()");
        bytes memory terms =
            abi.encode(address(reader), callData, ComparisonOperator.LTE, ValueType.UINT256, abi.encode(uint256(42)));
        enforcer.beforeHook(terms, "", ModeCode.wrap(bytes32(0)), "", bytes32(0), address(0), address(0));
    }

    function testEQ_bool() public {
        reader.setb(true);
        bytes memory callData = abi.encodeWithSignature("readb()");
        bytes memory terms = abi.encode(address(reader), callData, ComparisonOperator.EQ, ValueType.BOOL, abi.encode(true));
        enforcer.beforeHook(terms, "", ModeCode.wrap(bytes32(0)), "", bytes32(0), address(0), address(0));
    }

    function testGTE_int256() public {
        reader.seti(-1);
        bytes memory callData = abi.encodeWithSignature("readi()");
        bytes memory terms = abi.encode(address(reader), callData, ComparisonOperator.GTE, ValueType.INT256, abi.encode(int256(-2)));
        enforcer.beforeHook(terms, "", ModeCode.wrap(bytes32(0)), "", bytes32(0), address(0), address(0));
    }

    function testLTE_int256() public {
        reader.seti(-5);
        bytes memory callData = abi.encodeWithSignature("readi()");
        bytes memory terms = abi.encode(address(reader), callData, ComparisonOperator.LTE, ValueType.INT256, abi.encode(int256(-2)));
        enforcer.beforeHook(terms, "", ModeCode.wrap(bytes32(0)), "", bytes32(0), address(0), address(0));
    }

    function testEQ_uint128() public {
        reader.setu128(123);
        bytes memory callData = abi.encodeWithSignature("readu128()");
        bytes memory terms =
            abi.encode(address(reader), callData, ComparisonOperator.EQ, ValueType.UINT128, abi.encode(uint128(123)));
        enforcer.beforeHook(terms, "", ModeCode.wrap(bytes32(0)), "", bytes32(0), address(0), address(0));
    }

    function testGTE_int128() public {
        reader.seti128(-10);
        bytes memory callData = abi.encodeWithSignature("readi128()");
        bytes memory terms =
            abi.encode(address(reader), callData, ComparisonOperator.GTE, ValueType.INT128, abi.encode(int128(-20)));
        enforcer.beforeHook(terms, "", ModeCode.wrap(bytes32(0)), "", bytes32(0), address(0), address(0));
    }

    function test_RevertWhen_NEQ_uint256_shouldRevert() public {
        reader.set(42);
        bytes memory callData = abi.encodeWithSignature("read()");
        bytes memory terms =
            abi.encode(address(reader), callData, ComparisonOperator.NEQ, ValueType.UINT256, abi.encode(uint256(42)));
        vm.expectRevert("equal");
        enforcer.beforeHook(terms, "", ModeCode.wrap(bytes32(0)), "", bytes32(0), address(0), address(0));
    }

    function test_RevertWhen_GTE_uint256_shouldRevert() public {
        reader.set(10);
        bytes memory callData = abi.encodeWithSignature("read()");
        bytes memory terms =
            abi.encode(address(reader), callData, ComparisonOperator.GTE, ValueType.UINT256, abi.encode(uint256(42)));
        vm.expectRevert(bytes("lt"));
        enforcer.beforeHook(terms, "", ModeCode.wrap(bytes32(0)), "", bytes32(0), address(0), address(0));
    }
}
