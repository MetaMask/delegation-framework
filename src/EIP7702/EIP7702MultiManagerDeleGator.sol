// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { EIP7702MultiManagerDeleGatorCore } from "./EIP7702MultiManagerDeleGatorCore.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { ERC1271Lib } from "../libraries/ERC1271Lib.sol";

/**
 * @title EIP7702MultiManagerDeleGator
 * @notice EIP-7702 account with two permanent default DelegationManagers and mutable additional DelegationManagers.
 * @dev Every default or approved additional DelegationManager has full root execution authority.
 */
contract EIP7702MultiManagerDeleGator is EIP7702MultiManagerDeleGatorCore {
    ////////////////////////////// State //////////////////////////////

    /// @dev The name of the implementation.
    string public constant NAME = "EIP7702MultiManagerDeleGator";

    /// @dev The implementation version.
    string public constant VERSION = "1.0.0";

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the implementation with two equal, permanent default DelegationManagers.
     * @param _defaultDelegationManager1 The first permanent DelegationManager.
     * @param _defaultDelegationManager2 The second permanent DelegationManager.
     */
    constructor(
        IDelegationManager _defaultDelegationManager1,
        IDelegationManager _defaultDelegationManager2
    )
        EIP7702MultiManagerDeleGatorCore(_defaultDelegationManager1, _defaultDelegationManager2)
    { }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Verifies a signature from the EOA whose address hosts this delegated code.
     * @param _hash The signed hash.
     * @param _signature The ECDSA signature.
     * @return The ERC-1271 magic value for a valid signature, otherwise the failure value.
     */
    function _isValidSignature(bytes32 _hash, bytes calldata _signature) internal view override returns (bytes4) {
        if (ECDSA.recover(_hash, _signature) == address(this)) return ERC1271Lib.EIP1271_MAGIC_VALUE;
        return ERC1271Lib.SIG_VALIDATION_FAILED;
    }
}
