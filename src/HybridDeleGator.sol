// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

import { DeleGatorCore } from "./DeleGatorCore.sol";
import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { ERC1271Lib } from "./libraries/ERC1271Lib.sol";
import { P256VerifierLib } from "./libraries/P256VerifierLib.sol";
import { P256SCLVerifierLib } from "./libraries/P256SCLVerifierLib.sol";
import { P256PublicKey } from "./utils/Types.sol";
import { IERC173 } from "./interfaces/IERC173.sol";

/// @custom:storage-location erc7201:DeleGator.HybridDeleGator
struct HybridDeleGatorStorage {
    address owner;
    mapping(bytes32 keyIdHash => P256PublicKey) authorizedKeys;
    bytes32[] keyIdHashes;
}

/**
 * @title HybridDeleGator Contract
 * @dev This contract extends the DelegatorCore contracts. It provides functionality to validate P256 and EOA signatures.
 * @dev The signers that control the DeleGator are EOA, raw P256 keys or WebAuthn P256 public keys.
 * @notice There can be multiple signers configured for the DeleGator but only one signature is needed for a valid signature.
 * @notice There must be at least one active signer.
 */
contract HybridDeleGator is DeleGatorCore, IERC173 {
    ////////////////////////////// State //////////////////////////////

    /// @dev The name of the contract
    string public constant NAME = "HybridDeleGator";

    /// @dev The version used in the domainSeparator for EIP712
    string public constant DOMAIN_VERSION = "1";

    /// @dev The version of the contract
    string public constant VERSION = "1.3.0";

    /// @dev The storage location used for state
    /// @dev keccak256(abi.encode(uint256(keccak256("DeleGator.HybridDeleGator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DELEGATOR_STORAGE_LOCATION = 0xa2b1bcb5e16cee2a8898b49cb0c3605e70c16f429f6002ed8b1bc5612a694900;

    ////////////////////////////// Events //////////////////////////////

    /// @dev Event emitted when a P256 key is added
    event AddedP256Key(bytes32 indexed keyIdHash, string keyId, uint256 x, uint256 y);

    /// @dev Event emitted when a P256 key is removed
    event RemovedP256Key(bytes32 indexed keyIdHash, uint256 x, uint256 y);

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error emitted when a P256 key already exists
    error KeyAlreadyExists(bytes32 keyIdHash);

    /// @dev Error emitted when a P256 key is not stored and attempted to be removed
    error KeyDoesNotExist(bytes32 keyIdHash);

    /// @dev Error emitted when the last signer is attempted to be removed
    error CannotRemoveLastSigner();

    /// @dev Error emitted when the input lengths do not match
    error InputLengthsMismatch(uint256 keyIdsLength, uint256 xValuesLength, uint256 yValuesLength);

    /// @dev Error emitted when attempting to update to a state with no signers
    error SignersCannotBeEmpty();

    /// @dev Error emitted when a P256 key is not on the curve
    error KeyNotOnCurve(uint256 x, uint256 y);

    /// @dev Error emitted when an empty key is attempted to be added
    error InvalidEmptyKey();

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Constructor for the HybridDeleGator
     * @param _delegationManager the address of the trusted DelegationManager contract that will have root access to this contract
     * @param _entryPoint The entry point contract address
     */
    constructor(
        IDelegationManager _delegationManager,
        IEntryPoint _entryPoint
    )
        DeleGatorCore(_delegationManager, _entryPoint, NAME, DOMAIN_VERSION)
    { }

    /**
     * @notice Initializes the HybridDeleGator state by setting the owners.
     * @dev Used by UUPS proxies to initialize the contract state
     * @dev Contract owners require staking in the EntryPoint to enable signature
     * verification during UserOp validation.
     * @dev The Key ID of a WebAuthn P256 should be used for data retention, otherwise a random string should be used
     * @param _owner The address of the EOA owner to set
     * @param _keyIds The list of key Ids to be added
     * @param _xValues List of Public key's X coordinates
     * @param _yValues List of Public key's Y coordinates
     */
    function initialize(
        address _owner,
        string[] calldata _keyIds,
        uint256[] calldata _xValues,
        uint256[] calldata _yValues
    )
        external
        initializer
    {
        _updateSigners(_owner, _keyIds, _xValues, _yValues, false);
    }

    /**
     * @notice Reinitializes the HybridDeleGator state by setting the owners.
     * @dev Call this method when updating logic contracts on the DeleGatorProxy
     * @dev The owner SHOULD be an EOA. Contract owners require staking in the EntryPoint to enable signature
     * verification during UserOp validation.
     * @dev Used by UUPS proxies to initialize the contract state
     * @param _version The initilized version number of the proxy using this logic contract
     * @param _owner The address of the EOA owner to set
     * @param _keyIds The list of key Ids to be added
     * @param _xValues List of Public key's X coordinates
     * @param _yValues List of Public key's Y coordinates
     * @param _deleteP256Keys Boolean indicating whether to delete the P256 keys
     */
    function reinitialize(
        uint8 _version,
        address _owner,
        string[] calldata _keyIds,
        uint256[] calldata _xValues,
        uint256[] calldata _yValues,
        bool _deleteP256Keys
    )
        external
        reinitializer(_version)
        onlyEntryPointOrSelf
    {
        _updateSigners(_owner, _keyIds, _xValues, _yValues, _deleteP256Keys);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Adds a new key as a signer that can sign on behalf of the DeleGator
     * @param _keyId The ID of the key to be added
     * @param _x Public key's X coordinate
     * @param _y Public key's Y coordinate
     */
    function addKey(string calldata _keyId, uint256 _x, uint256 _y) external onlyEntryPointOrSelf {
        _addKey(_keyId, _x, _y);
    }

    /**
     * @notice Removes an existing key from the list of signers
     * @param _keyId The ID of the key to be removed
     */
    function removeKey(string calldata _keyId) external onlyEntryPointOrSelf {
        HybridDeleGatorStorage storage s_ = _getDeleGatorStorage();
        bytes32 keyIdHash_ = keccak256(abi.encodePacked(_keyId));
        P256PublicKey memory publicKey_ = s_.authorizedKeys[keyIdHash_];
        uint256 x_ = publicKey_.x;
        uint256 y_ = publicKey_.y;

        if (x_ == 0 && y_ == 0) revert KeyDoesNotExist(keyIdHash_);

        uint256 keyIdHashesCount_ = s_.keyIdHashes.length;

        if (keyIdHashesCount_ == 1 && s_.owner == address(0)) revert CannotRemoveLastSigner();

        for (uint256 i = 0; i < keyIdHashesCount_ - 1; ++i) {
            if (s_.keyIdHashes[i] == keyIdHash_) {
                s_.keyIdHashes[i] = s_.keyIdHashes[keyIdHashesCount_ - 1];
                break;
            }
        }
        s_.keyIdHashes.pop();

        delete s_.authorizedKeys[keyIdHash_];
        emit RemovedP256Key(keyIdHash_, x_, y_);
    }

    /**
     * @notice Returns the P256 public key coordinates of a given key ID if it is a signer
     * @param _keyId The ID of the key to get
     * @return x_ The X value of the public key
     * @return y_ The Y value of the public key
     */
    function getKey(string calldata _keyId) external view returns (uint256 x_, uint256 y_) {
        HybridDeleGatorStorage storage s_ = _getDeleGatorStorage();
        P256PublicKey memory publicKey_ = s_.authorizedKeys[keccak256(abi.encodePacked(_keyId))];
        x_ = publicKey_.x;
        y_ = publicKey_.y;
    }

    /**
     * @notice Returns all P256 key IDs that are signers for this contract
     */
    function getKeyIdHashes() external view returns (bytes32[] memory) {
        HybridDeleGatorStorage storage s_ = _getDeleGatorStorage();
        return s_.keyIdHashes;
    }

    /**
     * @notice Returns count of signer P256 keys
     */
    function getKeyIdHashesCount() external view returns (uint256) {
        HybridDeleGatorStorage storage s_ = _getDeleGatorStorage();
        return s_.keyIdHashes.length;
    }

    /**
     * @notice Updates all P256 signers and the owner of the contract
     * @param _owner The address of the owner to set
     * @param _keyIds The list of key Ids to be added
     * @param _xValues List of Public key's X coordinates
     * @param _yValues List of Public key's Y coordinates
     */
    function updateSigners(
        address _owner,
        string[] calldata _keyIds,
        uint256[] calldata _xValues,
        uint256[] calldata _yValues
    )
        external
        onlyEntryPointOrSelf
    {
        _updateSigners(_owner, _keyIds, _xValues, _yValues, true);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        HybridDeleGatorStorage storage s_ = _getDeleGatorStorage();
        return s_.owner;
    }

    /**
     * @notice Transfers ownership of the contract to a new account.
     * @param _newOwner The address of the new owner
     */
    function transferOwnership(address _newOwner) external virtual onlyEntryPointOrSelf {
        _transferOwnership(_newOwner);
    }

    /**
     * @dev Removes the owner of the contract.
     */
    function renounceOwnership() external virtual onlyEntryPointOrSelf {
        _transferOwnership(address(0));
    }

    /**
     * @inheritdoc DeleGatorCore
     * @dev Supports the following interfaces: ERC173
     */
    function supportsInterface(bytes4 _interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(_interfaceId) || _interfaceId == type(IERC173).interfaceId;
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Adds a new P256 key as a signer that can sign on behalf of the DeleGator
     * @param _keyId The ID of the key to be added
     * @param _x Public key's X coordinate
     * @param _y Public key's Y coordinate
     */
    function _addKey(string calldata _keyId, uint256 _x, uint256 _y) internal {
        if (!P256SCLVerifierLib.isValidPublicKey(_x, _y)) revert KeyNotOnCurve(_x, _y);
        bytes32 keyIdHash_ = keccak256(abi.encodePacked(_keyId));

        if (bytes(_keyId).length == 0) revert InvalidEmptyKey();
        HybridDeleGatorStorage storage s_ = _getDeleGatorStorage();

        P256PublicKey storage publicKey_ = s_.authorizedKeys[keyIdHash_];
        if (publicKey_.x != 0 || publicKey_.y != 0) revert KeyAlreadyExists(keyIdHash_);

        s_.authorizedKeys[keyIdHash_] = P256PublicKey(_x, _y);
        s_.keyIdHashes.push(keyIdHash_);

        emit AddedP256Key(keyIdHash_, _keyId, _x, _y);
    }

    /**
     * @dev Transfers the ownership of the contract to a new owner.
     * @param _newOwner The new owner's address
     */
    function _transferOwnership(address _newOwner) internal {
        HybridDeleGatorStorage storage s_ = _getDeleGatorStorage();
        if (s_.keyIdHashes.length == 0 && _newOwner == address(0)) revert CannotRemoveLastSigner();

        address oldOwner_ = s_.owner;
        s_.owner = _newOwner;
        emit IERC173.OwnershipTransferred(oldOwner_, _newOwner);
    }

    /**
     * @notice Updates all P256 signers and the owner of the contract
     * @param _owner The address of the EOA owner to set
     * @param _keyIds The list of key Ids to be added
     * @param _xValues List of Public key's X coordinates
     * @param _yValues List of Public key's Y coordinates
     * @param _deleteP256Keys Boolean indicating whether to delete the P256 keys
     */
    function _updateSigners(
        address _owner,
        string[] calldata _keyIds,
        uint256[] calldata _xValues,
        uint256[] calldata _yValues,
        bool _deleteP256Keys
    )
        internal
    {
        uint256 keysLength_ = _keyIds.length;
        if (_owner == address(0) && keysLength_ == 0 && _deleteP256Keys) revert SignersCannotBeEmpty();
        if (keysLength_ != _xValues.length || keysLength_ != _yValues.length) {
            revert InputLengthsMismatch(keysLength_, _xValues.length, _yValues.length);
        }

        if (_deleteP256Keys) {
            HybridDeleGatorStorage storage s_ = _getDeleGatorStorage();
            uint256 keyIdHashesCount_ = s_.keyIdHashes.length;
            if (keyIdHashesCount_ != 0) {
                for (uint256 i = 0; i < keyIdHashesCount_; ++i) {
                    bytes32 keyIdHash_ = s_.keyIdHashes[i];
                    P256PublicKey memory pubKey_ = s_.authorizedKeys[keyIdHash_];
                    delete s_.authorizedKeys[keyIdHash_];
                    emit RemovedP256Key(keyIdHash_, pubKey_.x, pubKey_.y);
                }
                delete s_.keyIdHashes;
            }
        }

        for (uint256 i = 0; i < keysLength_; ++i) {
            _addKey(_keyIds[i], _xValues[i], _yValues[i]);
        }

        _transferOwnership(_owner);
    }

    /**
     * @notice Clears the Hybrid DeleGator storage struct
     * @dev Prepares contract storage for a UUPS proxy to migrate to a new implementation
     */
    function _clearDeleGatorStorage() internal override {
        HybridDeleGatorStorage storage s_ = _getDeleGatorStorage();
        uint256 keyIdHashesCount_ = s_.keyIdHashes.length;
        for (uint256 i = 0; i < keyIdHashesCount_; ++i) {
            delete s_.authorizedKeys[s_.keyIdHashes[i]];
        }
        delete s_.keyIdHashes;
        delete s_.owner;

        emit ClearedStorage();
    }

    /**
     * @notice Verifies if signatures are authorized.
     * @dev This contract supports EOA, raw P256 and WebAuthn P256 signatures.
     * @dev Raw P256 signature bytes: keyId hash, r, s
     * @dev WebAuthn P256 signature bytes: keyId hash, r, s, challenge, authenticatorData, requireUserVerification,
     * clientDataJSON, challengeLocation, responseTypeLocation
     * @param _hash The hash of the data signed
     * @param _signature Signature of the data signed. See above for the format of the signature.
     * @return Returns ERC1271Lib.EIP1271_MAGIC_VALUE if the recovered address matches an authorized address, returns
     * ERC1271Lib.SIG_VALIDATION_FAILED on a signature mismatch or reverts on an error
     */
    function _isValidSignature(bytes32 _hash, bytes calldata _signature) internal view override returns (bytes4) {
        uint256 sigLength_ = _signature.length;
        if (sigLength_ == 65) {
            if (ECDSA.recover(_hash, _signature) == owner()) return ERC1271Lib.EIP1271_MAGIC_VALUE;
            return ERC1271Lib.SIG_VALIDATION_FAILED;
        } else {
            if (sigLength_ < 96) return ERC1271Lib.SIG_VALIDATION_FAILED;

            HybridDeleGatorStorage storage s_ = _getDeleGatorStorage();
            bytes32 keyIdHash_ = bytes32(_signature[:32]);

            P256PublicKey memory key_ = s_.authorizedKeys[keyIdHash_];
            if (key_.x == 0 && key_.y == 0) return ERC1271Lib.SIG_VALIDATION_FAILED;

            if (sigLength_ == 96 && P256VerifierLib._verifyRawP256Signature(_hash, _signature, key_.x, key_.y)) {
                return ERC1271Lib.EIP1271_MAGIC_VALUE;
            } else if (sigLength_ != 96 && P256VerifierLib._verifyWebAuthnP256Signature(_hash, _signature, key_.x, key_.y)) {
                return ERC1271Lib.EIP1271_MAGIC_VALUE;
            }
            return ERC1271Lib.SIG_VALIDATION_FAILED;
        }
    }

    /**
     * @notice This method loads the storage struct for the DeleGator implementation.
     */
    function _getDeleGatorStorage() internal pure returns (HybridDeleGatorStorage storage s_) {
        assembly {
            s_.slot := DELEGATOR_STORAGE_LOCATION
        }
    }
}
