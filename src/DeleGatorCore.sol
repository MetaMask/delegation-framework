// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import { ERC1271Lib } from "./libraries/ERC1271Lib.sol";
import { IDeleGatorCore } from "./interfaces/IDeleGatorCore.sol";
import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { Action, Delegation, PackedUserOperation } from "./utils/Types.sol";
import { ExecutionLib } from "./libraries/ExecutionLib.sol";

/**
 * @title DeleGatorCore
 * @notice This contract contains the shared logic for a DeleGator SCA implementation.
 * @dev Implements the interface needed for a DelegationManager to interact with a DeleGator implementation.
 * @dev DeleGator implementations can inherit this to enable Delegation, ERC4337 and UUPS.
 * @dev DeleGator implementations MUST use Namespaced Storage to ensure subsequent UUPS implementation updates are safe.
 */
abstract contract DeleGatorCore is Initializable, UUPSUpgradeable, IERC165, IDeleGatorCore, IERC721Receiver, IERC1155Receiver {
    using MessageHashUtils for bytes32;

    ////////////////////////////// State //////////////////////////////

    /// @dev The DelegationManager contract that has root access to this contract
    IDelegationManager public immutable delegationManager;

    /// @dev The EntryPoint contract that has root access to this contract
    IEntryPoint public immutable entryPoint;

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when the Delegation manager is set
    event SetDelegationManager(IDelegationManager indexed newDelegationManager);

    /// @dev Emitted when the EntryPoint is set
    event SetEntryPoint(IEntryPoint indexed entryPoint);

    /// @dev Emitted when the storage is cleared
    event ClearedStorage();

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when the caller is not this contract.
    error NotSelf();

    /// @dev Error thrown when the caller is not the entry point.
    error NotEntryPoint();

    /// @dev Error thrown when the caller is not the EntryPoint or this contract.
    error NotEntryPointOrSelf();

    /// @dev Error thrown when the caller is not the delegation manager.
    error NotDelegationManager();

    ////////////////////////////// Modifiers //////////////////////////////

    /**
     * @notice Require the function call to come from the EntryPoint.
     * @dev Check that the caller is the entry point
     */
    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();
        _;
    }

    /**
     * @notice Require the function call to come from the EntryPoint or this contract.
     * @dev Check that the caller is either the delegator contract itself or the entry point
     */
    modifier onlyEntryPointOrSelf() {
        if (msg.sender != address(entryPoint) && msg.sender != address(this)) revert NotEntryPointOrSelf();
        _;
    }

    /**
     * @notice Require the function call to come from the DelegationManager.
     * @dev Check that the caller is the stored delegation manager.
     */
    modifier onlyDelegationManager() {
        if (msg.sender != address(delegationManager)) revert NotDelegationManager();
        _;
    }

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the DeleGatorCore contract
     * @custom:oz-upgrades-unsafe-allow constructor
     * @param _delegationManager the address of the trusted DelegationManager contract that will have root access to this contract
     */
    constructor(IDelegationManager _delegationManager, IEntryPoint _entryPoint) {
        _disableInitializers();
        delegationManager = _delegationManager;
        entryPoint = _entryPoint;
        emit SetDelegationManager(_delegationManager);
        emit SetEntryPoint(_entryPoint);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Allows this contract to receive the chains native token
     */
    receive() external payable { }

    /**
     * @notice Redeems a delegation on the DelegationManager and executes the action as the root delegator
     * @dev `_data` is made up of an array of `Delegation` structs that are used to validate the authority given to execute the
     * action
     * on the root delegator ordered from leaf to root.
     * @param _data the data used to validate the authority given to execute the action
     * @param _action The action to be executed
     */
    function redeemDelegation(bytes calldata _data, Action calldata _action) external onlyEntryPointOrSelf {
        delegationManager.redeemDelegation(_data, _action);
    }

    /// @inheritdoc IDeleGatorCore
    function executeDelegatedAction(Action calldata _action) external onlyDelegationManager {
        ExecutionLib._execute(_action);
    }

    /**
     * @notice Executes an Action from this contract
     * @dev This method is intended to be called through a UserOp which ensures the invoker has sufficient permissions
     * @dev This method reverts if the action fails.
     * @param _action the action to execute
     */
    function execute(Action calldata _action) external onlyEntryPoint {
        ExecutionLib._execute(_action);
    }

    /**
     * @notice This method executes several Actions in order.
     * @dev This method is intended to be called through a UserOp which ensures the invoker has sufficient permissions.
     * @dev This method reverts if any of the actions fail.
     * @param _actions the ordered actions to execute
     */
    function executeBatch(Action[] calldata _actions) external onlyEntryPointOrSelf {
        ExecutionLib._executeBatch(_actions);
    }

    /**
     * @notice Validates a UserOp signature and sends any necessary funds to the EntryPoint
     * @dev Related: ERC4337
     * @param _userOp The UserOp struct to validate
     * @param _userOpHash The hash of the UserOp struct
     * @param _missingAccountFunds The missing funds from the account
     * @return validationData_ The validation data
     */
    function validateUserOp(
        PackedUserOperation calldata _userOp,
        bytes32 _userOpHash,
        uint256 _missingAccountFunds
    )
        external
        onlyEntryPoint
        onlyProxy
        returns (uint256 validationData_)
    {
        validationData_ = _validateUserOpSignature(_userOp, _userOpHash);
        ExecutionLib._payPrefund(_missingAccountFunds);
    }

    /**
     * @inheritdoc IERC1271
     * @notice Verifies the signatures of the signers.
     * @dev Related: ERC4337, Delegation
     * @param _hash The hash of the data signed.
     * @param _signature The signatures of the signers.
     * @return magicValue_ A bytes4 magic value which is EIP1271_MAGIC_VALUE(0x1626ba7e) if the signature is valid, returns
     * SIG_VALIDATION_FAILED(0xffffffff) if there is a signature mismatch and reverts (for all other errors).
     */
    function isValidSignature(
        bytes32 _hash,
        bytes calldata _signature
    )
        external
        view
        override
        onlyProxy
        returns (bytes4 magicValue_)
    {
        return _isValidSignature(_hash, _signature);
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(address, address, uint256, bytes memory) external view override onlyProxy returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IERC1155Receiver
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    )
        external
        view
        override
        onlyProxy
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    /// @inheritdoc IERC1155Receiver
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    )
        public
        view
        override
        onlyProxy
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @notice Deposits more funds for this account in the entry point
     * @dev Related: ERC4337
     */
    function addDeposit() external payable onlyProxy {
        entryPoint.depositTo{ value: msg.value }(address(this));
    }

    /**
     * @notice This method withdraws funds of this account from the entry point
     * @dev Related: ERC4337
     * @param _withdrawAddress Address to withdraw the amount to
     * @param _withdrawAmount Amount to be withdraw from the entry point
     */
    function withdrawDeposit(address payable _withdrawAddress, uint256 _withdrawAmount) external onlyEntryPointOrSelf {
        entryPoint.withdrawTo(_withdrawAddress, _withdrawAmount);
    }

    /**
     * @notice Delegates authority to an address and caches the delegation hash onchain
     * @dev Forwards a call to the DelegationManager to delegate
     * @param _delegation The delegation to be stored
     */
    function delegate(Delegation calldata _delegation) external onlyEntryPointOrSelf {
        delegationManager.delegate(_delegation);
    }

    /**
     * @notice Disables a delegation from being used
     * @param _delegation The delegation to be disabled
     */
    function disableDelegation(Delegation calldata _delegation) external onlyEntryPointOrSelf {
        delegationManager.disableDelegation(_delegation);
    }

    /**
     * @notice Enables a delegation to be used
     * @dev Delegations only need to be enabled if they have been disabled
     * @param _delegation The delegation to be enabled
     */
    function enableDelegation(Delegation calldata _delegation) external onlyEntryPointOrSelf {
        delegationManager.enableDelegation(_delegation);
    }

    /**
     * @notice Retains storage and updates the logic contract in use.
     * @dev Related: UUPS
     * @param _newImplementation Address of the new logic contract to use.
     * @param _data Data to send as msg.data to the implementation to initialize the proxied contract.
     */
    function upgradeToAndCallAndRetainStorage(address _newImplementation, bytes memory _data) external payable {
        super.upgradeToAndCall(_newImplementation, _data);
    }

    /**
     * @notice Clears storage by default and updates the logic contract in use.
     * @dev Related: UUPS
     * @param _newImplementation Address of the new logic contract to use.
     * @param _data Data to send as msg.data to the implementation to initialize the proxied contract.
     */
    function upgradeToAndCall(address _newImplementation, bytes memory _data) public payable override {
        _clearDeleGatorStorage();
        super.upgradeToAndCall(_newImplementation, _data);
    }

    /**
     * @notice Checks if the delegation is disabled
     * @param _delegationHash the hash of the delegation to check for disabled status.
     * @return bool is the delegation disabled
     */
    function isDelegationDisabled(bytes32 _delegationHash) external view returns (bool) {
        return delegationManager.disabledDelegations(_delegationHash);
    }

    /**
     * @notice Checks if the delegation hash has been cached onchain
     * @param _delegationHash the hash of the delegation to check for
     * @return bool is the delegation stored onchain
     */
    function isDelegationOnchain(bytes32 _delegationHash) external view returns (bool) {
        return delegationManager.onchainDelegations(_delegationHash);
    }

    /**
     * @notice Gets the current account's deposit in the entry point
     * @dev Related: ERC4337
     * @return uint256 The current account's deposit in the entry point
     */
    function getDeposit() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /**
     * @notice Retrieves the address of the current UUPS Logic contract
     * @dev Related: UUPS
     * @return The address of the current UUPS Logic contract.
     */
    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /**
     * @notice Retrieves the version of the current UUPS Logic contract
     * @dev This version number is moreso the count of initializations that have occurred for this proxy contract.
     * @dev Related: UUPS
     */
    function getInitializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }

    /**
     * @notice Returns the next sequential nonce using a static key
     * @dev Related: ERC4337
     * @return uint256 The next sequential nonce
     */
    function getNonce() external view returns (uint256) {
        return entryPoint.getNonce(address(this), 0);
    }

    /**
     * @notice Returns the next sequential nonce using a custom key
     * @dev Related: ERC4337
     * @return uint256 The next sequential nonce for the key provided
     * @param _key The key to use for the nonce
     */
    function getNonce(uint192 _key) external view returns (uint256) {
        return entryPoint.getNonce(address(this), _key);
    }

    /**
     * @inheritdoc IERC165
     * @dev Supports the following interfaces: IDeleGatorCore, IERC721Receiver, IERC1155Receiver, IERC165, IERC1271
     */
    function supportsInterface(bytes4 _interfaceId) public view virtual override(IERC165) onlyProxy returns (bool) {
        return _interfaceId == type(IDeleGatorCore).interfaceId || _interfaceId == type(IERC721Receiver).interfaceId
            || _interfaceId == type(IERC1155Receiver).interfaceId || _interfaceId == type(IERC165).interfaceId
            || _interfaceId == type(IERC1271).interfaceId;
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice The logic to verify if the signature is valid for this contract
     * @dev This is an internal function that should be overridden by the implementing contract based on the signature scheme used.
     * @dev Related: ERC4337
     * @param _hash The hash of the data signed.
     * @param _signature The signatures of the signers.
     * @return A bytes4 magic value which is EIP1271_MAGIC_VALUE(0x1626ba7e) if the signature is valid, returns
     * SIG_VALIDATION_FAILED(0xffffffff) if there is a signature mismatch and reverts (for all other errors).
     */
    function _isValidSignature(bytes32 _hash, bytes calldata _signature) internal view virtual returns (bytes4);

    /**
     * @notice Clears the storage being used by a DeleGator Implementation
     * @dev Related: UUPS
     */
    function _clearDeleGatorStorage() internal virtual;

    /**
     * @notice Validates that the sender is allowed to upgrade the contract
     * @dev Related: UUPS
     * @dev This is needed for UUPS secure upgradeability
     * @param _newImplementation The address of the new implementation.
     */
    function _authorizeUpgrade(address _newImplementation) internal override onlyEntryPointOrSelf { }

    /**
     * @notice Validates a UserOp signature and returns a code indicating if the signature is valid or not
     * @dev This method calls the DeleGator implementations `_isValidSignature` to validate the signature according to the
     * implementations auth scheme.
     * @dev Returns 0 if the signature is valid, 1 if the signature is invalid.
     * @dev Related: ERC4337
     * @param _userOp The UserOp
     * @param _userOpHash The hash of the UserOp
     * @return validationData_ A code indicating if the signature is valid or not
     */
    function _validateUserOpSignature(
        PackedUserOperation calldata _userOp,
        bytes32 _userOpHash
    )
        internal
        view
        returns (uint256 validationData_)
    {
        bytes4 result_ = _isValidSignature(_userOpHash.toEthSignedMessageHash(), _userOp.signature);
        if (result_ == ERC1271Lib.EIP1271_MAGIC_VALUE) {
            return 0;
        } else {
            return 1;
        }
    }
}
