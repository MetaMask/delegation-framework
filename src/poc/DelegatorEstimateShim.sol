// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { CallType, ExecType, ModeCode } from "../utils/Types.sol";
import { CALLTYPE_SINGLE, CALLTYPE_BATCH, EXECTYPE_DEFAULT, EXECTYPE_TRY } from "../utils/Constants.sol";
import { ERC1271Lib } from "../libraries/ERC1271Lib.sol";

/// @notice PoC-only delegator bytecode for eth_estimateGas with state overrides.
/// @dev Mirrors the gas profile of EIP7702StatelessDeleGator on the two paths
///      DelegationManager exercises (isValidSignature + single-default
///      executeFromExecutor) without requiring a valid signature. Not for
///      production. Single-default executions only.
contract DelegatorEstimateShim {
    using ModeLib for ModeCode;
    using ExecutionLib for bytes;

    /// @dev Implementation address, used by the onlyProxy guard to mirror
    ///      EIP7702DeleGatorCore.__self. Set to address(this) at construction;
    ///      under vm.etch / state override, address(this) is the etched account
    ///      (delegator), so the guard passes just like a real proxy call.
    address public immutable __self;

    address public immutable delegationManager;

    error NotDelegationManager();
    error UnauthorizedCallContext();
    error UnsupportedCallType(CallType callType);
    error UnsupportedExecType(ExecType execType);
    error ExecutionFailed();

    constructor(address _delegationManager) {
        __self = address(this);
        delegationManager = _delegationManager;
    }

    /// @dev Mirrors EIP7702DeleGatorCore.isValidSignature: onlyProxy guard,
    ///      then ECDSA.tryRecover (pays the ecrecover precompile + OZ overhead),
    ///      then returns magic regardless of the recovered address so any
    ///      65-byte placeholder passes. tryRecover is used instead of recover so
    ///      invalid signatures do not revert — this matches the gas profile of
    ///      the real delegator's valid-signature path (no revert overhead).
    function isValidSignature(bytes32 _hash, bytes calldata _signature) external view returns (bytes4) {
        if (address(this) == __self) revert UnauthorizedCallContext();
        // Burn the same gas as a real signature check; ignore the result.
        ECDSA.tryRecover(_hash, _signature);
        return ERC1271Lib.EIP1271_MAGIC_VALUE;
    }

    /// @dev Mirrors EIP7702DeleGatorCore.executeFromExecutor: onlyDelegationManager,
    ///      mode decode + branch, single-default via the same assembly call
    ///      body as ExecutionHelper._execute (bubble revert on failure).
    function executeFromExecutor(ModeCode _mode, bytes calldata _executionCalldata)
        external
        payable
        returns (bytes[] memory returnData_)
    {
        if (msg.sender != delegationManager) revert NotDelegationManager();

        (CallType callType_, ExecType execType_,,) = _mode.decode();

        if (callType_ == CALLTYPE_SINGLE) {
            if (!(execType_ == EXECTYPE_DEFAULT)) revert UnsupportedExecType(execType_);
            (address target_, uint256 value_, bytes calldata callData_) = _executionCalldata.decodeSingle();
            returnData_ = new bytes[](1);
            returnData_[0] = _execute(target_, value_, callData_);
        } else if (callType_ == CALLTYPE_BATCH) {
            // Not used by the relayer (encodeSimpleSingle only); revert to
            // avoid silently cheap-passing mis-encoded estimates.
            revert UnsupportedCallType(callType_);
        } else {
            revert UnsupportedCallType(callType_);
        }
    }

    /// @dev Same memory-safe-assembly call body as ExecutionHelper._execute.
    function _execute(address target, uint256 value, bytes calldata callData)
        internal
        returns (bytes memory result)
    {
        /// @solidity memory-safe-assembly
        assembly {
            result := mload(0x40)
            calldatacopy(result, callData.offset, callData.length)
            if iszero(call(gas(), target, value, result, callData.length, codesize(), 0x00)) {
                // Bubble up the revert if the call reverts.
                returndatacopy(result, 0x00, returndatasize())
                revert(result, returndatasize())
            }
            mstore(result, returndatasize()) // Store the length.
            let o := add(result, 0x20)
            returndatacopy(o, 0x00, returndatasize()) // Copy the returndata.
            mstore(0x40, add(o, returndatasize())) // Allocate the memory.
        }
    }
}
