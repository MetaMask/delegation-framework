// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { ICaveatEnforcer } from "../interfaces/ICaveatEnforcer.sol";
import { ModeCode, ExecType } from "../utils/Types.sol";
import { CALLTYPE_SINGLE, CALLTYPE_BATCH, EXECTYPE_DEFAULT, EXECTYPE_TRY } from "../utils/Constants.sol";

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
     * @dev Require the function call to be in single call type
     */
    modifier onlySingleCallTypeMode(ModeCode _mode) {
        {
            require(ModeLib.getCallType(_mode) == CALLTYPE_SINGLE, "CaveatEnforcer:invalid-call-type");
        }
        _;
    }

    /**
     * @dev Require the function call to be in batch call type
     */
    modifier onlyBatchCallTypeMode(ModeCode _mode) {
        {
            require(ModeLib.getCallType(_mode) == CALLTYPE_BATCH, "CaveatEnforcer:invalid-call-type");
        }
        _;
    }

    /**
     * @dev Require the function call to be in default execution mode
     */
    modifier onlyDefaultExecutionMode(ModeCode _mode) {
        {
            (, ExecType _execType,,) = _mode.decode();
            require(_execType == EXECTYPE_DEFAULT, "CaveatEnforcer:invalid-execution-type");
        }
        _;
    }

    /**
     * @dev Require the function call to be in try execution mode
     */
    modifier onlyTryExecutionMode(ModeCode _mode) {
        {
            (, ExecType _execType,,) = _mode.decode();
            require(_execType == EXECTYPE_TRY, "CaveatEnforcer:invalid-execution-type");
        }
        _;
    }
}
