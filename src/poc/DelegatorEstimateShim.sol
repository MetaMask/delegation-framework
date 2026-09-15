// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeCode } from "../utils/Types.sol";
import { ERC1271Lib } from "../libraries/ERC1271Lib.sol";

/// @notice PoC-only delegator bytecode for eth_estimateGas with state overrides (always-valid ERC-1271).
/// @dev Not for production. Minimal executeFromExecutor for single-default executions only.
contract DelegatorEstimateShim {
    using ExecutionLib for bytes;

    address public immutable delegationManager;

    error NotDelegationManager();
    error ExecutionFailed();

    constructor(address _delegationManager) {
        delegationManager = _delegationManager;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return ERC1271Lib.EIP1271_MAGIC_VALUE;
    }

    function executeFromExecutor(
        ModeCode _mode,
        bytes calldata _executionCalldata
    )
        external
        payable
        returns (bytes[] memory returnData_)
    {
        if (msg.sender != delegationManager) revert NotDelegationManager();
        _mode;
        (address target_, uint256 value_, bytes calldata callData_) = _executionCalldata.decodeSingle();
        returnData_ = new bytes[](1);
        (bool success_, bytes memory ret_) = target_.call{ value: value_ }(callData_);
        if (!success_) {
            if (ret_.length > 0) {
                assembly {
                    revert(add(ret_, 32), mload(ret_))
                }
            }
            revert ExecutionFailed();
        }
        returnData_[0] = ret_;
    }
}
