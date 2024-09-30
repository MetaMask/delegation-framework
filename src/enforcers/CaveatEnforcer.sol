// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { ICaveatEnforcer } from "../interfaces/ICaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";
import { CALLTYPE_SINGLE, CALLTYPE_BATCH } from "../utils/Constants.sol";

/**
 * @title CaveatEnforcer
 * @dev This abstract contract enforces caveats before and after the execution of an execution.
 */
abstract contract CaveatEnforcer is ICaveatEnforcer {
    using ModeLib for ModeCode;

    /// @inheritdoc ICaveatEnforcer
    function beforeAllHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) public virtual { }

    /// @inheritdoc ICaveatEnforcer
    function beforeHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) public virtual { }

    /// @inheritdoc ICaveatEnforcer
    function afterHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) public virtual { }

    /// @inheritdoc ICaveatEnforcer
    function afterAllHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) public virtual { }

    /**
     * @dev Require the function call to be in single execution mode
     */
    modifier onlySingleExecutionMode(ModeCode _mode) {
        require(ModeLib.getCallType(_mode) == CALLTYPE_SINGLE, "CaveatEnforcer:invalid-call-type");
        _;
    }

    /**
     * @dev Require the function call to be in batch execution mode
     */
    modifier onlyBatchExecutionMode(ModeCode _mode) {
        require(ModeLib.getCallType(_mode) == CALLTYPE_BATCH, "CaveatEnforcer:invalid-call-type");
        _;
    }
}
