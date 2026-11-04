// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";

import { IDeleGatorCore } from "../interfaces/IDeleGatorCore.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IERC7821 } from "../interfaces/IERC7821.sol";
import { CallType, ExecType, ModeSelector, ModePayload, Execution, Delegation, ModeCode } from "../utils/Types.sol";
import { CALLTYPE_SINGLE, CALLTYPE_BATCH, EXECTYPE_DEFAULT, EXECTYPE_TRY, MODE_DEFAULT } from "../utils/Constants.sol";

/// @custom:storage-location erc7201:DeleGator.EIP7702MultiManager
struct EIP7702MultiManagerStorage {
    // Set of DelegationManager addresses approved to call `executeFromExecutor` on this account (have root access).
    mapping(address delegationManager => bool approved) isApprovedDelegationManager;
}

/**
 * @title EIP7702MultiManagerDeleGatorCore
 * @notice A multi-manager EIP-7702 account.
 * @dev Where {EIP7702DeleGatorCore} hard-codes a single `immutable delegationManager`, this core stores a SET of approved
 *      DelegationManagers in EIP-7201 namespaced storage. `onlyDelegationManager` is a set-membership check, so one EIP-7702
 *      account can authorize both the canonical `DelegationManager` and a specialized `SimpleDelegationManager` (plus future
 *      managers) at once and route each action to the right one — no re-delegating and no switching between 7702 accounts.
 * @dev This account is NOT ERC-4337 compatible: all EntryPoint / UserOperation plumbing has been removed. It is driven only
 *      by (a) approved DelegationManagers via `executeFromExecutor`, and (b) the account itself (the EIP-7702 EOA calling
 *      itself) via the self-gated methods. Signatures are validated via ERC-1271 (`isValidSignature`).
 * @dev Namespaced storage is used so the approved-manager set never collides with other code sharing the EOA's storage under
 *      EIP-7702.
 */
