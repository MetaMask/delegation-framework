// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { CallType, ExecType, Delegation, ModeCode } from "../utils/Types.sol";
import { CALLTYPE_SINGLE, EXECTYPE_DEFAULT } from "../utils/Constants.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IAavePool } from "./interfaces/IAavePool.sol";

/**
 * @title AaveAdapter
 * @notice Adapter contract that enables Aave lending operations through MetaMask's delegation framework
 * @dev This contract acts as an intermediary between users and Aave, enabling delegation-based token operations
 *      without requiring direct token approvals. It supports both supply and withdrawal operations using a
 *      two-step redelegation pattern:
 *
 *      Delegation Flow:
 *      1. The user creates an initial delegation to an "operator" address, which must be a DeleGator-upgraded
 *         account. This delegation includes:
 *         - A transfer enforcer to control which tokens and amounts can be transferred
 *         - A redeemer enforcer that restricts redemption to only the AaveAdapter contract
 *
 *      2. The operator then redelegates to this AaveAdapter contract with additional constraints:
 *         - Allowed methods enforcer limiting which functions can be called (e.g., supply, withdraw)
 *         - Limited calls enforcer restricting the delegation to a single execution
 *
 *      3. The AaveAdapter redeems the delegation chain, transfers tokens from the user to itself,
 *         and executes the Aave operation (supply/withdraw) on behalf of the user.
 *
 *      This pattern ensures that:
 *      - Users maintain fine-grained control over their token permissions
 *      - Only the AaveAdapter can redeem the delegation for Aave operations
 *      - Each delegation is scoped to a specific operation and limited executions
 *
 *      Ownable functionality is implemented for emergency administration:
 *      - Recovery of tokens accidentally sent directly to the contract (bypassing delegation flow)
 *      - The contract is designed to never hold tokens during normal operation, making owner functions
 *        purely for exceptional circumstances
 */
