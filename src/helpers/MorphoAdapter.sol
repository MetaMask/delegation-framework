// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { CallType, ExecType, Delegation, ModeCode } from "../utils/Types.sol";
import { CALLTYPE_SINGLE, EXECTYPE_DEFAULT } from "../utils/Constants.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";

import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IMorphoVault } from "./interfaces/IMorphoVault.sol";

/**
 * @title MorphoAdapter
 * @notice Adapter contract that enables Morpho Vault V2 operations through MetaMask's delegation framework
 * @dev This contract acts as an intermediary between users and Morpho Vaults, enabling delegation-based
 *      token operations without requiring direct token approvals. It supports both deposit and redemption
 *      operations using a two-step redelegation pattern:
 *
 *      Delegation Flow:
 *      1. The user creates an initial delegation to an "operator" address, which must be a DeleGator-upgraded
 *         account. This delegation includes:
 *         - A transfer enforcer to control which tokens and amounts can be transferred
 *         - A redeemer enforcer that restricts redemption to only the MorphoAdapter contract
 *
 *      2. The operator then redelegates to this MorphoAdapter contract with additional constraints:
 *         - Allowed methods enforcer limiting which functions can be called (e.g., deposit, redeem)
 *         - Limited calls enforcer restricting the delegation to a single execution
 *
 *      3. The MorphoAdapter redeems the delegation chain, transfers tokens from the user to itself,
 *         and executes the Morpho vault operation (deposit/redeem) on behalf of the user.
 *
 *      This pattern ensures that:
 *      - Users maintain fine-grained control over their token permissions
 *      - Only the MorphoAdapter can redeem the delegation for Morpho operations
 *      - Each delegation is scoped to a specific operation and limited executions
 *
 *      Key differences from AaveAdapter:
 *      - No single vault address (vaults passed as parameters to support multiple vaults)
 *      - Uses ERC-4626 standard: deposit/redeem instead of supply/withdraw
 *      - Vault shares are ERC-20 tokens at the vault address itself
 *
 *      Ownable functionality is implemented for emergency administration:
 *      - Recovery of tokens accidentally sent directly to the contract (bypassing delegation flow)
 *      - The contract is designed to never hold tokens during normal operation, making owner functions
 *        purely for exceptional circumstances
 */
