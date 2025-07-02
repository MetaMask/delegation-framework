// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IAavePool } from "./interfaces/IAavePool.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Delegation, ModeCode, Execution } from "../utils/Types.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

/// @title AaveAdapter
/// @notice Proof of concept adapter contract for Aave lending operations using delegations
/// @dev Handles token transfers and Aave supply operations through delegation-based permissions
contract AaveAdapter {
    using SafeERC20 for IERC20;

    ////////////////////// Events //////////////////////

    /// @notice Emitted when a supply operation is executed via delegation
    /// @param delegator Address of the token owner (delegator)
    /// @param delegate Address of the executor (delegate)
    /// @param token Address of the supplied token
    /// @param amount Amount of tokens supplied
    event SupplyExecuted(address indexed delegator, address indexed delegate, address indexed token, uint256 amount);

    /// @notice Emitted when a withdrawal operation is executed via delegation
    /// @param delegator Address of the token owner (delegator)
    /// @param delegate Address of the executor (delegate)
    /// @param token Address of the withdrawn token
    /// @param amount Amount of tokens withdrawn
    event WithdrawExecuted(address indexed delegator, address indexed delegate, address indexed token, uint256 amount);

    ////////////////////// Errors //////////////////////

    /// @notice Thrown when a zero address is provided for required parameters
    error InvalidZeroAddress();

    /// @notice Thrown when the number of delegations provided is not exactly one
    error InvalidDelegationsLength();

    /// @notice Thrown when the caller is not the delegator for restricted functions
    error UnauthorizedCaller();

    ////////////////////// State //////////////////////

    IDelegationManager public immutable delegationManager;
    IAavePool public immutable aavePool;

    ////////////////////// Constructor //////////////////////

    /// @notice Initializes the adapter with delegation manager and Aave pool addresses
    /// @param _delegationManager Address of the delegation manager contract
    /// @param _aavePool Address of the Aave lending pool contract
    constructor(address _delegationManager, address _aavePool) {
        if (_delegationManager == address(0) || _aavePool == address(0)) revert InvalidZeroAddress();

        delegationManager = IDelegationManager(_delegationManager);
        aavePool = IAavePool(_aavePool);
    }

    ////////////////////// Private Functions //////////////////////

    /// @notice Ensures sufficient token allowance for Aave operations
    /// @dev Checks current allowance and increases to max if needed
    /// @param _token Token to manage allowance for
    /// @param _amount Amount needed for the operation
    function _ensureAllowance(IERC20 _token, uint256 _amount) private {
        uint256 allowance_ = _token.allowance(address(this), address(aavePool));
        if (allowance_ < _amount) {
            _token.safeIncreaseAllowance(address(aavePool), type(uint256).max);
        }
    }

    ////////////////////// Public Functions //////////////////////

    /// @notice Supplies tokens to Aave using delegation-based token transfer
    /// @dev Only the delegator can execute this function, ensuring full control over supply parameters
    /// @param _delegations Array containing a single delegation for token transfer
    /// @param _token Address of the token to supply to Aave
    /// @param _amount Amount of tokens to supply
    function supplyByDelegation(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        if (_delegations.length != 1) revert InvalidDelegationsLength();
        if (_delegations[0].delegator != msg.sender) revert UnauthorizedCaller();
        if (_token == address(0)) revert InvalidZeroAddress();

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(address(_token), 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        _ensureAllowance(IERC20(_token), _amount);
        aavePool.supply(_token, _amount, msg.sender, 0);

        emit SupplyExecuted(msg.sender, msg.sender, _token, _amount);
    }

    /// @notice Supplies tokens to Aave using delegation-based token transfer with open-ended execution
    /// @dev Any delegate can execute this function, but aTokens are always credited to the delegator
    /// @param _delegations Array containing a single delegation for token transfer
    /// @param _token Address of the token to supply to Aave
    /// @param _amount Amount of tokens to supply
    function supplyByDelegationOpenEnded(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        if (_delegations.length != 1) revert InvalidDelegationsLength();
        if (_token == address(0)) revert InvalidZeroAddress();

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(address(_token), 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        _ensureAllowance(IERC20(_token), _amount);
        aavePool.supply(_token, _amount, _delegations[0].delegator, 0);

        emit SupplyExecuted(_delegations[0].delegator, msg.sender, _token, _amount);
    }

    /// @notice Withdraws tokens from Aave using delegation-based aToken transfer
    /// @dev Only the delegator can execute this function, ensuring full control over withdrawal parameters
    /// @param _delegations Array containing a single delegation for aToken transfer
    /// @param _token Address of the underlying token to withdraw from Aave
    /// @param _amount Amount of tokens to withdraw (or type(uint256).max for all)
    function withdrawByDelegation(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        if (_delegations.length != 1) revert InvalidDelegationsLength();
        if (_delegations[0].delegator != msg.sender) revert UnauthorizedCaller();
        if (_token == address(0)) revert InvalidZeroAddress();

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

        // Withdraw from Aave directly to the delegator
        aavePool.withdraw(_token, _amount, msg.sender);

        emit WithdrawExecuted(msg.sender, msg.sender, _token, _amount);
    }

    /// @notice Withdraws tokens from Aave using delegation-based aToken transfer with open-ended execution
    /// @dev Any delegate can execute this function, but underlying tokens are always sent to the delegator
    /// @param _delegations Array containing a single delegation for aToken transfer
    /// @param _token Address of the underlying token to withdraw from Aave
    /// @param _amount Amount of tokens to withdraw (or type(uint256).max for all)
    function withdrawByDelegationOpenEnded(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        if (_delegations.length != 1) revert InvalidDelegationsLength();
        if (_token == address(0)) revert InvalidZeroAddress();

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

        // Withdraw from Aave directly to the delegator
        aavePool.withdraw(_token, _amount, _delegations[0].delegator);

        emit WithdrawExecuted(_delegations[0].delegator, msg.sender, _token, _amount);
    }
}
