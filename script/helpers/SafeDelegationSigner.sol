// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/console2.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { Delegation, Caveat } from "../../src/utils/Types.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { SigningUtilsLib } from "../../test/utils/SigningUtilsLib.t.sol";

/**
 * @title SafeDelegationSigner
 * @notice Library for signing delegations with Safe multisig
 * @dev This library encapsulates all the logic for:
 *      - Creating delegation hashes
 *      - Computing Safe message hashes
 *      - Signing with multiple signers
 *      - Verifying signatures
 *      - Attaching signatures to delegations
 */
library SafeDelegationSigner {
    using MessageHashUtils for bytes32;

    /// @notice ERC1271 magic value for valid signature
    bytes4 constant EIP1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 constant SIG_VALIDATION_FAILED = 0xffffffff;

    /// @notice Configuration for signing a delegation with Safe
    struct SignerConfig {
        address safeAddress;
        address gatorSafeModule;
        IDelegationManager delegationManager;
        uint256[] signerPrivateKeys;
        address[] signerAddresses; // Corresponding addresses for the private keys
    }

    /// @notice Result of signing a delegation
    struct SignedDelegationResult {
        Delegation delegation;
        bytes32 delegationHash;
        bytes32 delegationTypedDataHash;
        bytes32 safeMessageHash;
        bytes signatures;
    }

    /**
     * @notice Creates a delegation hash from a delegation struct
     * @param _delegation The delegation to hash
     * @return delegationHash The computed hash of the delegation
     */
    function createDelegationHash(Delegation memory _delegation) internal pure returns (bytes32 delegationHash) {
        delegationHash = EncoderLib._getDelegationHash(_delegation);
    }

    /**
     * @notice Gets the DelegationManager's typed data hash for a delegation
     * @param _delegationManager The DelegationManager contract
     * @param _delegationHash The delegation hash
     * @return delegationTypedDataHash The typed data hash with DelegationManager domain
     */
    function getDelegationTypedDataHash(
        IDelegationManager _delegationManager,
        bytes32 _delegationHash
    )
        internal
        view
        returns (bytes32 delegationTypedDataHash)
    {
        bytes32 delegationDomainHash = _delegationManager.getDomainHash();
        delegationTypedDataHash = delegationDomainHash.toTypedDataHash(_delegationHash);
    }

    /**
     * @notice Gets Safe's message hash for the delegation typed data hash
     * @param _safeAddress The Safe contract address
     * @param _delegationTypedDataHash The delegation typed data hash
     * @return safeMessageHash The Safe message hash (includes both Safe and DelegationManager domains)
     * @dev Safe's getMessageHash computes: keccak256(abi.encodePacked("\x19\x01", domainSeparator,
     *      keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(message))))) where message = abi.encode(typedDataHash)
     */
    function getSafeMessageHash(
        address _safeAddress,
        bytes32 _delegationTypedDataHash
    )
        internal
        view
        returns (bytes32 safeMessageHash)
    {
        ISafe safe = ISafe(_safeAddress);
        bytes memory typedDataHashBytes = abi.encode(_delegationTypedDataHash);
        safeMessageHash = safe.getMessageHash(typedDataHashBytes);
    }

    /**
     * @notice Signs a hash with multiple signers and sorts signatures by signer address
     * @param _hashToSign The hash to sign
     * @param _signerPrivateKeys Array of private keys for signers
     * @param _signerAddresses Array of addresses corresponding to the private keys
     * @return concatenatedSignatures The sorted, concatenated signatures
     * @dev Safe's checkNSignatures REQUIRES signatures sorted by owner address (ascending)
     *      - Each signature must be 65 bytes (r + s + v)
     *      - Signatures are concatenated sequentially: sig1 || sig2 || ...
     *      - Owners must be in ascending order: owner1 < owner2 < owner3 ...
     */
    function signAndSort(
        bytes32 _hashToSign,
        uint256[] memory _signerPrivateKeys,
        address[] memory _signerAddresses
    )
        internal
        view
        returns (bytes memory concatenatedSignatures)
    {
        require(_signerPrivateKeys.length > 0, "SafeDelegationSigner:no-signers");
        require(_signerPrivateKeys.length == _signerAddresses.length, "SafeDelegationSigner:keys-addresses-mismatch");

        // Sign with all signers
        bytes[] memory signatures = new bytes[](_signerPrivateKeys.length);
        address[] memory signers = new address[](_signerPrivateKeys.length);

        for (uint256 i = 0; i < _signerPrivateKeys.length; i++) {
            signatures[i] = SigningUtilsLib.signHash_EOA(_signerPrivateKeys[i], _hashToSign);
            signers[i] = ECDSA.recover(_hashToSign, signatures[i]);
            require(signers[i] == _signerAddresses[i], "SafeDelegationSigner:signature-recovery-failed");
        }

        // Sort signatures by signer address (ascending order)
        // Use insertion sort for simplicity
        for (uint256 i = 1; i < signers.length; i++) {
            address currentSigner = signers[i];
            bytes memory currentSig = signatures[i];
            uint256 j = i;

            while (j > 0 && signers[j - 1] > currentSigner) {
                signers[j] = signers[j - 1];
                signatures[j] = signatures[j - 1];
                j--;
            }

            signers[j] = currentSigner;
            signatures[j] = currentSig;
        }

        // Verify signature lengths and concatenate
        for (uint256 i = 0; i < signatures.length; i++) {
            require(signatures[i].length == 65, "SafeDelegationSigner:invalid-signature-length");
        }

        // Concatenate sorted signatures
        concatenatedSignatures = signatures[0];
        for (uint256 i = 1; i < signatures.length; i++) {
            concatenatedSignatures = abi.encodePacked(concatenatedSignatures, signatures[i]);
        }

        console2.log("Concatenated Signatures (sorted by signer address, ascending):");
        console2.logBytes(concatenatedSignatures);
    }

    /**
     * @notice Verifies signature with Safe's isValidSignature
     * @param _gatorSafeModule The GatorSafeModule contract address
     * @param _delegationTypedDataHash The delegation typed data hash (bytes32) to verify
     * @param _concatenatedSignatures The sorted, concatenated signatures
     * @return isValid True if signature is valid, false otherwise
     * @dev CRITICAL: CompatibilityFallbackHandler.isValidSignature(bytes32) will:
     *      1. Call isValidSignature(bytes) with abi.encode(delegationTypedDataHash)
     *      2. Call getMessageHashForSafe(safe, abi.encode(delegationTypedDataHash)) to recompute hash
     *      3. Call checkSignatures(messageHash, abi.encode(delegationTypedDataHash), signatures)
     */
    function verifySignature(
        address _gatorSafeModule,
        bytes32 _delegationTypedDataHash,
        bytes memory _concatenatedSignatures
    )
        internal
        view
        returns (bool isValid)
    {
        IGatorSafeModule gatorSafeModuleContract = IGatorSafeModule(_gatorSafeModule);
        bytes4 result = gatorSafeModuleContract.isValidSignature(_delegationTypedDataHash, _concatenatedSignatures);

        console2.log("isValidSignature Result:");
        console2.logBytes4(result);

        if (result == EIP1271_MAGIC_VALUE) {
            console2.log("Signature is VALID!");
            isValid = true;
        } else if (result == SIG_VALIDATION_FAILED) {
            console2.log("Signature validation FAILED");
            isValid = false;
        } else {
            console2.log("Unexpected result");
            isValid = false;
        }
    }

    /**
     * @notice Signs a delegation with Safe multisig
     * @param _delegation The delegation to sign (signature field will be ignored)
     * @param _config The signer configuration
     * @return result The signed delegation result with all intermediate hashes
     * @dev This is the main entry point for signing a delegation with Safe
     */
    function signDelegationWithSafe(
        Delegation memory _delegation,
        SignerConfig memory _config
    )
        internal
        view
        returns (SignedDelegationResult memory result)
    {
        // Create delegation hash
        result.delegationHash = createDelegationHash(_delegation);
        console2.log("Delegation Hash:");
        console2.logBytes32(result.delegationHash);

        // Get DelegationManager's typed data hash
        result.delegationTypedDataHash = getDelegationTypedDataHash(_config.delegationManager, result.delegationHash);
        console2.log("Delegation Typed Data Hash (with DelegationManager domain):");
        console2.logBytes32(result.delegationTypedDataHash);

        // Get Safe message hash
        result.safeMessageHash = getSafeMessageHash(_config.safeAddress, result.delegationTypedDataHash);
        console2.log("Safe Message Hash (includes both Safe and DelegationManager domains):");
        console2.logBytes32(result.safeMessageHash);

        // Sign and sort signatures
        result.signatures = signAndSort(result.safeMessageHash, _config.signerPrivateKeys, _config.signerAddresses);

        // Verify signature
        bool isValid = verifySignature(_config.gatorSafeModule, result.delegationTypedDataHash, result.signatures);
        require(isValid, "SafeDelegationSigner:signature-verification-failed");

        // Attach signature to delegation
        result.delegation = Delegation({
            delegate: _delegation.delegate,
            delegator: _delegation.delegator,
            authority: _delegation.authority,
            caveats: _delegation.caveats,
            salt: _delegation.salt,
            signature: result.signatures
        });

        console2.log("Delegation signature (hex):");
        console2.logBytes(result.signatures);
    }
}

/// @notice Safe contract interface for domainSeparator and getMessageHash
interface ISafe {
    function domainSeparator() external view returns (bytes32);
    function getMessageHash(bytes memory message) external view returns (bytes32);
}

/// @notice GatorSafeModule interface for isValidSignature
interface IGatorSafeModule {
    function isValidSignature(bytes32 _hash, bytes calldata _signature) external view returns (bytes4);
}