contract MorphoAdapter is Ownable2Step, ExecutionHelper {
    using SafeERC20 for IERC20;
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    ////////////////////// Events //////////////////////

    /**
     * @notice Emitted when a deposit operation is executed via delegation
     * @param delegator Address of the token owner (delegator)
     * @param delegate Address of the executor (delegate)
     * @param vault Address of the Morpho vault
     * @param amount Amount of assets deposited
     */
    event DepositExecuted(address indexed delegator, address indexed delegate, address indexed vault, uint256 amount);

    /**
     * @notice Emitted when a redemption operation is executed via delegation
     * @param delegator Address of the share owner (delegator)
     * @param delegate Address of the executor (delegate)
     * @param vault Address of the Morpho vault
     * @param shares Amount of shares redeemed
     */
    event RedeemExecuted(address indexed delegator, address indexed delegate, address indexed vault, uint256 shares);

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

    ////////////////////// Modifiers //////////////////////

    /**
     * @notice Require the function call to come from the DelegationManager.
     */
    modifier onlyDelegationManager() {
        if (msg.sender != address(delegationManager)) revert NotDelegationManager();
        _;
    }

    /**
     * @notice Require the function call to come from this contract itself
     */
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    ////////////////////// State //////////////////////

    /**
     * @notice The DelegationManager contract used to redeem delegations
     */
    IDelegationManager public immutable delegationManager;

    ////////////////////// Constructor //////////////////////

    /**
     * @notice Initializes the adapter with delegation manager address
     * @param _owner Address of the contract owner
     * @param _delegationManager Address of the delegation manager contract
     */
    constructor(address _owner, address _delegationManager) Ownable(_owner) {
        if (_delegationManager == address(0)) revert InvalidZeroAddress();

        delegationManager = IDelegationManager(_delegationManager);
    }

    ////////////////////// Private Functions //////////////////////

    /**
     * @notice Ensures sufficient token allowance for vault operations
     * @dev Checks current allowance and increases to max if needed
     * @param _token Token to manage allowance for
     * @param _spender Address to approve (vault address)
     * @param _amount Amount needed for the operation
     */
    function _ensureAllowance(IERC20 _token, address _spender, uint256 _amount) private {
        uint256 allowance_ = _token.allowance(address(this), _spender);
        if (allowance_ < _amount) {
            _token.safeIncreaseAllowance(_spender, _amount);
        }
    }

    ////////////////////// Public Functions //////////////////////

    /**
     * @notice Deposits assets to a Morpho vault using delegation-based token transfer
     * @dev Only the delegator can execute this function, ensuring full control over deposit parameters.
     *      Requires exactly 2 delegations forming a chain from user to operator to this adapter.
     * @param _delegations Array containing exactly 2 delegations for the redelegation pattern
     * @param _vault Address of the Morpho vault to deposit into
     * @param _amount Amount of assets to deposit (use type(uint256).max for full balance)
     */
    function depositByDelegation(Delegation[] memory _delegations, address _vault, uint256 _amount) external {
        if (_delegations.length != 2) revert InvalidDelegationsLength();
        if (_delegations[0].delegator != msg.sender) revert UnauthorizedCaller();
        if (_vault == address(0)) revert InvalidZeroAddress();

        // Root delegator is the original token owner (last in the delegation chain)
        address rootDelegator_ = _delegations[1].delegator;

        // Get the underlying asset token from the vault
        address underlyingToken_ = IMorphoVault(_vault).asset();

        bytes[] memory permissionContexts_ = new bytes[](2);
        permissionContexts_[0] = abi.encode(_delegations);
        permissionContexts_[1] = abi.encode(new Delegation[](0));

        ModeCode[] memory encodedModes_ = new ModeCode[](2);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();
        encodedModes_[1] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](2);

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(underlyingToken_, 0, encodedTransfer_);
        executionCallDatas_[1] = ExecutionLib.encodeSingle(
            address(this), 0, abi.encodeWithSelector(this.deposit.selector, _vault, _amount, rootDelegator_)
        );

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        emit DepositExecuted(rootDelegator_, msg.sender, _vault, _amount);
    }

    /**
     * @notice Calls the actual deposit function on the Morpho vault
     * @dev This function can only be called internally by this contract (`onlySelf`).
     * @param _vault Address of the Morpho vault
     * @param _amount Amount of assets to deposit
     * @param _onBehalfOf Address that will receive the vault shares
     * @return sharesMinted Amount of shares minted
     */
    function deposit(address _vault, uint256 _amount, address _onBehalfOf) external onlySelf returns (uint256 sharesMinted) {
        address underlyingToken_ = IMorphoVault(_vault).asset();
        _ensureAllowance(IERC20(underlyingToken_), _vault, _amount);
        sharesMinted = IMorphoVault(_vault).deposit(_amount, _onBehalfOf);
    }

    /**
     * @notice Redeems shares from a Morpho vault using delegation-based share transfer
     * @dev Only the delegator can execute this function, ensuring full control over redemption parameters.
     *      Requires exactly 2 delegations forming a chain from user to operator to this adapter.
     * @param _delegations Array containing exactly 2 delegations for the redelegation pattern
     * @param _vault Address of the Morpho vault to redeem from
     * @param _shares Amount of shares to redeem (use type(uint256).max for full balance)
     */
    function redeemByDelegation(Delegation[] memory _delegations, address _vault, uint256 _shares) external {
        if (_delegations.length != 2) revert InvalidDelegationsLength();
        if (_delegations[0].delegator != msg.sender) revert UnauthorizedCaller();
        if (_vault == address(0)) revert InvalidZeroAddress();

        // Root delegator is the original share owner (last in the delegation chain)
        address rootDelegator_ = _delegations[1].delegator;

        bytes[] memory permissionContexts_ = new bytes[](2);
        permissionContexts_[0] = abi.encode(_delegations);
        permissionContexts_[1] = abi.encode(new Delegation[](0));

        ModeCode[] memory encodedModes_ = new ModeCode[](2);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();
        encodedModes_[1] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](2);

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _shares));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(_vault, 0, encodedTransfer_);
        executionCallDatas_[1] = ExecutionLib.encodeSingle(
            address(this), 0, abi.encodeWithSelector(this.redeem.selector, _vault, _shares, rootDelegator_)
        );

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        emit RedeemExecuted(rootDelegator_, msg.sender, _vault, _shares);
    }

    /**
     * @notice Calls the actual redeem function on the Morpho vault
     * @dev This function can only be called internally by this contract (`onlySelf`).
     * @param _vault Address of the Morpho vault
     * @param _shares Amount of shares to redeem
     * @param _receiver Address that will receive the withdrawn assets
     * @return assetsWithdrawn Amount of assets withdrawn
     */
    function redeem(address _vault, uint256 _shares, address _receiver) external onlySelf returns (uint256 assetsWithdrawn) {
        // The adapter owns the shares (they were transferred here), so we pass address(this) as owner
        assetsWithdrawn = IMorphoVault(_vault).redeem(_shares, _receiver, address(this));
    }

    /**
     * @notice Executes a call on behalf of this contract, authorized by the DelegationManager
     * @dev Only callable by the DelegationManager. Supports single-call execution
     *      and handles the revert logic via ExecType.
     * @dev Related: @erc7579/MSAAdvanced.sol
     * @param _mode The encoded execution mode of the transaction (CallType, ExecType, etc.)
     * @param _executionCalldata The encoded call data (single) to be executed
     * @return returnData_ An array of returned data from the executed call
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

        /* Only support single call type with default execution */
        if (CallType.unwrap(CALLTYPE_SINGLE) != CallType.unwrap(callType_)) revert UnsupportedCallType(callType_);
        if (ExecType.unwrap(EXECTYPE_DEFAULT) != ExecType.unwrap(execType_)) revert UnsupportedExecType(execType_);
        /* Process single execution directly without additional checks */
        (address target_, uint256 value_, bytes calldata callData_) = _executionCalldata.decodeSingle();
        returnData_ = new bytes[](1);
        returnData_[0] = _execute(target_, value_, callData_);
        return returnData_;
    }

    /**
     * @notice Emergency function to recover tokens accidentally sent to this contract
     * @dev This contract should never hold ERC20 tokens as all token operations are handled
     *      through delegation-based transfers that move tokens directly between users and Morpho vaults.
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