contract AaveAdapter is Ownable2Step {
    using SafeERC20 for IERC20;
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    ////////////////////// Events //////////////////////

    /**
     * @notice Emitted when a supply operation is executed via delegation
     * @param delegator Address of the token owner (delegator)
     * @param delegate Address of the executor (delegate)
     * @param token Address of the supplied token
     * @param amount Amount of tokens supplied
     */
    event SupplyExecuted(address indexed delegator, address indexed delegate, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a withdrawal operation is executed via delegation
     * @param delegator Address of the token owner (delegator)
     * @param delegate Address of the executor (delegate)
     * @param token Address of the withdrawn token
     * @param amount Amount of tokens withdrawn
     */
    event WithdrawExecuted(address indexed delegator, address indexed delegate, address indexed token, uint256 amount);

    /**
     * @notice Event emitted when stuck tokens are withdrawn by owner
     * @param token Address of the token withdrawn
     * @param recipient Address of the recipient
     * @param amount Amount of tokens withdrawn
     */
    event StuckTokensWithdrawn(IERC20 indexed token, address indexed recipient, uint256 amount);

    ////////////////////// Errors //////////////////////

    /**
     * @notice Thrown when a zero address is provided for required parameters
     */
    error InvalidZeroAddress();

    /**
     * @notice Thrown when a zero address is provided for the recipient
     */
    error InvalidRecipient();

    /**
     * @notice Thrown when the number of delegations provided is not exactly two
     */
    error InvalidDelegationsLength();

    /**
     * @notice Thrown when the batch array is empty or lengths don't match
     */
    error InvalidBatchLength();

    /**
     * @notice Thrown when the caller is not the delegator for restricted functions
     */
    error UnauthorizedCaller();

    /**
     * @notice Thrown when the caller is not the delegation manager
     */
    error NotDelegationManager();

    /**
     * @notice Thrown when the call is not made by this contract itself.
     */
    error NotSelf();

    /**
     * @notice Thrown when an execution with an unsupported CallType is made.
     */
    error UnsupportedCallType(CallType callType);

    /**
     * @notice Thrown when an execution with an unsupported ExecType is made.
     */
    error UnsupportedExecType(ExecType execType);

    ////////////////////// State //////////////////////

    /**
     * @notice The DelegationManager contract used to redeem delegations
     */
    IDelegationManager public immutable delegationManager;

    /**
     * @notice The Aave lending pool contract for supply/withdraw operations
     */
    IAavePool public immutable aavePool;

    ////////////////////// Constructor //////////////////////

    /**
     * @notice Initializes the adapter with delegation manager and Aave pool addresses
     * @param _owner Address of the contract owner
     * @param _delegationManager Address of the delegation manager contract
     * @param _aavePool Address of the Aave lending pool contract
     */
    constructor(address _owner, address _delegationManager, address _aavePool) Ownable(_owner) {
        if (_delegationManager == address(0) || _aavePool == address(0)) revert InvalidZeroAddress();

        delegationManager = IDelegationManager(_delegationManager);
        aavePool = IAavePool(_aavePool);
    }

    ////////////////////// Private Functions //////////////////////

    /**
     * @notice Ensures sufficient token allowance for Aave operations
     * @dev Checks current allowance and increases to max if needed
     * @param _token Token to manage allowance for
     * @param _amount Amount needed for the operation
     */
    function _ensureAllowance(IERC20 _token, uint256 _amount) private {
        uint256 allowance_ = _token.allowance(address(this), address(aavePool));
        if (allowance_ < _amount) {
            _token.safeIncreaseAllowance(address(aavePool), _amount);
        }
    }

    ////////////////////// Public Functions //////////////////////

    /**
     * @notice Parameters for a single supply operation in a batch
     */
    struct SupplyParams {
        Delegation[] delegations;
        address token;
        uint256 amount;
    }

    /**
     * @notice Supplies tokens to Aave using delegation-based token transfer
     * @dev Only the delegator can execute this function, ensuring full control over supply parameters.
     *      Requires exactly 2 delegations forming a chain from user to operator to this adapter.
     * @param _delegations Array containing exactly 2 delegations for the redelegation pattern
     * @param _token Address of the token to supply to Aave
     * @param _amount Amount of tokens to supply (use type(uint256).max for full balance)
     */
    function supplyByDelegation(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        _executeSupplyByDelegation(_delegations, _token, _amount, msg.sender);
    }

    /**
     * @notice Supplies tokens to Aave using multiple delegation streams, executed sequentially
     * @dev Each element in _supplyStreams is executed one after the other. The caller must be the delegator
     *      (first delegate in the chain) for each stream. Useful for batch operations across multiple users/tokens.
     * @param _supplyStreams Array of supply parameters, each containing delegations, token, and amount
     */
    function supplyByDelegationBatch(SupplyParams[] memory _supplyStreams) external {
        uint256 streamsLength_ = _supplyStreams.length;
        if (streamsLength_ == 0) revert InvalidBatchLength();

        address caller_ = msg.sender;
        for (uint256 i = 0; i < streamsLength_;) {
            SupplyParams memory params_ = _supplyStreams[i];
            _executeSupplyByDelegation(params_.delegations, params_.token, params_.amount, caller_);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Internal implementation of supply by delegation
     * @param _delegations Delegation chain for the redelegation pattern
     * @param _token Token to supply
     * @param _amount Amount to supply
     * @param _caller Authorized caller (must match first delegator in chain)
     */
    function _executeSupplyByDelegation(
        Delegation[] memory _delegations,
        address _token,
        uint256 _amount,
        address _caller
    )
        internal
    {
        uint256 length_ = _delegations.length;
        if (length_ < 2) revert InvalidDelegationsLength();
        if (_delegations[0].delegator != _caller) revert UnauthorizedCaller();
        if (_token == address(0)) revert InvalidZeroAddress();

        // Root delegator is the original token owner (last in the delegation chain)
        address rootDelegator_ = _delegations[length_ - 1].delegator;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(address(_token), 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        _ensureAllowance(IERC20(_token), _amount);
        aavePool.supply(_token, _amount, rootDelegator_, 0);

        emit SupplyExecuted(rootDelegator_, _caller, _token, _amount);
    }

    /**
     * @notice Withdraws tokens from Aave using delegation-based aToken transfer
     * @dev Only the delegator can execute this function, ensuring full control over withdrawal parameters.
     *      Requires exactly 2 delegations forming a chain from user to operator to this adapter.
     * @param _delegations Array containing exactly 2 delegations for the redelegation pattern
     * @param _token Address of the underlying token to withdraw from Aave
     * @param _amount Amount of tokens to withdraw (use type(uint256).max for full balance)
     */
    function withdrawByDelegation(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        if (_delegations.length < 2) revert InvalidDelegationsLength();
        if (_delegations[0].delegator != msg.sender) revert UnauthorizedCaller();
        if (_token == address(0)) revert InvalidZeroAddress();

        // Root delegator is the original token owner (last in the delegation chain)
        address rootDelegator_ = _delegations[1].delegator;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        // Get the aToken address for the underlying token
        IERC20 aToken_ = IERC20(aavePool.getReserveAToken(_token));

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(address(aToken_), 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        aavePool.withdraw(_token, _amount, rootDelegator_);

        emit WithdrawExecuted(rootDelegator_, msg.sender, _token, _amount);
    }

    /**
     * @notice Emergency function to recover tokens accidentally sent to this contract
     * @dev This contract should never hold ERC20 tokens as all token operations are handled
     *      through delegation-based transfers that move tokens directly between users and Aave.
     *      This function is only for recovering tokens that users may have sent to this contract
     *      by mistake (e.g., direct transfers instead of using delegation functions).
     * @param _token The token to be recovered
     * @param _amount The amount of tokens to recover
     * @param _recipient The address to receive the recovered tokens
     */
    function withdrawEmergency(IERC20 _token, uint256 _amount, address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidRecipient();

        IERC20(_token).safeTransfer(_recipient, _amount);

        emit StuckTokensWithdrawn(_token, _recipient, _amount);
    }
}
