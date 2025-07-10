// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

import { DeleGatorCore } from "./DeleGatorCore.sol";
import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { ERC1271Lib } from "./libraries/ERC1271Lib.sol";
import { PackedUserOperation } from "./utils/Types.sol";

/// @custom:storage-location erc7201:DeleGator.MultiSigDeleGator
struct MultiSigDeleGatorStorage {
    mapping(address => bool) isSigner;
    address[] signers;
    uint256 threshold; // 0 < threshold <= number of signers <= MAX_NUMBER_OF_SIGNERS
}

/**
 * @title MultiSig Delegator Contract
 * @dev This contract extends the DeleGatorCore contract. It provides functionality for multi-signature based access control and
 * delegation.
 * @dev The signers that control the DeleGator MUST be EOAs
 */
contract MultiSigDeleGator is DeleGatorCore {
    ////////////////////////////// State //////////////////////////////

    /// @dev The name of the contract
    string public constant NAME = "MultiSigDeleGator";

    /// @dev The version used in the domainSeparator for EIP712
    string public constant DOMAIN_VERSION = "1";

    /// @dev The version of the contract
    string public constant VERSION = "1.3.0";

    /// @dev The storage slot for the MultiSig DeleGator
    /// @dev keccak256(abi.encode(uint256(keccak256("DeleGator.MultiSigDeleGator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DELEGATOR_STORAGE_LOCATION = 0xb005e320c74f68de39b3d9025549122b8b117c48474f537aac49c12147b61c00;

    /// @dev The maximum number of signers allowed
    uint256 public constant MAX_NUMBER_OF_SIGNERS = 30;

    /// @dev The length of a signature
    uint256 private constant SIGNATURE_LENGTH = 65;

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when a signer is replaced by another
    event ReplacedSigner(address indexed oldSigner, address indexed newSigner);

    /// @dev Emitted when a signer is added
    event AddedSigner(address indexed signer);

    /// @dev Emitted when a signer is removed
    event RemovedSigner(address indexed signer);

    /// @dev Emitted when the signature threshold is updated
    event UpdatedThreshold(uint256 threshold);

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error emitted when the threshold provided to be set is invalid
    error InvalidThreshold();

    /// @dev Error emitted when the address of a signer to be added is invalid
    error InvalidSignerAddress();

    /// @dev Error emitted when the address of a signer to be replaced is not a signer
    error NotASigner();

    /// @dev Error emitted when the address of a signer to be added is already a signer
    error AlreadyASigner();

    /// @dev Error emitted when there are too many signers attempted to be added
    error TooManySigners();

    /// @dev Error emitted when there are insufficient signers to remove a signer
    error InsufficientSigners();

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Constructor for the MultiSigDelegator
     * @param _delegationManager the address of the trusted DelegationManager contract that will have root access to this contract
     * @param _entryPoint the address of the EntryPoint contract that will have root access to this contract
     */
    constructor(
        IDelegationManager _delegationManager,
        IEntryPoint _entryPoint
    )
        DeleGatorCore(_delegationManager, _entryPoint, NAME, DOMAIN_VERSION)
    {
        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();
        s_.threshold = type(uint256).max;
        emit UpdatedThreshold(s_.threshold);
    }

    /**
     * @notice Initializes the MultiSigDeleGator signers, and threshold
     * @dev Used by UUPS proxies to initialize the contract state
     * @param _signers The signers of the contract
     * @param _threshold The threshold of signatures required to execute a transaction
     */
    function initialize(address[] calldata _signers, uint256 _threshold) external initializer {
        _setSignersAndThreshold(_signers, _threshold, false);
    }

    /**
     * @notice Reinitializes the MultiSigDeleGator signers, and threshold
     * @dev This method should only be called by upgradeToAndCall when migrating between DeleGator implementations
     * @param _version The initilized version number of the proxy using this logic contract
     * @param _signers The signers of the contract
     * @param _threshold The threshold of signatures required to execute a transaction
     * @param _clearSigners Boolean indicating whether to remove the current signerss
     */
    function reinitialize(
        uint64 _version,
        address[] calldata _signers,
        uint256 _threshold,
        bool _clearSigners
    )
        external
        reinitializer(_version)
        onlyEntryPointOrSelf
    {
        _setSignersAndThreshold(_signers, _threshold, _clearSigners);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Replaces a signer with another signer
     * @param _oldSigner The old signer address to be replaced.
     * @param _newSigner The new signer address to replace the old one.
     */
    function replaceSigner(address _oldSigner, address _newSigner) external onlyEntryPointOrSelf {
        if (_newSigner == address(0) || _newSigner.code.length != 0) revert InvalidSignerAddress();

        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();

        if (!s_.isSigner[_oldSigner]) revert NotASigner();
        if (s_.isSigner[_newSigner]) revert AlreadyASigner();

        uint256 length_ = s_.signers.length;
        for (uint256 i = 0; i < length_; ++i) {
            if (s_.signers[i] == _oldSigner) {
                s_.signers[i] = _newSigner;
                break;
            }
        }

        delete s_.isSigner[_oldSigner];
        s_.isSigner[_newSigner] = true;
        emit ReplacedSigner(_oldSigner, _newSigner);
    }

    /**
     * @notice Adds a new signer to the MultiSigDeleGator
     * @param _newSigner the new signer to be added
     */
    function addSigner(address _newSigner) external onlyEntryPointOrSelf {
        if (_newSigner == address(0) || _newSigner.code.length != 0) revert InvalidSignerAddress();

        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();

        if (s_.signers.length == MAX_NUMBER_OF_SIGNERS) revert TooManySigners();
        if (s_.isSigner[_newSigner]) revert AlreadyASigner();

        s_.signers.push(_newSigner);
        s_.isSigner[_newSigner] = true;

        emit AddedSigner(_newSigner);
    }

    /**
     * @notice Removes a signer from the MultiSigDeleGator
     * @param _oldSigner the signer to be removed
     */
    function removeSigner(address _oldSigner) external onlyEntryPointOrSelf {
        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();

        if (!s_.isSigner[_oldSigner]) revert NotASigner();
        uint256 storedSignersLength_ = s_.signers.length;
        if (storedSignersLength_ == s_.threshold) revert InsufficientSigners();

        for (uint256 i = 0; i < storedSignersLength_ - 1; ++i) {
            if (s_.signers[i] == _oldSigner) {
                s_.signers[i] = s_.signers[storedSignersLength_ - 1];
                break;
            }
        }
        s_.signers.pop();
        delete s_.isSigner[_oldSigner];

        emit RemovedSigner(_oldSigner);
    }

    /**
     * @notice Updates the threshold of the MultiSigDeleGator
     * @param _threshold The new threshold of signatures required to execute a transaction
     */
    function updateThreshold(uint256 _threshold) external onlyEntryPointOrSelf {
        if (_threshold == 0) revert InvalidThreshold();
        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();
        if (_threshold > s_.signers.length) revert InvalidThreshold();

        s_.threshold = _threshold;

        emit UpdatedThreshold(_threshold);
    }

    /**
     * @notice Optionally overwrites the current signers and threshold of the MultiSigDeleGator
     * @param _signers The new signers of the MultiSigDeleGator
     * @param _threshold The new threshold of signatures required to execute a transaction
     * @param _clearSigners Boolean indicating whether to remove the current signerss
     */
    function updateMultiSigParameters(
        address[] calldata _signers,
        uint256 _threshold,
        bool _clearSigners
    )
        external
        onlyEntryPointOrSelf
    {
        _setSignersAndThreshold(_signers, _threshold, _clearSigners);
    }

    /**
     * @notice Checks if an address is a signer of the MultiSigDeleGator
     * @param _addr The address to be checked against the signers
     * @return True if the address is one of the signers of the DeleGator
     */
    function isSigner(address _addr) external view returns (bool) {
        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();
        return s_.isSigner[_addr];
    }

    /**
     * @notice Returns the signers of the MultiSigDeleGator
     * @return The signers of the MultiSigDeleGator
     */
    function getSigners() external view returns (address[] memory) {
        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();
        return s_.signers;
    }

    /**
     * @notice Returns the threshold of the MultiSigDeleGator
     * @return The threshold of the multiSig
     */
    function getThreshold() external view returns (uint256) {
        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();
        return s_.threshold;
    }

    /**
     * @notice Returns the count of the signers of the MultiSigDeleGator
     */
    function getSignersCount() external view returns (uint256) {
        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();
        return s_.signers.length;
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Adds the signers and threshold, optionally deletes the current signers
     * @param _signers List of new signers of the MultiSig
     * @param _threshold The new threshold of required signatures
     * @param _clearSigners Boolean indicating whether to remove the current signerss
     */
    function _setSignersAndThreshold(address[] calldata _signers, uint256 _threshold, bool _clearSigners) internal {
        uint256 signersLength_ = _signers.length;
        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();
        uint256 storedSignersLength_ = s_.signers.length;

        uint256 signersCount_ = _clearSigners ? signersLength_ : signersLength_ + storedSignersLength_;
        if (_threshold == 0 || _threshold > signersCount_) revert InvalidThreshold();
        if (signersCount_ > MAX_NUMBER_OF_SIGNERS) revert TooManySigners();

        if (_clearSigners) {
            for (uint256 i = 0; i < storedSignersLength_; ++i) {
                address signer_ = s_.signers[i];
                delete s_.isSigner[signer_];
                emit RemovedSigner(signer_);
            }
            delete s_.signers;
        }

        for (uint256 i = 0; i < signersLength_; ++i) {
            address newSigner_ = _signers[i];
            if (s_.isSigner[newSigner_]) revert AlreadyASigner();
            if (newSigner_ == address(0) || newSigner_.code.length != 0) revert InvalidSignerAddress();

            s_.signers.push(newSigner_);
            s_.isSigner[newSigner_] = true;

            emit AddedSigner(newSigner_);
        }
        s_.threshold = _threshold;
        emit UpdatedThreshold(_threshold);
    }

    /**
     * @notice Clears the MultiSig DeleGator storage struct
     * @dev Prepares contract storage for a UUPS proxy to migrate to a new implementation
     */
    function _clearDeleGatorStorage() internal override {
        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();
        uint256 signersLength_ = s_.signers.length;
        for (uint256 i = 0; i < signersLength_; ++i) {
            delete s_.isSigner[s_.signers[i]];
        }
        delete s_.signers;
        delete s_.threshold;
        emit ClearedStorage();
    }

    /**
     * @notice This method is used to verify the signatures of the signers
     * @dev Signatures must be sorted in ascending order by the address of the signer.
     * @param _hash The data signed
     * @param _signatures A threshold amount of 65-byte signatures from the signers all sorted and concatenated
     * @return The EIP1271 magic value if the signature is valid, otherwise it reverts
     */
    function _isValidSignature(bytes32 _hash, bytes calldata _signatures) internal view override returns (bytes4) {
        MultiSigDeleGatorStorage storage s_ = _getDeleGatorStorage();

        // check if we have enough sigs by threshold
        if (_signatures.length != s_.threshold * SIGNATURE_LENGTH) return ERC1271Lib.SIG_VALIDATION_FAILED;

        uint256 signatureCount_ = _signatures.length / SIGNATURE_LENGTH;
        uint256 threshold_ = s_.threshold;

        // There cannot be an owner with address 0.
        address lastOwner_ = address(0);
        address currentOwner_;
        uint256 validSignatureCount_ = 0;

        for (uint256 i = 0; i < signatureCount_; ++i) {
            bytes memory signature_ = _signatures[i * SIGNATURE_LENGTH:(i + 1) * SIGNATURE_LENGTH];

            currentOwner_ = ECDSA.recover(_hash, signature_);

            if (currentOwner_ <= lastOwner_ || !s_.isSigner[currentOwner_]) return ERC1271Lib.SIG_VALIDATION_FAILED;

            validSignatureCount_++;

            if (validSignatureCount_ >= threshold_) {
                return ERC1271Lib.EIP1271_MAGIC_VALUE;
            }

            lastOwner_ = currentOwner_;
        }

        return ERC1271Lib.SIG_VALIDATION_FAILED;
    }

    /**
     * @notice This method loads the storage struct for the DeleGator implementation.
     */
    function _getDeleGatorStorage() internal pure returns (MultiSigDeleGatorStorage storage s_) {
        assembly {
            s_.slot := DELEGATOR_STORAGE_LOCATION
        }
    }
}
