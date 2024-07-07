// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import { Action } from "../utils/Types.sol";

/**
 * @title IDeleGatorCore
 * @notice Interface for a DeleGator that exposes the minimal functionality required.
 */
interface IDeleGatorCore is IERC1271 {
    /**
     * @notice executes a CALL using the data provided in the action
     * @dev MUST enforce calls come from an approved DelegationManager address
     * @param _action the onchain action to perform
     */
    function executeDelegatedAction(Action calldata _action) external;
}
