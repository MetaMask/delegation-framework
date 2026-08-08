// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";

import { IDelegationManager } from "../../interfaces/IDelegationManager.sol";
import { Delegation, ModeCode, CallType, ExecType } from "../../utils/Types.sol";
import { TokenTransformationEnforcer } from "../../enforcers/TokenTransformationEnforcer.sol";
import { IAdapter } from "../interfaces/IAdapter.sol";
import { IAavePool } from "../interfaces/IAave.sol";
import { EncoderLib } from "../../libraries/EncoderLib.sol";
import { CALLTYPE_SINGLE, EXECTYPE_DEFAULT } from "../../utils/Constants.sol";

/**
 * @title AdapterManager
 * @notice Manages protocol adapters and coordinates token transformations through lending protocols
 * @dev Routes protocol interactions to specific adapters and updates enforcer state
 * @dev All tokens are transferred to the root delegator after protocol interactions
 */
contract AdapterManager is ExecutionHelper, Ownable2Step {
    using ModeLib for ModeCode;
    using ExecutionLib for bytes;
    using SafeERC20 for IERC20;

    ////////////////////////////// State //////////////////////////////

    /// @dev The DelegationManager contract
    IDelegationManager public immutable delegationManager;

    /// @dev The TokenTransformationEnforcer contract (settable by owner)
    TokenTransformationEnforcer public tokenTransformationEnforcer;

    /// @dev Mapping from protocol address to adapter address
    mapping(address protocol => address adapter) public protocolAdapters;

    /// @dev Struct to reduce stack depth
    struct ExecutionCallDataParams {
        IERC20 tokenFrom;
        uint256 amountFrom;
        address protocolAddress;
        bytes actionData;
        address rootDelegator;
        bytes32 rootDelegationHash;
        uint256 balanceBefore;
    }

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when the token transformation enforcer is set
    event TokenTransformationEnforcerSet(address indexed oldEnforcer, address indexed newEnforcer);

    /// @dev Emitted when a protocol adapter is registered
    event ProtocolAdapterRegistered(address indexed protocol, address indexed adapter);

    /// @dev Emitted when a protocol adapter is removed
    event ProtocolAdapterRemoved(address indexed protocol);

    /// @dev Emitted when tokens are transferred to root delegator
    event TokensTransferredToDelegator(address indexed token, address indexed delegator, uint256 amount);

    /// @dev Emitted when a protocol action is executed
    event ProtocolActionExecuted(
        bytes32 indexed delegationHash,
        address indexed protocol,
        string action,
        address tokenFrom,
        uint256 amountFrom,
        address tokenTo,
        uint256 amountTo
    );

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when caller is not the DelegationManager
    error NotDelegationManager();

    /// @dev Error thrown when caller is not the leaf delegator
    error NotLeafDelegator();

    /// @dev Error thrown when no adapter is registered for the protocol
    error NoAdapterForProtocol(address protocol);

    /// @dev Error thrown when delegations array is empty
    error InvalidEmptyDelegations();

    /// @dev Error thrown when address is zero
    error InvalidZeroAddress();

    /// @dev Error thrown when native token transfer fails
    error FailedNativeTokenTransfer(address recipient);

    /// @dev Error thrown when call is not from self
    error NotSelf();

    /// @dev Error thrown when insufficient tokens are received
    error InsufficientTokens();

    /// @dev Error thrown when insufficient output tokens are received from adapter
    error InsufficientOutputTokens();

    /// @dev Error thrown when unsupported call type is used
    error UnsupportedCallType(CallType callType);

    /// @dev Error thrown when unsupported execution type is used
    error UnsupportedExecType(ExecType execType);

    /// @dev Error thrown when enforcer is not set
    error EnforcerNotSet();

    /// @dev Error thrown when TokenTransformationEnforcer is not found at index 0
    error TokenTransformationEnforcerNotFound();

    ////////////////////////////// Modifiers //////////////////////////////

    modifier onlyDelegationManager() {
        if (msg.sender != address(delegationManager)) revert NotDelegationManager();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the AdapterManager
     * @param _owner The initial owner of the contract
     * @param _delegationManager The DelegationManager contract address
     */
    constructor(address _owner, IDelegationManager _delegationManager) Ownable(_owner) {
        if (address(_delegationManager) == address(0)) {
            revert InvalidZeroAddress();
        }
        delegationManager = _delegationManager;
        // tokenTransformationEnforcer is set later by owner via setTokenTransformationEnforcer()
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Allows this contract to receive native tokens
     */
    receive() external payable { }

    /**
     * @notice Sets the TokenTransformationEnforcer contract address
     * @dev Only callable by the contract owner
     * @dev Can be called multiple times to update the enforcer address
     * @param _tokenTransformationEnforcer The TokenTransformationEnforcer contract address
     */
    function setTokenTransformationEnforcer(TokenTransformationEnforcer _tokenTransformationEnforcer) external onlyOwner {
        if (address(_tokenTransformationEnforcer) == address(0)) {
            revert InvalidZeroAddress();
        }
        address oldEnforcer_ = address(tokenTransformationEnforcer);
        tokenTransformationEnforcer = _tokenTransformationEnforcer;
        emit TokenTransformationEnforcerSet(oldEnforcer_, address(_tokenTransformationEnforcer));
    }

    /**
     * @notice Executes a protocol action using delegations
     * @dev The msg.sender must be the leaf delegator
     * @param _protocolAddress The address of the lending protocol contract
     * @param _tokenFrom The input token address
     * @param _amountFrom The amount of input tokens to use
     * @param _actionData Additional data needed for the specific action (first element should be the action string)
     * @param _delegations Array of Delegation objects, sorted leaf to root
     */
    function executeProtocolActionByDelegation(
        address _protocolAddress,
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        bytes calldata _actionData,
        Delegation[] memory _delegations
    )
        external
    {
        if (_delegations.length == 0) revert InvalidEmptyDelegations();
        if (_delegations[0].delegator != msg.sender) revert NotLeafDelegator();
        if (protocolAdapters[_protocolAddress] == address(0)) revert NoAdapterForProtocol(_protocolAddress);

        _validateAndSetProtocol(_delegations, _protocolAddress);
        _executeWithDelegations(_delegations, _protocolAddress, _tokenFrom, _amountFrom, _actionData);
    }

    /**
     * @notice Executes the protocol action using delegations
     * @param _delegations The delegation chain
     * @param _protocolAddress The protocol address
     * @param _tokenFrom The input token
     * @param _amountFrom The amount to use
     * @param _actionData Additional action data (first element should be the action string)
     */
    function _executeWithDelegations(
        Delegation[] memory _delegations,
        address _protocolAddress,
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        bytes calldata _actionData
    )
        private
    {
        uint256 delegationsLength_ = _delegations.length;
        Delegation memory rootDelegation_ = _delegations[delegationsLength_ - 1];
        bytes32 rootDelegationHash_ = EncoderLib._getDelegationHash(rootDelegation_);
        address rootDelegator_ = rootDelegation_.delegator;
        uint256 balanceBefore_ = _getSelfBalance(_tokenFrom);

        ExecutionCallDataParams memory params_;
        params_.tokenFrom = _tokenFrom;
        params_.amountFrom = _amountFrom;
        params_.protocolAddress = _protocolAddress;
        params_.actionData = _actionData;
        params_.rootDelegator = rootDelegator_;
        params_.rootDelegationHash = rootDelegationHash_;
        params_.balanceBefore = balanceBefore_;

        delegationManager.redeemDelegations(_buildPermissionContexts(_delegations), _buildModes(), _buildCallDatas(params_));
    }

    /**
     * @notice Builds execution call datas array
     */
    function _buildCallDatas(ExecutionCallDataParams memory _params) private view returns (bytes[] memory executionCallDatas_) {
        executionCallDatas_ = new bytes[](2);
        executionCallDatas_[0] = _encodeTokenTransfer(_params.tokenFrom, _params.amountFrom);
        executionCallDatas_[1] = _encodeInternalActionCall(_params);
    }

    /**
     * @notice Encodes token transfer call data
     */
    function _encodeTokenTransfer(IERC20 _tokenFrom, uint256 _amountFrom) private view returns (bytes memory) {
        if (address(_tokenFrom) == address(0)) {
            return ExecutionLib.encodeSingle(address(this), _amountFrom, hex"");
        }
        return ExecutionLib.encodeSingle(address(_tokenFrom), 0, abi.encodeCall(IERC20.transfer, (address(this), _amountFrom)));
    }

    /**
     * @notice Encodes internal action call data
     */
    function _encodeInternalActionCall(ExecutionCallDataParams memory _params) private view returns (bytes memory) {
        bytes memory callData_ = abi.encodeWithSelector(
            this.executeProtocolActionInternal.selector,
            _params.protocolAddress,
            _params.tokenFrom,
            _params.amountFrom,
            _params.actionData,
            _params.rootDelegator,
            _params.rootDelegationHash,
            _params.balanceBefore
        );
        return ExecutionLib.encodeSingle(address(this), 0, callData_);
    }

    /**
     * @notice Builds permission contexts array
     */
    function _buildPermissionContexts(Delegation[] memory _delegations) private pure returns (bytes[] memory) {
        bytes[] memory permissionContexts_ = new bytes[](2);
        permissionContexts_[0] = abi.encode(_delegations);
        permissionContexts_[1] = abi.encode(new Delegation[](0));
        return permissionContexts_;
    }

    /**
     * @notice Builds modes array
     */
    function _buildModes() private pure returns (ModeCode[] memory) {
        ModeCode[] memory encodedModes_ = new ModeCode[](2);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();
        encodedModes_[1] = ModeLib.encodeSimpleSingle();
        return encodedModes_;
    }

    /**
     * @notice Executes the protocol action internally and updates enforcer state
     * @dev Only callable internally by this contract (`onlySelf`)
     * @param _protocolAddress The protocol address
     * @param _tokenFrom The input token
     * @param _amountFrom The amount to use
     * @param _actionData The action data (first element is the action string)
     * @param _rootDelegator The root delegator address
     * @param _rootDelegationHash The root delegation hash
     * @param _balanceBefore The balance before receiving tokens
     */
    function executeProtocolActionInternal(
        address _protocolAddress,
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        bytes memory _actionData,
        address _rootDelegator,
        bytes32 _rootDelegationHash,
        uint256 _balanceBefore
    )
        external
        onlySelf
    {
        address adapter_ = protocolAdapters[_protocolAddress];
        if (adapter_ == address(0)) revert NoAdapterForProtocol(_protocolAddress);

        (string memory action_, bytes memory originalActionData_) = abi.decode(_actionData, (string, bytes));

        _handleTokenReceipt(_tokenFrom, _amountFrom, _balanceBefore, _rootDelegator);
        _tokenFrom.safeTransfer(adapter_, _amountFrom);

        IAdapter.TransformationInfo memory transformationInfo_ = IAdapter(adapter_)
            .executeProtocolAction(
                _protocolAddress, action_, _tokenFrom, _amountFrom, abi.encode(address(this), originalActionData_)
            );

        _handleTransformationResult(transformationInfo_, _rootDelegator, _rootDelegationHash, _protocolAddress, action_);
    }

    /**
     * @notice Executes calls on behalf of this contract, authorized by the DelegationManager
     * @dev Only callable by the DelegationManager
     * @param _mode The encoded execution mode
     * @param _executionCalldata The encoded call data (single) to be executed
     * @return returnData_ An array of returned data from each executed call
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

        if (CallType.unwrap(CALLTYPE_SINGLE) != CallType.unwrap(callType_)) {
            revert UnsupportedCallType(callType_);
        }
        if (ExecType.unwrap(EXECTYPE_DEFAULT) != ExecType.unwrap(execType_)) {
            revert UnsupportedExecType(execType_);
        }

        (address target_, uint256 value_, bytes calldata callData_) = _executionCalldata.decodeSingle();
        returnData_ = new bytes[](1);
        returnData_[0] = _execute(target_, value_, callData_);
        return returnData_;
    }

    /**
     * @notice Registers a protocol adapter
     * @dev Only callable by the contract owner
     * @param _protocol The protocol contract address
     * @param _adapter The adapter contract address
     */
    function registerProtocolAdapter(address _protocol, address _adapter) external onlyOwner {
        if (_protocol == address(0) || _adapter == address(0)) revert InvalidZeroAddress();
        protocolAdapters[_protocol] = _adapter;
        emit ProtocolAdapterRegistered(_protocol, _adapter);
    }

    /**
     * @notice Removes a protocol adapter
     * @dev Only callable by the contract owner
     * @param _protocol The protocol contract address
     */
    function removeProtocolAdapter(address _protocol) external onlyOwner {
        delete protocolAdapters[_protocol];
        emit ProtocolAdapterRemoved(_protocol);
    }

    ////////////////////////////// Private/Internal Methods //////////////////////////////

    /**
     * @notice Validates that TokenTransformationEnforcer is at index 0 of root delegation caveats
     *         and sets the protocol address in args
     * @dev The TokenTransformationEnforcer must be the first caveat in the root delegation
     * @param _delegations The delegation chain; the last delegation must include the TokenTransformationEnforcer
     * @param _protocolAddress The protocol address to set in the enforcer's args
     */
    function _validateAndSetProtocol(Delegation[] memory _delegations, address _protocolAddress) private view {
        // The TokenTransformationEnforcer must be the first caveat in the root delegation
        uint256 lastIndex_ = _delegations.length - 1;
        if (
            _delegations[lastIndex_].caveats.length == 0
                || _delegations[lastIndex_].caveats[0].enforcer != address(tokenTransformationEnforcer)
        ) {
            revert TokenTransformationEnforcerNotFound();
        }

        // Set protocol address in args of TokenTransformationEnforcer caveat
        _delegations[lastIndex_].caveats[0].args = abi.encodePacked(_protocolAddress);
    }

    /**
     * @notice Handles token receipt verification and excess token return
     * @param _tokenFrom The input token
     * @param _amountFrom The expected amount
     * @param _balanceFromBefore The balance before receiving tokens
     * @param _rootDelegator The root delegator to return excess tokens to
     */
    function _handleTokenReceipt(
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        uint256 _balanceFromBefore,
        address _rootDelegator
    )
        private
    {
        uint256 tokenFromObtained_ = _getSelfBalance(_tokenFrom) - _balanceFromBefore;
        if (tokenFromObtained_ < _amountFrom) revert InsufficientTokens();
        if (tokenFromObtained_ > _amountFrom) {
            _sendTokens(_tokenFrom, tokenFromObtained_ - _amountFrom, _rootDelegator);
        }
    }

    /**
     * @notice Approves protocol to spend tokens if needed
     * @param _tokenFrom The input token
     * @param _protocolAddress The protocol address
     * @param _amountFrom The amount needed
     */
    function _approveProtocolIfNeeded(IERC20 _tokenFrom, address _protocolAddress, uint256 _amountFrom) private {
        if (_tokenFrom.allowance(address(this), _protocolAddress) < _amountFrom) {
            _tokenFrom.safeIncreaseAllowance(_protocolAddress, type(uint256).max);
        }
    }

    /**
     * @notice Approves adapter to transfer aTokens from this contract for wrapping
     * @dev Only called for Aave deposits where aTokens need to be wrapped
     * @param _adapter The adapter address
     * @param _protocolAddress The Aave Pool address
     * @param _tokenFrom The underlying token
     * @param _amountFrom The amount to approve
     */
    function _approveAdapterForATokenTransfer(
        address _adapter,
        address _protocolAddress,
        IERC20 _tokenFrom,
        uint256 _amountFrom
    )
        private
    {
        address aTokenAddress_ = IAavePool(_protocolAddress).getReserveAToken(address(_tokenFrom));
        IERC20(aTokenAddress_).safeIncreaseAllowance(_adapter, _amountFrom);
    }

    /**
     * @notice Handles the transformation result: verifies output, updates enforcer, transfers tokens, and emits event
     * @param _transformationInfo The transformation information from the adapter
     * @param _rootDelegator The root delegator address
     * @param _rootDelegationHash The root delegation hash
     * @param _protocolAddress The protocol address
     * @param _action The action string that was performed
     */
    function _handleTransformationResult(
        IAdapter.TransformationInfo memory _transformationInfo,
        address _rootDelegator,
        bytes32 _rootDelegationHash,
        address _protocolAddress,
        string memory _action
    )
        private
    {
        uint256 amountTo_ = _transformationInfo.amountTo;
        if (_getSelfBalance(IERC20(_transformationInfo.tokenTo)) < amountTo_) {
            revert InsufficientOutputTokens();
        }

        if (address(tokenTransformationEnforcer) == address(0)) revert EnforcerNotSet();
        tokenTransformationEnforcer.updateAssetState(_rootDelegationHash, _transformationInfo.tokenTo, amountTo_);

        if (amountTo_ > 0) {
            _sendTokens(IERC20(_transformationInfo.tokenTo), amountTo_, _rootDelegator);
        }

        emit ProtocolActionExecuted(
            _rootDelegationHash,
            _protocolAddress,
            _action,
            _transformationInfo.tokenFrom,
            _transformationInfo.amountFrom,
            _transformationInfo.tokenTo,
            amountTo_
        );
    }

    /**
     * @notice Sends tokens or native token to a specified recipient
     * @param _token ERC20 token to send or address(0) for native token
     * @param _amount Amount of tokens or native token to send
     * @param _recipient Address to receive the funds
     */
    function _sendTokens(IERC20 _token, uint256 _amount, address _recipient) private {
        if (address(_token) == address(0)) {
            (bool success_,) = _recipient.call{ value: _amount }("");
            if (!success_) revert FailedNativeTokenTransfer(_recipient);
        } else {
            _token.safeTransfer(_recipient, _amount);
        }
        emit TokensTransferredToDelegator(address(_token), _recipient, _amount);
    }

    /**
     * @notice Returns this contract's balance of the specified ERC20 token
     * @param _token The token to check balance for
     * @return balance_ The balance of the specified token
     */
    function _getSelfBalance(IERC20 _token) private view returns (uint256 balance_) {
        if (address(_token) == address(0)) return address(this).balance;
        return _token.balanceOf(address(this));
    }
}

