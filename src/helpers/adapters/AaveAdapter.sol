// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILendingAdapter } from "../interfaces/ILendingAdapter.sol";

/**
 * @notice Simplified Aave Pool interface for supply
 * @dev In production, use the official Aave IPool interface
 */
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/**
 * @notice Aave Data Provider interface to get aToken address
 * @dev In production, use the official Aave IProtocolDataProvider interface
 */
interface IAaveDataProvider {
    function getReserveTokensAddresses(address asset) external view returns (address aTokenAddress, address, address);
}

/**
 * @notice Interface for wrapping/unwrapping aTokens
 * @dev Wraps rebasing aTokens into fixed-supply wrapped tokens for easier tracking
 */
interface IATokenWrapper {
    function wrap(address aToken, uint256 amount) external returns (uint256 wrappedAmount);
    function unwrap(address aToken, uint256 wrappedAmount) external returns (uint256 aTokenAmount);
    function getWrappedToken(address aToken) external view returns (address wrappedToken);
}

/**
 * @title AaveAdapter
 * @notice Adapter for Aave lending protocol interactions
 * @dev Handles deposit, withdraw, borrow, and repay actions for Aave V3
 * @dev TODO: Validate and test using Aave's ATokenVault (ERC-4626) for direct deposit/withdraw
 *      of wrapped tokens without manual wrapping/unwrapping conversion steps. ATokenVault allows:
 *      - Direct deposit: underlying → vault.deposit() → wrapped token (no manual wrap needed)
 *      - Direct withdraw: wrapped token → vault.withdraw() → underlying (no manual unwrap needed)
 *      This would simplify the flow and eliminate the need for aTokenWrapper.
 */
