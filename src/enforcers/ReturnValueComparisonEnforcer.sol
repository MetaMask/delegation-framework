// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

enum ComparisonOperator {
    EQ, // Equal (bytes32 hash equality)
    NEQ, // Not Equal (bytes32 hash inequality)
    GTE, // Greater Than or Equal (numeric, supports uint/int/bool)
    LTE // Less Than or Equal (numeric, supports uint/int/bool)

}

enum ValueType {
    UINT256,
    INT256,
    UINT128,
    INT128,
    BOOL
}

/**
 * @title ReturnValueComparisonEnforcer
 * @notice Enforces that the return value of a staticcall matches a comparison against a specified term.
 * @dev The `_terms` parameter encodes the target, calldata, comparison operator, and value to compare against.
 *      For EQ/NEQ, compares keccak256 hashes of the return and expected value (works for structs, tuples, etc).
 *      For GTE/LTE, supports uint256, int256, uint128, int128, and bool (by type length).
 *      Example use case: Only allow execution if a collateral ratio is below a threshold.
 *
 * _terms encoding: abi.encode(target (address), callData (bytes), operator (uint8), expectedValue (bytes))
 */
contract ReturnValueComparisonEnforcer is CaveatEnforcer {
    /**
     * @notice Checks that the return value of a staticcall matches the comparison.
     * @dev Expects _terms = abi.encode(target, callData, operator, expectedValue)
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        view
        override
        onlyDefaultExecutionMode(_mode)
    {
        (address target, bytes memory callData, ComparisonOperator op, ValueType typeTag, bytes memory expected) =
            abi.decode(_terms, (address, bytes, ComparisonOperator, ValueType, bytes));

        (bool success, bytes memory result) = target.staticcall(callData);
        require(success, "ReturnValueComparisonEnforcer:staticcall-failed");

        if (op == ComparisonOperator.EQ) {
            require(keccak256(result) == keccak256(expected), "not-equal");
        } else if (op == ComparisonOperator.NEQ) {
            require(keccak256(result) != keccak256(expected), "equal");
        } else if (op == ComparisonOperator.GTE || op == ComparisonOperator.LTE) {
            require(result.length == expected.length, "length-mismatch");
            if (typeTag == ValueType.UINT256) {
                uint256 actual = abi.decode(result, (uint256));
                uint256 exp = abi.decode(expected, (uint256));
                require(op == ComparisonOperator.GTE ? actual >= exp : actual <= exp, op == ComparisonOperator.GTE ? "lt" : "gt");
            } else if (typeTag == ValueType.INT256) {
                int256 actual = abi.decode(result, (int256));
                int256 exp = abi.decode(expected, (int256));
                require(op == ComparisonOperator.GTE ? actual >= exp : actual <= exp, op == ComparisonOperator.GTE ? "lt" : "gt");
            } else if (typeTag == ValueType.UINT128) {
                uint128 actual = abi.decode(result, (uint128));
                uint128 exp = abi.decode(expected, (uint128));
                require(op == ComparisonOperator.GTE ? actual >= exp : actual <= exp, op == ComparisonOperator.GTE ? "lt" : "gt");
            } else if (typeTag == ValueType.INT128) {
                int128 actual = abi.decode(result, (int128));
                int128 exp = abi.decode(expected, (int128));
                require(op == ComparisonOperator.GTE ? actual >= exp : actual <= exp, op == ComparisonOperator.GTE ? "lt" : "gt");
            } else if (typeTag == ValueType.BOOL) {
                bool actual = abi.decode(result, (bool));
                bool exp = abi.decode(expected, (bool));
                require(
                    op == ComparisonOperator.GTE ? (actual == exp || (actual && !exp)) : (actual == exp || (!actual && exp)),
                    op == ComparisonOperator.GTE ? "lt" : "gt"
                );
            } else {
                revert("unsupported-type");
            }
        } else {
            revert("invalid-operator");
        }
    }
}
