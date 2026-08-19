// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "../../../../src/enforcers/CaveatEnforcer.sol";
import { ModeLib, ModeCode } from "@erc7579/lib/ModeLib.sol";

/**
 * @notice Test helper that records the mode and execution calldata observed during `beforeHook`.
 * @dev Managers pass the same `_mode` and `_executionCallData` into caveat hooks and into
 *      `executeFromExecutor`; this enforcer captures hook-visible forwarding inputs for differential tests.
 */
contract ExecuteFromExecutorWitnessEnforcer is CaveatEnforcer {
    ModeCode public witnessedMode;
    bytes public witnessedExecutionCalldata;
    uint256 public witnessCount;

    function beforeHook(
        bytes calldata,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCalldata,
        bytes32,
        address,
        address
    )
        public
        override
    {
        witnessedMode = _mode;
        witnessedExecutionCalldata = _executionCalldata;
        ++witnessCount;
    }

    function resetWitness() external {
        witnessedMode = ModeLib.encodeSimpleSingle();
        witnessedExecutionCalldata = hex"";
        witnessCount = 0;
    }
}