contract AaveAdapter is ILendingAdapter {
    using SafeERC20 for IERC20;

    ////////////////////////////// State //////////////////////////////

    /// @dev Aave Pool contract address
    address public immutable aavePool;

    /// @dev Aave Data Provider contract address
    address public immutable aaveDataProvider;

    /// @dev AToken Wrapper contract address
    address public immutable aTokenWrapper;

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when action is not supported
    error UnsupportedAction(string action);

    /// @dev Error thrown when protocol address doesn't match Aave Pool
    error InvalidProtocolAddress();

    /// @dev Error thrown when address is zero
    error InvalidZeroAddress();

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the AaveAdapter
     * @param _aavePool The Aave Pool contract address
     * @param _aaveDataProvider The Aave Data Provider contract address
     * @param _aTokenWrapper The AToken Wrapper contract address
     */
    constructor(address _aavePool, address _aaveDataProvider, address _aTokenWrapper) {
        if (_aavePool == address(0) || _aaveDataProvider == address(0) || _aTokenWrapper == address(0)) {
            revert InvalidZeroAddress();
        }
        aavePool = _aavePool;
        aaveDataProvider = _aaveDataProvider;
        aTokenWrapper = _aTokenWrapper;
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Executes an Aave protocol action and returns transformation info
     * @param _protocolAddress The Aave Pool address (must match aavePool)
     * @param _action The action to perform ("deposit" or "withdraw")
     * @param _tokenFrom The input token address
     * @param _amountFrom The amount of input tokens to use
     * @param _actionData Additional data containing the AdapterManager address for balance measurement
     * @return transformationInfo_ The transformation information
     */
    function executeProtocolAction(
        address _protocolAddress,
        string calldata _action,
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        bytes calldata _actionData
    )
        external
        override
        returns (TransformationInfo memory transformationInfo_)
    {
        if (_protocolAddress != aavePool) revert InvalidProtocolAddress();

        // Decode AdapterManager address from actionData
        address adapterManager_ = abi.decode(_actionData, (address));

        bytes32 actionHash_ = keccak256(bytes(_action));

        if (actionHash_ == keccak256(bytes("deposit"))) {
            return _handleDeposit(_tokenFrom, _amountFrom, adapterManager_);
        } else if (actionHash_ == keccak256(bytes("withdraw"))) {
            return _handleWithdraw(_tokenFrom, _amountFrom, _actionData, adapterManager_);
        } else {
            revert UnsupportedAction(_action);
        }
    }

    ////////////////////////////// Private Methods //////////////////////////////

    /**
     * @notice Handles Aave deposit action
     * @param _tokenFrom The underlying token to deposit
     * @param _amountFrom The amount to deposit
     * @param _adapterManager The AdapterManager address to measure balances
     * @return transformationInfo_ The transformation information
     */
    function _handleDeposit(
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        address _adapterManager
    )
        private
        returns (TransformationInfo memory transformationInfo_)
    {
        // Get aToken address from Aave Data Provider
        (address aTokenAddress_,,) = IAaveDataProvider(aaveDataProvider).getReserveTokensAddresses(address(_tokenFrom));
        IERC20 aToken_ = IERC20(aTokenAddress_);

        // Measure aToken balance of AdapterManager before deposit
        uint256 aTokenBalanceBefore_ = aToken_.balanceOf(_adapterManager);

        // Execute deposit (supply) to Aave on behalf of AdapterManager
        // Note: AdapterManager must have approved Aave Pool before calling this adapter
        IAavePool(aavePool).supply(address(_tokenFrom), _amountFrom, _adapterManager, 0);

        // Measure aToken balance of AdapterManager after deposit
        uint256 aTokenBalanceAfter_ = aToken_.balanceOf(_adapterManager);
        uint256 aTokenAmount_ = aTokenBalanceAfter_ - aTokenBalanceBefore_;

        // Wrap the aToken to get a fixed-supply wrapped token
        // Approve wrapper to spend aTokens
        aToken_.safeIncreaseAllowance(aTokenWrapper, aTokenAmount_);

        // Get wrapped token address
        address wrappedTokenAddress_ = IATokenWrapper(aTokenWrapper).getWrappedToken(aTokenAddress_);
        IERC20 wrappedToken_ = IERC20(wrappedTokenAddress_);

        // Measure wrapped token balance before wrapping
        uint256 wrappedBalanceBefore_ = wrappedToken_.balanceOf(_adapterManager);

        // Wrap the aTokens
        IATokenWrapper(aTokenWrapper).wrap(aTokenAddress_, aTokenAmount_);

        // Measure wrapped token balance after wrapping
        uint256 wrappedBalanceAfter_ = wrappedToken_.balanceOf(_adapterManager);
        uint256 wrappedAmount_ = wrappedBalanceAfter_ - wrappedBalanceBefore_;

        return TransformationInfo({
            tokenFrom: address(_tokenFrom), amountFrom: _amountFrom, tokenTo: wrappedTokenAddress_, amountTo: wrappedAmount_
        });
    }

    /**
     * @notice Handles Aave withdraw action
     * @param _wrappedToken The wrapped aToken to withdraw
     * @param _amountFrom The amount of wrapped token to withdraw
     * @param _actionData Additional data containing underlying token address and AdapterManager address
     * @param _adapterManager The AdapterManager address to measure balances
     * @return transformationInfo_ The transformation information
     */
    function _handleWithdraw(
        IERC20 _wrappedToken,
        uint256 _amountFrom,
        bytes calldata _actionData,
        address _adapterManager
    )
        private
        returns (TransformationInfo memory transformationInfo_)
    {
        // Decode underlying token address from actionData (skip first 32 bytes which is adapterManager)
        address underlyingToken_ = abi.decode(_actionData[32:], (address));
        IERC20 underlyingToken = IERC20(underlyingToken_);

        // Get aToken address from Aave Data Provider
        (address aTokenAddress_,,) = IAaveDataProvider(aaveDataProvider).getReserveTokensAddresses(underlyingToken_);
        IERC20 aToken_ = IERC20(aTokenAddress_);

        // Measure aToken balance of AdapterManager before unwrap
        uint256 aTokenBalanceBefore_ = aToken_.balanceOf(_adapterManager);

        // Unwrap the wrapped token to get aTokens back
        // Approve wrapper to spend wrapped tokens
        _wrappedToken.safeIncreaseAllowance(aTokenWrapper, _amountFrom);

        // Unwrap wrapped tokens to get aTokens
        IATokenWrapper(aTokenWrapper).unwrap(aTokenAddress_, _amountFrom);

        // Measure aToken balance after unwrap
        uint256 aTokenBalanceAfter_ = aToken_.balanceOf(_adapterManager);
        uint256 aTokenAmount_ = aTokenBalanceAfter_ - aTokenBalanceBefore_;

        // Measure underlying token balance of AdapterManager before withdraw
        uint256 underlyingBalanceBefore_ = underlyingToken.balanceOf(_adapterManager);

        // Execute withdraw from Aave to AdapterManager using the unwrapped aToken amount
        IAavePool(aavePool).withdraw(underlyingToken_, aTokenAmount_, _adapterManager);

        // Measure underlying token balance of AdapterManager after withdraw
        uint256 underlyingBalanceAfter_ = underlyingToken.balanceOf(_adapterManager);
        uint256 underlyingAmount_ = underlyingBalanceAfter_ - underlyingBalanceBefore_;

        return TransformationInfo({
            tokenFrom: address(_wrappedToken), amountFrom: _amountFrom, tokenTo: underlyingToken_, amountTo: underlyingAmount_
        });
    }
}
