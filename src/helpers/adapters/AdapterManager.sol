// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";

import { IDelegationManager } from "../../interfaces/IDelegationManager.sol";
import { Delegation, ModeCode, CallType, ExecType } from "../../utils/Types.sol";
import { TokenTransformationEnforcer } from "../../enforcers/TokenTransformationEnforcer.sol";
import { ILendingAdapter } from "../interfaces/ILendingAdapter.sol";
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

    /// @dev The TokenTransformationEnforcer contract
    TokenTransformationEnforcer public immutable tokenTransformationEnforcer;

    /// @dev Mapping from protocol address to adapter address
    mapping(address protocol => address adapter) public protocolAdapters;

    ////////////////////////////// Events //////////////////////////////

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
     * @param _tokenTransformationEnforcer The TokenTransformationEnforcer contract address
     */
    constructor(
        address _owner,
        IDelegationManager _delegationManager,
        TokenTransformationEnforcer _tokenTransformationEnforcer
    )
        Ownable(_owner)
    {
        if (address(_delegationManager) == address(0) || address(_tokenTransformationEnforcer) == address(0)) {
            revert InvalidZeroAddress();
        }
        delegationManager = _delegationManager;
        tokenTransformationEnforcer = _tokenTransformationEnforcer;
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Allows this contract to receive native tokens
     */
    receive() external payable { }

    /**
     * @notice Executes a protocol action using delegations
     * @dev The msg.sender must be the leaf delegator
     * @param _protocolAddress The address of the lending protocol contract
     * @param _action The action to perform (e.g., "deposit", "withdraw")
     * @param _tokenFrom The input token address
     * @param _amountFrom The amount of input tokens to use
     * @param _actionData Additional data needed for the specific action
     * @param _delegations Array of Delegation objects, sorted leaf to root
     */
    function executeProtocolActionByDelegation(
        address _protocolAddress,
        string calldata _action,
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        bytes calldata _actionData,
        Delegation[] memory _delegations
    )
        external
    {
        uint256 delegationsLength_ = _delegations.length;
        if (delegationsLength_ == 0) revert InvalidEmptyDelegations();
        if (_delegations[0].delegator != msg.sender) revert NotLeafDelegator();

        address rootDelegator_ = _delegations[delegationsLength_ - 1].delegator;
        address adapter_ = protocolAdapters[_protocolAddress];
        if (adapter_ == address(0)) revert NoAdapterForProtocol(_protocolAddress);

        // Calculate root delegation hash
        bytes32 rootDelegationHash_ = EncoderLib._getDelegationHash(_delegations[delegationsLength_ - 1]);

        // Prepare the call that will be executed internally via onlySelf
        bytes memory encodedExecute_ = abi.encodeCall(
            this.executeProtocolActionInternal,
            (
                _protocolAddress,
                _action,
                _tokenFrom,
                _amountFrom,
                _actionData,
                rootDelegator_,
                rootDelegationHash_,
                _getSelfBalance(_tokenFrom)
            )
        );

        bytes[] memory permissionContexts_ = new bytes[](2);
        permissionContexts_[0] = abi.encode(_delegations);
        permissionContexts_[1] = abi.encode(new Delegation[](0));

        ModeCode[] memory encodedModes_ = new ModeCode[](2);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();
        encodedModes_[1] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](2);

        if (address(_tokenFrom) == address(0)) {
            executionCallDatas_[0] = ExecutionLib.encodeSingle(address(this), _amountFrom, hex"");
        } else {
            bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amountFrom));
            executionCallDatas_[0] = ExecutionLib.encodeSingle(address(_tokenFrom), 0, encodedTransfer_);
        }
        executionCallDatas_[1] = ExecutionLib.encodeSingle(address(this), 0, encodedExecute_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);
    }

    /**
     * @notice Executes the protocol action internally and updates enforcer state
     * @dev Only callable internally by this contract (`onlySelf`)
     * @param _protocolAddress The address of the lending protocol contract
     * @param _action The action to perform
     * @param _tokenFrom The input token address
     * @param _amountFrom The amount of input tokens to use
     * @param _actionData Additional data needed for the specific action
     * @param _rootDelegator The root delegator address
     * @param _rootDelegationHash The hash of the root delegation
     * @param _balanceFromBefore The contract's balance of _tokenFrom before the incoming token transfer
     */
    function executeProtocolActionInternal(
        address _protocolAddress,
        string calldata _action,
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        bytes calldata _actionData,
        address _rootDelegator,
        bytes32 _rootDelegationHash,
        uint256 _balanceFromBefore
    )
        external
        onlySelf
    {
        address adapter_ = protocolAdapters[_protocolAddress];
        if (adapter_ == address(0)) revert NoAdapterForProtocol(_protocolAddress);

        // Verify we received the expected amount
        uint256 tokenFromObtained_ = _getSelfBalance(_tokenFrom) - _balanceFromBefore;
        if (tokenFromObtained_ < _amountFrom) {
            revert InsufficientTokens();
        }

        // If we received more than needed, send excess back to root delegator
        if (tokenFromObtained_ > _amountFrom) {
            _sendTokens(_tokenFrom, tokenFromObtained_ - _amountFrom, _rootDelegator);
        }

        // Approve protocol to spend tokens (if needed)
        // For Aave/Morpho, we need to approve the protocol contract
        uint256 currentAllowance_ = _tokenFrom.allowance(address(this), _protocolAddress);
        if (currentAllowance_ < _amountFrom) {
            _tokenFrom.safeIncreaseAllowance(_protocolAddress, type(uint256).max);
        }

        // Prepare actionData with AdapterManager address for balance measurement
        bytes memory enhancedActionData_ = abi.encode(address(this), _actionData);

        // Execute protocol action via adapter
        // The adapter will measure balances of this contract and return transformation info
        ILendingAdapter.TransformationInfo memory transformationInfo_ = ILendingAdapter(adapter_)
            .executeProtocolAction(_protocolAddress, _action, _tokenFrom, _amountFrom, enhancedActionData_);

        // Reset approval (if needed, though we use max allowance above)
        // Note: In production, consider resetting to 0 for security, but requires handling non-zero to zero transitions

        // Verify we received the output tokens from the adapter
        address tokenToAddress_ = transformationInfo_.tokenTo;
        IERC20 tokenTo_ = IERC20(tokenToAddress_);
        uint256 tokenToBalance_ = _getSelfBalance(tokenTo_);

        // The adapter should have transferred tokens to this contract
        // Use the amount reported by the adapter
        uint256 amountTo_ = transformationInfo_.amountTo;

        // Verify we actually received the tokens (safety check)
        if (tokenToBalance_ < amountTo_) {
            revert InsufficientOutputTokens();
        }

        // Update enforcer state: deduct tokenFrom, add tokenTo
        // Deduct the amount used from tokenFrom
        if (_amountFrom > 0) {
            // Note: The enforcer's beforeHook should have already validated and deducted tokenFrom
            // But we need to handle the case where tokenFrom was transformed
            // Actually, the enforcer tracks available amounts, so we need to:
            // 1. The tokenFrom was already deducted by the enforcer's beforeHook when tokens were transferred to this contract
            // 2. Now we need to add the tokenTo amount to the enforcer state
            tokenTransformationEnforcer.updateAssetState(_rootDelegationHash, transformationInfo_.tokenTo, amountTo_);
        }

        // Transfer output tokens to root delegator
        if (amountTo_ > 0) {
            _sendTokens(tokenTo_, amountTo_, _rootDelegator);
        }

        emit ProtocolActionExecuted(
            _rootDelegationHash,
            _protocolAddress,
            _action,
            transformationInfo_.tokenFrom,
            transformationInfo_.amountFrom,
            transformationInfo_.tokenTo,
            amountTo_
        );
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

