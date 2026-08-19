// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Delegation } from "../../utils/Types.sol";
import { ExperimentDelegationManagerBase } from "../lib/ExperimentDelegationManagerBase.sol";

/**
 * @title X3ActivationCacheDelegationManager
 * @notice X3 experiment: skip repeat signature validation after first successful fill per epoch.
 * @dev Epoch bumps on `disableDelegation` and explicit `bumpDelegatorEpoch`. See X3.md for ERC-1271 risks.
 */
contract X3ActivationCacheDelegationManager is ExperimentDelegationManagerBase {
    string public constant NAME = "X3ActivationCacheDelegationManager";
    string public constant VERSION = "1.0.0-exp";

    mapping(address delegator => uint256 epoch) public delegatorEpoch;
    mapping(bytes32 activationKey => bool activated) public activationCache;

    event DelegatorEpochBumped(address indexed delegator, uint256 newEpoch);

    constructor(address _owner) ExperimentDelegationManagerBase(NAME, VERSION, _owner) { }

    function bumpDelegatorEpoch() external {
        uint256 nextEpoch_ = delegatorEpoch[msg.sender] + 1;
        delegatorEpoch[msg.sender] = nextEpoch_;
        emit DelegatorEpochBumped(msg.sender, nextEpoch_);
    }

    function activationKey(address _delegator, bytes32 _delegationHash) public view returns (bytes32) {
        return keccak256(abi.encode(_delegator, _delegationHash, delegatorEpoch[_delegator]));
    }

    function _validateDelegationSignature(Delegation memory _delegation, bytes32 _delegationHash) internal override {
        bytes32 key_ = activationKey(_delegation.delegator, _delegationHash);
        if (activationCache[key_]) return;
        super._validateDelegationSignature(_delegation, _delegationHash);
        activationCache[key_] = true;
    }

    function _onDelegationDisabled(address _delegator, bytes32) internal override {
        delegatorEpoch[_delegator] = delegatorEpoch[_delegator] + 1;
    }
}
