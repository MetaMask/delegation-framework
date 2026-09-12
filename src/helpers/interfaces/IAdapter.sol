// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Delegation } from "../../utils/Types.sol";

/**
 * @title IAdapter
 * @notice Interface for protocol adapters that handle token transformations
 */
interface IAdapter {
    /**
     * @notice Struct representing token transformation information
     */
    struct TransformationInfo {
        address tokenFrom;
        uint256 amountFrom;
        address tokenTo;
        uint256 amountTo;
    }

    /**
     * @notice Executes a protocol interaction and returns transformation info
     * @param _protocolAddress The address of the protocol contract
     * @param _action The action to perform (e.g., "deposit", "withdraw", "borrow", "repay")
     * @param _tokenFrom The input token address
     * @param _amountFrom The amount of input tokens to use
     * @param _actionData Additional data needed for the specific action
     * @return transformationInfo_ The transformation information (tokenFrom, amountFrom, tokenTo, amountTo)
     */
    function executeProtocolAction(
        address _protocolAddress,
        string calldata _action,
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        bytes calldata _actionData
    )
        external
        returns (TransformationInfo memory transformationInfo_);
}

