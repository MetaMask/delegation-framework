// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

import { EIP7702DeleGatorCore } from "./EIP7702DeleGatorCore.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { ERC1271Lib } from "../libraries/ERC1271Lib.sol";

/**
 * @title EIP7702 Stateless Delegator Contract
 * @dev This contract extends the EIP7702DeleGatorCore contract. It provides functionality for EIP7702 based access control
 * and delegation.
 * @dev The signer that controls the DeleGator MUST be the EIP7702 EOA
 */
contract EIP7702StatelessDeleGator is EIP7702DeleGatorCore {
    ////////////////////////////// State //////////////////////////////

    /// @dev The name of the contract
    string public constant NAME = "EIP7702StatelessDeleGator";

    /// @dev The version used in the domainSeparator for EIP712
    string public constant DOMAIN_VERSION = "1";

    /// @dev The version of the contract
    string public constant VERSION = "1.3.0";

    /// @dev The length of a signature
    uint256 private constant SIGNATURE_LENGTH = 65;

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Constructor for the EIP7702Stateless DeleGator
     * @param _delegationManager the address of the trusted DelegationManager contract that will have root access to this contract
     * @param _entryPoint the address of the EntryPoint contract that will have root access to this contract
     */
    constructor(
        IDelegationManager _delegationManager,
        IEntryPoint _entryPoint
    )
        EIP7702DeleGatorCore(_delegationManager, _entryPoint, NAME, DOMAIN_VERSION)
    { }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice This method is used to verify the signature of the signer
     * @param _hash The data signed
     * @param _signature A 65-byte signature produced by the EIP7702 EOA
     * @return The EIP1271 magic value if the signature is valid, otherwise it reverts
     */
    function _isValidSignature(bytes32 _hash, bytes calldata _signature) internal view override returns (bytes4) {
        if (ECDSA.recover(_hash, _signature) == address(this)) return ERC1271Lib.EIP1271_MAGIC_VALUE;

        return ERC1271Lib.SIG_VALIDATION_FAILED;
    }
}
