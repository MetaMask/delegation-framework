// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC20AllowanceRevocationEnforcer
 * @notice Allows the delegate to revoke an existing ERC-20 allowance on behalf of the delegator.
 *
 * @dev The execution must:
 * - transfer zero native value,
 * - call `approve(address spender, uint256 amount)` on the execution target,
 * - set `amount` to zero, and
 * - target a contract on which `allowance(delegator, spender)` currently returns a non-zero value.
 *
 * The allowance precondition guarantees the call is strictly a revocation of an existing allowance rather than a
 * new grant or a no-op against an already-zero allowance.
 *
 * @dev This enforcer does not consume any terms.
 * @dev Operates only in single call type and default execution mode.
 */
contract ERC20AllowanceRevocationEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    /// @dev Calldata length of `approve(address,uint256)`: 4-byte selector + two 32-byte words.
    uint256 private constant _APPROVE_CALLDATA_LENGTH = 68;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Requires the execution to revoke an existing ERC-20 allowance owned by `_delegator`.
     * @param _mode Must be single call type and default execution mode.
     * @param _executionCallData Single execution targeting the ERC-20 token contract.
     * @param _delegator The delegator, treated as the allowance `owner`.
     */
    function beforeHook(
        bytes calldata,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32,
        address _delegator,
        address
    )
        public
        view
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(value_ == 0, "ERC20AllowanceRevocationEnforcer:invalid-value");
        require(callData_.length == _APPROVE_CALLDATA_LENGTH, "ERC20AllowanceRevocationEnforcer:invalid-execution-length");
        require(bytes4(callData_[0:4]) == IERC20.approve.selector, "ERC20AllowanceRevocationEnforcer:invalid-method");
        require(uint256(bytes32(callData_[36:68])) == 0, "ERC20AllowanceRevocationEnforcer:non-zero-amount");

        address spender_ = address(uint160(uint256(bytes32(callData_[4:36]))));

        (bool success_, bytes memory returnData_) =
            target_.staticcall(abi.encodeWithSelector(IERC20.allowance.selector, _delegator, spender_));
        require(
            success_ && returnData_.length >= 32, "ERC20AllowanceRevocationEnforcer:allowance-call-failed"
        );
        require(abi.decode(returnData_, (uint256)) != 0, "ERC20AllowanceRevocationEnforcer:no-allowance-to-revoke");
    }
}
