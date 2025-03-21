// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { BitMaps } from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title IdEnforcer Contract
 * @dev This contract extends the CaveatEnforcer contract. It provides functionality to enforce id
 * restrictions on delegations. A delegator can assign the same id to multiple delegations, once one of them
 * is redeemed the other delegations with the same id will revert.
 * @dev This enforcer operates only in default execution mode.
 */
contract IdEnforcer is CaveatEnforcer {
    using BitMaps for BitMaps.BitMap;
    ////////////////////// State //////////////////////

    mapping(address delegationManager => mapping(address delegator => BitMaps.BitMap id)) private isUsedId;

    ////////////////////////////// Events //////////////////////////////

    event UsedId(address indexed sender, address indexed delegator, address indexed redeemer, uint256 id);

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to specify a id for the delegation, that id can be redeemed only once.
     * @param _terms A uint256 representing the id used in the delegation.
     * @param _mode The execution mode. (Must be Default execType)
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address _delegator,
        address _redeemer
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        uint256 id_ = getTermsInfo(_terms);
        require(!getIsUsed(msg.sender, _delegator, id_), "IdEnforcer:id-already-used");
        isUsedId[msg.sender][_delegator].set(id_);
        emit UsedId(msg.sender, _delegator, _redeemer, id_);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return id_ The id used in the delegation.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 id_) {
        require(_terms.length == 32, "IdEnforcer:invalid-terms-length");
        id_ = uint256(bytes32(_terms));
    }

    /**
     * @notice Returns if the id has already been used
     * @param _delegationManager DelegationManager
     * @param _delegator Delegator address
     * @param _id id used in the delegation
     * @return Is the id has already been used
     */
    function getIsUsed(address _delegationManager, address _delegator, uint256 _id) public view returns (bool) {
        return isUsedId[_delegationManager][_delegator].get(_id);
    }
}
