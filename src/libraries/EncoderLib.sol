// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Delegation, Caveat } from "../utils/Types.sol";
import { DELEGATION_TYPEHASH, CAVEAT_TYPEHASH } from "../utils/Constants.sol";

/**
 * @dev Provides implementations for common utility methods for Delegation.
 * @title Delegation Utility Library
 */
library EncoderLib {
    /**
     * @notice Encodes and hashes a Delegation struct.
     * @dev The hash is used to verify the integrity of the Delegation.
     * @param _input The Delegation parameters to be hashed.
     * @return The keccak256 hash of the encoded Delegation packet.
     */
    function _getDelegationHash(Delegation memory _input) internal pure returns (bytes32) {
        bytes memory encoded_ = abi.encode(
            DELEGATION_TYPEHASH,
            _input.delegate,
            _input.delegator,
            _input.authority,
            _getCaveatArrayPacketHash(_input.caveats),
            _input.salt
        );
        return keccak256(encoded_);
    }

    /**
     * @notice Calculates the hash of an array of Caveats.
     * @dev The hash is used to verify the integrity of the Caveats.
     * @param _input The array of Caveats.
     * @return The keccak256 hash of the encoded Caveat array packet.
     */
    function _getCaveatArrayPacketHash(Caveat[] memory _input) internal pure returns (bytes32) {
        bytes32[] memory caveatPacketHashes_ = new bytes32[](_input.length);
        for (uint256 i = 0; i < _input.length; ++i) {
            caveatPacketHashes_[i] = _getCaveatPacketHash(_input[i]);
        }
        return keccak256(abi.encodePacked(caveatPacketHashes_));
    }

    /**
     * @notice Calculates the hash of a single Caveat.
     * @dev The hash is used to verify the integrity of the Caveat.
     * @param _input The Caveat data.
     * @return The keccak256 hash of the encoded Caveat packet.
     */
    function _getCaveatPacketHash(Caveat memory _input) internal pure returns (bytes32) {
        bytes memory encoded_ = abi.encode(CAVEAT_TYPEHASH, _input.enforcer, keccak256(_input.terms));
        return keccak256(encoded_);
    }
}
