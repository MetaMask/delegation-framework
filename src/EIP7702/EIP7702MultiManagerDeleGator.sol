// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { EIP7702MultiManagerDeleGatorCore } from "./EIP7702MultiManagerDeleGatorCore.sol";
import { ERC1271Lib } from "../libraries/ERC1271Lib.sol";

/**
 * @title EIP7702 Multi-Manager Stateless DeleGator Contract
 * @notice An EIP-7702 account that approves a SET of DelegationManagers, instead of the single immutable
 *         manager baked into {EIP7702StatelessDeleGator}.
 * @dev Same recover-to-self ECDSA signature scheme as {EIP7702StatelessDeleGator}: the signer that controls the account MUST
 *      be the EIP-7702 EOA. The approved-manager set lives in EIP-7201 namespaced storage on the EOA (see the core). This
 *      account is NOT ERC-4337 compatible (no EntryPoint / UserOperation support).
 */
contract EIP7702MultiManagerDeleGator is EIP7702MultiManagerDeleGatorCore {
    ////////////////////////////// State //////////////////////////////

    /// @dev The name of the contract
    string public constant NAME = "EIP7702MultiManagerDeleGator";

    /// @dev The version of the contract
    string public constant VERSION = "1.3.0";

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Verifies that the signature was produced by the EIP-7702 EOA (i.e. this account's address).
     * @param _hash The data signed
     * @param _signature A 65-byte signature produced by the EIP-7702 EOA
     * @return The EIP1271 magic value if the signature is valid, otherwise the failure value.
     */
    function _isValidSignature(bytes32 _hash, bytes calldata _signature) internal view override returns (bytes4) {
        if (ECDSA.recover(_hash, _signature) == address(this)) return ERC1271Lib.EIP1271_MAGIC_VALUE;

        return ERC1271Lib.SIG_VALIDATION_FAILED;
    }
}
