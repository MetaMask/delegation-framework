// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IDeleGatorCore } from "../interfaces/IDeleGatorCore.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IERC7821 } from "../interfaces/IERC7821.sol";
import { CALLTYPE_BATCH, CALLTYPE_SINGLE, EXECTYPE_DEFAULT, EXECTYPE_TRY, MODE_DEFAULT } from "../utils/Constants.sol";
import { CallType, Delegation, Execution, ExecType, ModeCode, ModePayload, ModeSelector } from "../utils/Types.sol";

/**
 * @title EIP7702MultiManagerDeleGatorCore
 * @notice EIP-7702 account core with two permanent default DelegationManagers and mutable additional DelegationManagers.
 * @dev Every approved DelegationManager has full root execution authority, including authority to self-call this account.
 * @dev Unknown, unofficial, unaudited, or upgradeable DelegationManagers can compromise the account. Users and
 * integrators must carefully verify and trust each DelegationManager before configuring or approving it.
 * @dev Any child contract adding state variables must use namespaced storage for safe EIP-7702 implementation changes.
 */
abstract contract EIP7702MultiManagerDeleGatorCore is
    ExecutionHelper,
    IERC165,
    IERC7821,
    IDeleGatorCore,
    IERC721Receiver,
    IERC1155Receiver
{
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;
    using ModeLib for ModeSelector;

    ////////////////////////////// Structs //////////////////////////////

    /// @custom:storage-location erc7201:DeleGator.EIP7702MultiManager.v1
    struct MultiManagerStorage {
        mapping(address delegationManager => bool approved) isApprovedDelegationManager;
    }

    ////////////////////////////// State //////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable __self = address(this);

    /// @dev ERC-7201 slot for erc7201:DeleGator.EIP7702MultiManager.v1.
    bytes32 private constant MULTI_MANAGER_STORAGE_LOCATION = 0x4ffe8763039a0c1b60d7504fab186e7e570dca76b49af35bcd94b7cdae58b300;

    /// @notice The first permanent DelegationManager.
    IDelegationManager public immutable defaultDelegationManager1;

    /// @notice The second permanent DelegationManager.
    IDelegationManager public immutable defaultDelegationManager2;

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when an additional DelegationManager is approved.
     * @param delegationManager The approved DelegationManager.
     */
    event ApprovedDelegationManager(IDelegationManager indexed delegationManager);

    /**
     * @notice Emitted when an additional DelegationManager is revoked.
     * @param delegationManager The revoked DelegationManager.
     */
    event RevokedDelegationManager(IDelegationManager indexed delegationManager);

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when the caller is not this contract.
    error NotSelf();

    /// @dev The zero address cannot be configured as a DelegationManager.
    error InvalidDelegationManager();

    /// @dev A DelegationManager must have deployed code.
    error DelegationManagerHasNoCode(IDelegationManager delegationManager);

    /// @dev The two default DelegationManagers must be distinct.
    error DuplicateDefaultDelegationManager();

    /// @dev The DelegationManager is already approved.
    error DelegationManagerAlreadyApproved(IDelegationManager delegationManager);

    /// @dev The DelegationManager is not approved.
    error DelegationManagerNotApproved(IDelegationManager delegationManager);

    /// @dev A permanent default DelegationManager cannot be revoked.
    error DefaultDelegationManagerCannotBeRevoked(IDelegationManager delegationManager);

    /// @dev The call is from an unauthorized context.
    error UnauthorizedCallContext();

    /// @dev Error thrown when an execution with an unsupported CallType was made.
    error UnsupportedCallType(CallType callType);

    /// @dev Error thrown when an execution with an unsupported ExecType was made.
    error UnsupportedExecType(ExecType execType);

    ////////////////////////////// Modifiers //////////////////////////////

    /**
     * @dev Prevents direct calls to the implementation.
     * @dev Under EIP-7702 the delegated account runs in the EOA context, so `address(this) != __self`.
     */
    modifier onlyProxy() {
        if (address(this) == __self) revert UnauthorizedCallContext();
        _;
    }

    /// @notice Requires the function call to come from the EIP-7702 account itself.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /// @notice Requires the caller to be a default or approved additional DelegationManager.
    modifier onlyDelegationManager() {
        if (!_isApprovedDelegationManager(msg.sender)) {
            revert DelegationManagerNotApproved(IDelegationManager(msg.sender));
        }
        _;
    }

    /// @dev Requires the selected DelegationManager to be a default or approved additional DelegationManager.
    modifier onlyApprovedDelegationManager(IDelegationManager _delegationManager) {
        if (!_isApprovedDelegationManager(address(_delegationManager))) {
            revert DelegationManagerNotApproved(_delegationManager);
        }
        _;
    }

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Configures the two permanent default DelegationManagers.
     * @param _defaultDelegationManager1 The first permanent DelegationManager.
     * @param _defaultDelegationManager2 The second permanent DelegationManager.
     */
    constructor(IDelegationManager _defaultDelegationManager1, IDelegationManager _defaultDelegationManager2) {
        _validateDelegationManager(_defaultDelegationManager1);
        _validateDelegationManager(_defaultDelegationManager2);
        if (_defaultDelegationManager1 == _defaultDelegationManager2) revert DuplicateDefaultDelegationManager();

        defaultDelegationManager1 = _defaultDelegationManager1;
        defaultDelegationManager2 = _defaultDelegationManager2;
    }

    ////////////////////////////// External Methods //////////////////////////////

    /// @notice Allows this contract to receive the chain's native token.
    receive() external payable { }

    /**
     * @notice Approves an additional DelegationManager with full root execution authority.
     * @dev A direct EOA self-transaction or DelegationManager-driven self-call may call this function.
     * @param _delegationManager The additional DelegationManager to approve.
     */
    function approveDelegationManager(IDelegationManager _delegationManager) external onlySelf {
        _validateDelegationManager(_delegationManager);
        if (_isApprovedDelegationManager(address(_delegationManager))) {
            revert DelegationManagerAlreadyApproved(_delegationManager);
        }

        _getMultiManagerStorage().isApprovedDelegationManager[address(_delegationManager)] = true;
        emit ApprovedDelegationManager(_delegationManager);
    }

    /**
     * @notice Revokes an additional DelegationManager.
     * @dev Permanent default DelegationManagers cannot be revoked.
     * @param _delegationManager The additional DelegationManager to revoke.
     */
    function revokeDelegationManager(IDelegationManager _delegationManager) external onlySelf {
        if (_isDefaultDelegationManager(address(_delegationManager))) {
            revert DefaultDelegationManagerCannotBeRevoked(_delegationManager);
        }

        MultiManagerStorage storage multiManagerStorage_ = _getMultiManagerStorage();
        if (!multiManagerStorage_.isApprovedDelegationManager[address(_delegationManager)]) {
            revert DelegationManagerNotApproved(_delegationManager);
        }

        multiManagerStorage_.isApprovedDelegationManager[address(_delegationManager)] = false;
        emit RevokedDelegationManager(_delegationManager);
    }

    /**
     * @notice Redeems delegations through a selected approved DelegationManager.
     * @param _delegationManager The DelegationManager through which to redeem.
     * @param _permissionContexts Delegation chains ordered from leaf to root.
     * @param _modes Execution modes corresponding to each chain.
     * @param _executionCallDatas Encoded executions corresponding to each chain.
     */
    function redeemDelegations(
        IDelegationManager _delegationManager,
        bytes[] calldata _permissionContexts,
        ModeCode[] calldata _modes,
        bytes[] calldata _executionCallDatas
    )
        external
        onlySelf
        onlyApprovedDelegationManager(_delegationManager)
    {
        _delegationManager.redeemDelegations(_permissionContexts, _modes, _executionCallDatas);
    }

    /**
     * @notice Executes a single call from this account.
     * @param _execution The execution to perform.
     */
    function execute(Execution calldata _execution) external payable onlySelf {
        _execute(_execution.target, _execution.value, _execution.callData);
    }

    /**
     * @notice Executes calls from this account using an ERC-7579 execution mode.
     * @param _mode The execution mode.
     * @param _executionCalldata The encoded execution data.
     */
    function execute(ModeCode _mode, bytes calldata _executionCalldata) external payable onlySelf {
        (CallType callType_, ExecType execType_) = _validateExecutionMode(_mode);

        if (callType_ == CALLTYPE_BATCH) {
            Execution[] calldata executions_ = _executionCalldata.decodeBatch();
            if (execType_ == EXECTYPE_DEFAULT) _execute(executions_);
            else if (execType_ == EXECTYPE_TRY) _tryExecute(executions_);
            else revert UnsupportedExecType(execType_);
        } else if (callType_ == CALLTYPE_SINGLE) {
            (address target_, uint256 value_, bytes calldata callData_) = _executionCalldata.decodeSingle();
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
     * @dev Every default or approved additional DelegationManager has full root authority through this function.
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
        (CallType callType_, ExecType execType_) = _validateExecutionMode(_mode);

        if (callType_ == CALLTYPE_BATCH) {
            Execution[] calldata executions_ = _executionCalldata.decodeBatch();
            if (execType_ == EXECTYPE_DEFAULT) returnData_ = _execute(executions_);
            else if (execType_ == EXECTYPE_TRY) returnData_ = _tryExecute(executions_);
            else revert UnsupportedExecType(execType_);
        } else if (callType_ == CALLTYPE_SINGLE) {
            (address target_, uint256 value_, bytes calldata callData_) = _executionCalldata.decodeSingle();
            returnData_ = new bytes[](1);
            bool success_;
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
     * @inheritdoc IERC1271
     * @notice Verifies a signature from the EOA whose address hosts this delegated code.
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
    function onERC1155Received(address, address, uint256, uint256, bytes memory) external view override onlyProxy returns (bytes4) {
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
        external
        view
        override
        onlyProxy
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @notice Disables a delegation through a selected approved DelegationManager.
     * @param _delegationManager The DelegationManager that stores the disabled state.
     * @param _delegation The delegation to disable.
     */
    function disableDelegation(
        IDelegationManager _delegationManager,
        Delegation calldata _delegation
    )
        external
        onlySelf
        onlyApprovedDelegationManager(_delegationManager)
    {
        _delegationManager.disableDelegation(_delegation);
    }

    /**
     * @notice Enables a delegation through a selected approved DelegationManager.
     * @param _delegationManager The DelegationManager that stores the disabled state.
     * @param _delegation The delegation to enable.
     */
    function enableDelegation(
        IDelegationManager _delegationManager,
        Delegation calldata _delegation
    )
        external
        onlySelf
        onlyApprovedDelegationManager(_delegationManager)
    {
        _delegationManager.enableDelegation(_delegation);
    }

    /**
     * @notice Returns whether a DelegationManager is a permanent default or approved additional DelegationManager.
     * @param _delegationManager The DelegationManager to query.
     * @return Whether the DelegationManager is approved.
     */
    function isApprovedDelegationManager(IDelegationManager _delegationManager) external view returns (bool) {
        return _isApprovedDelegationManager(address(_delegationManager));
    }

    /**
     * @notice Returns whether a delegation is disabled in a selected approved DelegationManager.
     * @param _delegationManager The DelegationManager to query.
     * @param _delegationHash The delegation hash to query.
     * @return Whether the delegation is disabled.
     */
    function isDelegationDisabled(
        IDelegationManager _delegationManager,
        bytes32 _delegationHash
    )
        external
        view
        onlyApprovedDelegationManager(_delegationManager)
        returns (bool)
    {
        return _delegationManager.disabledDelegations(_delegationHash);
    }

    /**
     * @notice Returns whether an ERC-7579 execution mode is supported.
     * @param _mode The mode to validate.
     * @return Whether the mode is supported.
     */
    function supportsExecutionMode(ModeCode _mode) external view virtual override returns (bool) {
        (CallType callType_, ExecType execType_, ModeSelector modeSelector_, ModePayload modePayload_) = _mode.decode();

        return ((callType_ == CALLTYPE_SINGLE || callType_ == CALLTYPE_BATCH)
                && (execType_ == EXECTYPE_DEFAULT || execType_ == EXECTYPE_TRY) && (modeSelector_ == MODE_DEFAULT)
                && (ModePayload.unwrap(modePayload_) == bytes22(0)));
    }

    /**
     * @inheritdoc IERC165
     * @dev Supports IDeleGatorCore, IERC721Receiver, IERC1155Receiver, IERC165, IERC1271, and IERC7821.
     */
    function supportsInterface(bytes4 _interfaceId) public view virtual override(IERC165) onlyProxy returns (bool) {
        return _interfaceId == type(IDeleGatorCore).interfaceId || _interfaceId == type(IERC721Receiver).interfaceId
            || _interfaceId == type(IERC1155Receiver).interfaceId || _interfaceId == type(IERC165).interfaceId
            || _interfaceId == type(IERC1271).interfaceId || _interfaceId == type(IERC7821).interfaceId;
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Verifies a signature according to the implementing contract's signature scheme.
     * @param _hash The signed hash.
     * @param _signature The signature.
     * @return The ERC-1271 validation result.
     */
    function _isValidSignature(bytes32 _hash, bytes calldata _signature) internal view virtual returns (bytes4);

    ////////////////////////////// Private Methods //////////////////////////////

    /// @dev Returns whether an address is one of the two permanent default DelegationManagers.
    function _isDefaultDelegationManager(address _delegationManager) private view returns (bool) {
        return _delegationManager == address(defaultDelegationManager1) || _delegationManager == address(defaultDelegationManager2);
    }

    /// @dev Returns whether an address is a default or approved additional DelegationManager.
    function _isApprovedDelegationManager(address _delegationManager) private view returns (bool) {
        return _isDefaultDelegationManager(_delegationManager)
            || _getMultiManagerStorage().isApprovedDelegationManager[_delegationManager];
    }

    /// @dev Validates a DelegationManager configured in the constructor or mutable approval mapping.
    function _validateDelegationManager(IDelegationManager _delegationManager) private view {
        address delegationManager_ = address(_delegationManager);
        if (delegationManager_ == address(0)) revert InvalidDelegationManager();
        if (delegationManager_.code.length == 0) revert DelegationManagerHasNoCode(_delegationManager);
    }

    /// @dev Validates mode selector and payload before execution and returns its call and execution types.
    function _validateExecutionMode(ModeCode _mode) private pure returns (CallType callType_, ExecType execType_) {
        ModeSelector modeSelector_;
        ModePayload modePayload_;
        (callType_, execType_, modeSelector_, modePayload_) = _mode.decode();
        if (
            ModeSelector.unwrap(modeSelector_) != ModeSelector.unwrap(MODE_DEFAULT)
                || ModePayload.unwrap(modePayload_) != bytes22(0)
        ) {
            revert UnsupportedCallType(callType_);
        }
    }

    /// @dev Returns the namespaced mutable additional-DelegationManager storage.
    function _getMultiManagerStorage() private pure returns (MultiManagerStorage storage multiManagerStorage_) {
        bytes32 location_ = MULTI_MANAGER_STORAGE_LOCATION;
        assembly {
            multiManagerStorage_.slot := location_
        }
    }
}