abstract contract EIP7702MultiManagerDeleGatorCore is
    ExecutionHelper,
    IERC165,
    IERC7821,
    IDeleGatorCore,
    IERC721Receiver,
    IERC1155Receiver
{
    using ModeLib for ModeCode;
    using ModeLib for ModeSelector;
    using ExecutionLib for bytes;

    ////////////////////////////// State //////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable __self = address(this);

    /// @dev The ERC-7201 namespaced storage location for the approved-manager set.
    /// @dev keccak256(abi.encode(uint256(keccak256("DeleGator.EIP7702MultiManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MULTI_MANAGER_STORAGE_LOCATION = 0x49e56a63dc56241c65d46138ca3c27c5bf7b4df245f96cb568e8e7ba7c940400;

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when a DelegationManager is approved to drive this account
    event ApprovedDelegationManager(IDelegationManager indexed delegationManager);

    /// @dev Emitted when a DelegationManager's approval is revoked
    event RevokedDelegationManager(IDelegationManager indexed delegationManager);

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when the caller is not this contract (self).
    error NotSelf();

    /// @dev Error thrown when the caller is not an approved delegation manager.
    error NotDelegationManager();

    /// @dev Error thrown when routing to a DelegationManager that is not approved.
    error UnapprovedDelegationManager();

    /// @dev The call is from an unauthorized context.
    error UnauthorizedCallContext();

    /// @dev Error thrown when an execution with an unsupported CallType was made.
    error UnsupportedCallType(CallType callType);

    /// @dev Error thrown when an execution with an unsupported ExecType was made.
    error UnsupportedExecType(ExecType execType);

    ////////////////////////////// Modifiers //////////////////////////////

    /**
     * @dev Prevents direct calls to the implementation. Under EIP-7702 the etched account runs in the EOA context, so
     *      `address(this) != __self` and the check passes.
     */
    modifier onlyProxy() {
        if (address(this) == __self) revert UnauthorizedCallContext();
        _;
    }

    /**
     * @notice Require the function call to come from the account itself (the EIP-7702 EOA calling itself).
     */
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /**
     * @notice Require the function call to come from an APPROVED DelegationManager.
     * @dev Set-membership check against the EIP-7201 namespaced approved-manager set.
     */
    modifier onlyDelegationManager() {
        if (!_getMultiManagerStorage().isApprovedDelegationManager[msg.sender]) revert NotDelegationManager();
        _;
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Allows this contract to receive the chain's native token.
     */
    receive() external payable { }

    /**
     * @notice Approves a DelegationManager to drive this account (grant it root access via `executeFromExecutor`).
     * @dev MUST be called by the account itself.
     * @param _delegationManager The DelegationManager to approve.
     */
    function approveDelegationManager(IDelegationManager _delegationManager) external onlySelf {
        _getMultiManagerStorage().isApprovedDelegationManager[address(_delegationManager)] = true;
        emit ApprovedDelegationManager(_delegationManager);
    }

    /**
     * @notice Revokes a DelegationManager's approval.
     * @dev MUST be called by the account itself.
     * @param _delegationManager The DelegationManager to revoke.
     */
    function revokeDelegationManager(IDelegationManager _delegationManager) external onlySelf {
        delete _getMultiManagerStorage().isApprovedDelegationManager[address(_delegationManager)];
        emit RevokedDelegationManager(_delegationManager);
    }

    /**
     * @notice Returns whether a DelegationManager is approved to drive this account.
     */
    function isApprovedDelegationManager(IDelegationManager _delegationManager) external view returns (bool) {
        return _getMultiManagerStorage().isApprovedDelegationManager[address(_delegationManager)];
    }

    /**
     * @notice Redeems delegations on a chosen APPROVED DelegationManager and executes on behalf of the root delegator.
     * @param _delegationManager The approved DelegationManager to route through.
     * @param _permissionContexts See {IDelegationManager.redeemDelegations}.
     * @param _modes See {IDelegationManager.redeemDelegations}.
     * @param _executionCallDatas See {IDelegationManager.redeemDelegations}.
     */
    function redeemDelegations(
        IDelegationManager _delegationManager,
        bytes[] calldata _permissionContexts,
        ModeCode[] calldata _modes,
        bytes[] calldata _executionCallDatas
    )
        external
        onlySelf
    {
        if (!_getMultiManagerStorage().isApprovedDelegationManager[address(_delegationManager)]) {
            revert UnapprovedDelegationManager();
        }
        _delegationManager.redeemDelegations(_permissionContexts, _modes, _executionCallDatas);
    }

    /**
     * @notice Executes a single Execution from this contract.
     * @param _execution The Execution to be executed
     */
    function execute(Execution calldata _execution) external payable onlySelf {
        _execute(_execution.target, _execution.value, _execution.callData);
    }

    /**
     * @notice Executes an Execution from this contract (ERC-7821 / ERC-7579 modes).
     * @param _mode The ModeCode for the execution
     * @param _executionCalldata The calldata for the execution
     */
    function execute(ModeCode _mode, bytes calldata _executionCalldata) external payable onlySelf {
        (CallType callType_, ExecType execType_,,) = _mode.decode();

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
     * @dev Gated by the approved-manager set membership check.
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
     * @notice Verifies the signature of the signer.
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
     * @notice Disables a delegation on a chosen approved DelegationManager.
     * @param _delegationManager The approved DelegationManager that owns the delegation state.
     * @param _delegation The delegation to be disabled
     */
    function disableDelegation(IDelegationManager _delegationManager, Delegation calldata _delegation) external onlySelf {
        if (!_getMultiManagerStorage().isApprovedDelegationManager[address(_delegationManager)]) {
            revert UnapprovedDelegationManager();
        }
        _delegationManager.disableDelegation(_delegation);
    }

    /**
     * @notice Checks if a delegation is disabled on a given DelegationManager.
     */
    function isDelegationDisabled(IDelegationManager _delegationManager, bytes32 _delegationHash) external view returns (bool) {
        return _delegationManager.disabledDelegations(_delegationHash);
    }

    /**
     * @notice Returns a boolean indicating if a mode is supported.
     * @param _mode The mode to validate
     */
    function supportsExecutionMode(ModeCode _mode) external view virtual override returns (bool) {
        (CallType callType_, ExecType execType_, ModeSelector modeSelector_, ModePayload modePayload_) = _mode.decode();

        return ((callType_ == CALLTYPE_SINGLE || callType_ == CALLTYPE_BATCH)
                && (execType_ == EXECTYPE_DEFAULT || execType_ == EXECTYPE_TRY) && (modeSelector_ == MODE_DEFAULT)
                && (ModePayload.unwrap(modePayload_) == bytes22(0x00)));
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 _interfaceId) public view virtual override(IERC165) onlyProxy returns (bool) {
        return _interfaceId == type(IDeleGatorCore).interfaceId || _interfaceId == type(IERC721Receiver).interfaceId
            || _interfaceId == type(IERC1155Receiver).interfaceId || _interfaceId == type(IERC165).interfaceId
            || _interfaceId == type(IERC1271).interfaceId || _interfaceId == type(IERC7821).interfaceId;
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Loads the ERC-7201 namespaced storage struct for the multi-manager account.
     */
    function _getMultiManagerStorage() internal pure returns (EIP7702MultiManagerStorage storage s_) {
        assembly {
            s_.slot := MULTI_MANAGER_STORAGE_LOCATION
        }
    }

    /**
     * @notice The logic to verify if the signature is valid for this contract.
     * @dev Overridden by the implementing contract based on the signature scheme used.
     */
    function _isValidSignature(bytes32 _hash, bytes calldata _signature) internal view virtual returns (bytes4);
}
