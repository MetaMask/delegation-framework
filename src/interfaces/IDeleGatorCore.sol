// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import { ModeCode } from "../utils/Types.sol";

/**
 * @title IDeleGatorCore
 * @notice Interface for a DeleGator that exposes the minimal functionality required.
 */
interface IDeleGatorCore is IERC1271 {
    /**
     * @dev Executes a transaction on behalf of the account.
     *         This function is intended to be called by Executor Modules
     * @dev Ensure adequate authorization control: i.e. onlyExecutorModule
     * @dev If a mode is requested that is not supported by the Account, it MUST revert
     * @dev Related: @erc7579/MSAAdvanced.sol
     * @param _mode The encoded execution mode of the transaction. See @erc7579/ModeLib.sol for details.
     * @param _executionCalldata The encoded execution call data
     */
    function executeFromExecutor(
        ModeCode _mode,
        bytes calldata _executionCalldata
    )
        external
        payable
        returns (bytes[] memory returnData);
}
