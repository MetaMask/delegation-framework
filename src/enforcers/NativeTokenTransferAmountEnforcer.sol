// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { Action } from "../utils/Types.sol";

/**
 * @title NativeTokenTransferAmountEnforcer
 * @notice This contract enforces an allowance of native currency (e.g., ETH) for a specific delegation.
 */
contract NativeTokenTransferAmountEnforcer is CaveatEnforcer {
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
     * @param _action The action of the transaction.
     * @param _delegationHash The hash of the delegation.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        Action calldata _action,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
    {
        // Decode the total allowance from _terms
        uint256 allowance_ = getTermsInfo(_terms);

        uint256 spent_ = spentMap[msg.sender][_delegationHash] += _action.value;
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
