// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title Nonce Enforcer Contract
 * @dev This contract extends the CaveatEnforcer contract. It provides functionality to add an nonce to a delegation and enable
 * multi delegation revocation based on that nonce by incrementing the current nonce.
 * @dev This enforcer operates only in default execution mode.
 */
contract NonceEnforcer is CaveatEnforcer {
    ////////////////////// State //////////////////////

    mapping(address delegationManager => mapping(address delegator => uint256 nonce)) public currentNonce;

    ////////////////////////////// Events //////////////////////////////

    event UsedNonce(address indexed delegationManager, address indexed delegator, uint256 nonce);

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice
     * @param _terms A uint256 representing the nonce used in the delegation.
     * @param _mode The execution mode. (Must be Default execType)
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address _delegator,
        address
    )
        public
        view
        override
        onlyDefaultExecutionMode(_mode)
    {
        uint256 nonce_ = getTermsInfo(_terms);
        require(currentNonce[msg.sender][_delegator] == nonce_, "NonceEnforcer:invalid-nonce");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return nonce_ The ID used in the delegation.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (uint256 nonce_) {
        require(_terms.length == 32, "NonceEnforcer:invalid-terms-length");
        nonce_ = uint256(bytes32(_terms));
    }

    /**
     * @notice Increments the nonce of a delegator. This invalidates all previous delegations with the old nonce.
     * @dev The message sender must be the delegator.
     * @param _delegationManager the address of the delegation manager that the user is using.
     */
    function incrementNonce(address _delegationManager) external {
        uint256 oldNonce_;
        unchecked {
            oldNonce_ = currentNonce[_delegationManager][msg.sender]++;
        }
        emit UsedNonce(_delegationManager, msg.sender, oldNonce_);
    }
}
