// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title NativeTokenTransferAmountEnforcer
 * @notice This contract enforces an allowance of native currency (e.g., ETH) for a specific delegation.
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 */
contract NativeTokenTransferAmountEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// State //////////////////////////////

    /// @notice Mapping to store used allowance for each delegation
    mapping(address sender => mapping(bytes32 delegationHash => uint256 amount)) public spentMap;

    ////////////////////////////// Events //////////////////////////////

    event IncreasedSpentMap(
        address indexed sender, address indexed redeemer, bytes32 indexed delegationHash, uint256 limit, uint256 spent
    );

    ////////////////////////////// External Functions //////////////////////////////

    /**
     * @notice Enforces the conditions that should hold before a transaction is performed.
     * @param _terms The encoded amount of native token allowance.
     * @param _mode The execution mode. (Must be Single callType, Default execType)
     * @param _executionCallData The call data of the execution.
     * @param _delegationHash The hash of the delegation.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        // Decode the total allowance from _terms
        uint256 allowance_ = getTermsInfo(_terms);

        (, uint256 value_,) = _executionCallData.decodeSingle();

        uint256 spent_ = spentMap[msg.sender][_delegationHash] += value_;
        require(spent_ <= allowance_, "NativeTokenTransferAmountEnforcer:allowance-exceeded");

        emit IncreasedSpentMap(msg.sender, _redeemer, _delegationHash, allowance_, spent_);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms The encoded amount of native token allowance.
     * @return allowance_ The maximum number of tokens that the delegate is allowed to transfer.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 allowance_) {
        allowance_ = abi.decode(_terms, (uint256));
    }
}
