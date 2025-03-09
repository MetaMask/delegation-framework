// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ERC1271Lib } from "./libraries/ERC1271Lib.sol";
import { IDeleGatorCore } from "./interfaces/IDeleGatorCore.sol";
import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { CallType, ExecType, Execution, Delegation, PackedUserOperation, ModeCode } from "./utils/Types.sol";
import { CALLTYPE_SINGLE, CALLTYPE_BATCH, EXECTYPE_DEFAULT, EXECTYPE_TRY } from "./utils/Constants.sol";

/**
 * @title DeleGatorCore
 * @notice This contract contains the shared logic for a DeleGator SCA implementation.
 * @dev Implements the interface needed for a DelegationManager to interact with a DeleGator implementation.
 * @dev DeleGator implementations can inherit this to enable Delegation, ERC4337 and UUPS.
 * @dev DeleGator implementations MUST use Namespaced Storage to ensure subsequent UUPS implementation updates are safe.
 */
abstract contract DeleGatorCore is
    Initializable,
    ExecutionHelper,
    UUPSUpgradeable,
    IERC165,
    IDeleGatorCore,
    IERC721Receiver,
    IERC1155Receiver,
    EIP712
{
    using ModeLib for ModeCode;
    using ExecutionLib for bytes;

    ////////////////////////////// State //////////////////////////////

    /// @dev The DelegationManager contract that has root access to this contract
    IDelegationManager public immutable delegationManager;

    /// @dev The EntryPoint contract that has root access to this contract
    IEntryPoint public immutable entryPoint;

    /// @dev The typehash for the PackedUserOperation struct
    bytes32 public constant PACKED_USER_OP_TYPEHASH = keccak256(
        "PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,address entryPoint)"
    );

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when the Delegation manager is set
    event SetDelegationManager(IDelegationManager indexed newDelegationManager);

    /// @dev Emitted when the EntryPoint is set
    event SetEntryPoint(IEntryPoint indexed entryPoint);

    /// @dev Emitted when the storage is cleared
    event ClearedStorage();

    /// @dev Event emitted when prefunding is sent.
    event SentPrefund(address indexed sender, uint256 amount, bool success);

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when the caller is not this contract.
    error NotSelf();

    /// @dev Error thrown when the caller is not the entry point.
    error NotEntryPoint();

    /// @dev Error thrown when the caller is not the EntryPoint or this contract.
    error NotEntryPointOrSelf();

    /// @dev Error thrown when the caller is not the delegation manager.
    error NotDelegationManager();

    /// @dev Error thrown when an execution with an unsupported CallType was made
    error UnsupportedCallType(CallType callType);

    /// @dev Error thrown when an execution with an unsupported ExecType was made
    error UnsupportedExecType(ExecType execType);

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
     * @param _entryPoint the address of entry point
     * @param _name Name of the contract
     * @param _domainVersion Domain version of the contract
     */
    constructor(
        IDelegationManager _delegationManager,
        IEntryPoint _entryPoint,
        string memory _name,
        string memory _domainVersion
    )
        EIP712(_name, _domainVersion)
    {
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
     * @notice Redeems a delegation on the DelegationManager and executes the specified executions on behalf of the root delegator.
     * @param _permissionContexts An array of bytes where each element is made up of an array
     * of `Delegation` structs that are used to validate the authority given to execute the corresponding execution on the
     * root delegator, ordered from leaf to root.
     * @param _modes An array of `ModeCode` structs representing the mode of execiton for each execution callData.
     * @param _executionCallDatas An array of `Execution` structs representing the executions to be executed.
     */
    function redeemDelegations(
        bytes[] calldata _permissionContexts,
        ModeCode[] calldata _modes,
        bytes[] calldata _executionCallDatas
    )
        external
        onlyEntryPointOrSelf
    {
        delegationManager.redeemDelegations(_permissionContexts, _modes, _executionCallDatas);
    }

    /**
     * @notice Executes an Execution from this contract
     * @dev This method is intended to be called through a UserOp which ensures the invoker has sufficient permissions
     * @dev This convenience method defeaults to reverting on failure and a single execution.
     * @param _execution The Execution to be executed
     */
    function execute(Execution calldata _execution) external payable onlyEntryPoint {
        _execute(_execution.target, _execution.value, _execution.callData);
    }

    /**
     * @notice Executes an Execution from this contract
     * @dev Related: @erc7579/MSAAdvanced.sol
     * @dev This method is intended to be called through a UserOp which ensures the invoker has sufficient permissions
     * @param _mode The ModeCode for the execution
     * @param _executionCalldata The calldata for the execution
     */
    function execute(ModeCode _mode, bytes calldata _executionCalldata) external payable onlyEntryPoint {
        (CallType callType_, ExecType execType_,,) = _mode.decode();

        // Check if calltype is batch or single
        if (callType_ == CALLTYPE_BATCH) {
            // destructure executionCallData according to batched exec
            Execution[] calldata executions_ = _executionCalldata.decodeBatch();
            // Check if execType is revert or try
            if (execType_ == EXECTYPE_DEFAULT) _execute(executions_);
            else if (execType_ == EXECTYPE_TRY) _tryExecute(executions_);
            else revert UnsupportedExecType(execType_);
        } else if (callType_ == CALLTYPE_SINGLE) {
            // Destructure executionCallData according to single exec
            (address target_, uint256 value_, bytes calldata callData_) = _executionCalldata.decodeSingle();
            // Check if execType is revert or try
            if (execType_ == EXECTYPE_DEFAULT) {
                _execute(target_, value_, callData_);
            } else if (execType_ == EXECTYPE_TRY) {
                bytes[] memory returnData_ = new bytes[](1);
                bool success_;
                (success_, returnData_[0]) = _tryExecute(target_, value_, callData_);
                if (!success_) emit TryExecuteUnsuccessful(0, returnData_[0]);
            } else {
                revert UnsupportedExecType(execType_);
            }
        } else {
            revert UnsupportedCallType(callType_);
        }
    }

    /**
     * @inheritdoc IDeleGatorCore
     * @dev Related: @erc7579/MSAAdvanced.sol
     */
    function executeFromExecutor(
        ModeCode _mode,
        bytes calldata _executionCalldata
    )
        external
        payable
        onlyDelegationManager
        returns (bytes[] memory returnData_)
    {
        (CallType callType_, ExecType execType_,,) = _mode.decode();

        // Check if calltype is batch or single
        if (callType_ == CALLTYPE_BATCH) {
            // Destructure executionCallData according to batched exec
            Execution[] calldata executions_ = _executionCalldata.decodeBatch();
            // check if execType is revert or try
            if (execType_ == EXECTYPE_DEFAULT) returnData_ = _execute(executions_);
            else if (execType_ == EXECTYPE_TRY) returnData_ = _tryExecute(executions_);
            else revert UnsupportedExecType(execType_);
        } else if (callType_ == CALLTYPE_SINGLE) {
            // Destructure executionCallData according to single exec
            (address target_, uint256 value_, bytes calldata callData_) = _executionCalldata.decodeSingle();
            returnData_ = new bytes[](1);
            bool success_;
            // check if execType is revert or try
            if (execType_ == EXECTYPE_DEFAULT) {
                returnData_[0] = _execute(target_, value_, callData_);
            } else if (execType_ == EXECTYPE_TRY) {
                (success_, returnData_[0]) = _tryExecute(target_, value_, callData_);
                if (!success_) emit TryExecuteUnsuccessful(0, returnData_[0]);
            } else {
                revert UnsupportedExecType(execType_);
            }
        } else {
            revert UnsupportedCallType(callType_);
        }
    }

    /**
     * @notice Validates a UserOp signature and sends any necessary funds to the EntryPoint
     * @dev Related: ERC4337
     * @param _userOp The UserOp struct to validate
     * @param _missingAccountFunds The missing funds from the account
     * @return validationData_ The validation data
     */
    function validateUserOp(
        PackedUserOperation calldata _userOp,
        bytes32, // Ignore UserOpHash from the Entry Point
        uint256 _missingAccountFunds
    )
        external
        onlyEntryPoint
        onlyProxy
        returns (uint256 validationData_)
    {
        validationData_ = _validateUserOpSignature(_userOp, getPackedUserOperationTypedDataHash(_userOp));
        _payPrefund(_missingAccountFunds);
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
     * @notice This method returns the domain hash used for signing typed data
     * @return bytes32 The domain hash
     */
    function getDomainHash() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Returns the formatted hash to sign for an EIP712 typed data signature
     * @param _userOp the UserOp to hash
     * @notice Returns an EIP712 typed data hash for a given UserOp
     */
    function getPackedUserOperationTypedDataHash(PackedUserOperation calldata _userOp) public view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), getPackedUserOperationHash(_userOp));
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

    /**
     * Provides the typed data hash for a PackedUserOperation
     * @param _userOp the PackedUserOperation to hash
     */
    function getPackedUserOperationHash(PackedUserOperation calldata _userOp) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                PACKED_USER_OP_TYPEHASH,
                _userOp.sender,
                _userOp.nonce,
                keccak256(_userOp.initCode),
                keccak256(_userOp.callData),
                _userOp.accountGasLimits,
                _userOp.preVerificationGas,
                _userOp.gasFees,
                keccak256(_userOp.paymasterAndData),
                entryPoint
            )
        );
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
     * @param _userOpHash UserOp hash produced with typed data
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
        bytes4 result_ = _isValidSignature(_userOpHash, _userOp.signature);
        if (result_ == ERC1271Lib.EIP1271_MAGIC_VALUE) {
            return 0;
        } else {
            return 1;
        }
    }

    /**
     * @notice Sends the entrypoint (msg.sender) any needed funds for the transaction.
     * @param _missingAccountFunds the minimum value this method should send the entrypoint.
     *         this value MAY be zero, in case there is enough deposit, or the userOp has a paymaster.
     */
    function _payPrefund(uint256 _missingAccountFunds) internal {
        if (_missingAccountFunds != 0) {
            (bool success_,) = payable(msg.sender).call{ value: _missingAccountFunds, gas: type(uint256).max }("");
            (success_);
            // Ignore failure (it's EntryPoint's job to verify, not account.)
            emit SentPrefund(msg.sender, _missingAccountFunds, success_);
        }
    }
}
