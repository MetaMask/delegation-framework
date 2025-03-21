// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title Limited Calls Enforcer Contract
 * @dev This contract extends the CaveatEnforcer contract. It provides functionality to enforce a limit on the number of times a
 * delegate may perform transactions on behalf of the delegator.
 * @dev This enforcer operates only in default execution mode.
 */
contract LimitedCallsEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    mapping(address delegationManager => mapping(bytes32 delegationHash => uint256 count)) public callCounts;

    ////////////////////////////// Events //////////////////////////////

    event IncreasedCount(
        address indexed sender, address indexed redeemer, bytes32 indexed delegationHash, uint256 limit, uint256 callCount
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to specify a maximum number of times the recipient may perform transactions on their behalf.
     * @param _terms - The maximum number of times the delegate may perform transactions on their behalf.
     * @param _delegationHash - The hash of the delegation being operated on.
     * @param _mode The execution mode. (Must be Default execType)
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        uint256 limit_ = getTermsInfo(_terms);
        uint256 callCounts_ = ++callCounts[msg.sender][_delegationHash];
        require(callCounts_ <= limit_, "LimitedCallsEnforcer:limit-exceeded");
        emit IncreasedCount(msg.sender, _redeemer, _delegationHash, limit_, callCounts_);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return limit_ The maximum number of times the delegate may perform transactions on the delegator's behalf.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 limit_) {
        require(_terms.length == 32, "LimitedCallsEnforcer:invalid-terms-length");
        limit_ = uint256(bytes32(_terms));
    }
}
