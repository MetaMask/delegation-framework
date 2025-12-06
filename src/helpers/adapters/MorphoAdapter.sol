// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILendingAdapter } from "../interfaces/ILendingAdapter.sol";

/**
 * @notice Simplified Morpho Market interface
 * @dev In production, use the official Morpho interfaces
 */
interface IMorphoMarket {
    function supply(address underlying, uint256 amount, address onBehalfOf, bytes calldata data) external;
    function withdraw(address underlying, uint256 amount, address onBehalfOf, address receiver) external;
}

/**
 * @notice Morpho Positions Manager interface to get market addresses
 * @dev In production, use the official Morpho interfaces
 */
interface IMorphoPositionsManager {
    function market(address underlying) external view returns (address marketAddress);
}

/**
 * @title MorphoAdapter
 * @notice Adapter for Morpho lending protocol interactions
 * @dev Handles deposit and withdraw actions for Morpho markets
 */
contract MorphoAdapter is ILendingAdapter {
    using SafeERC20 for IERC20;

    ////////////////////////////// State //////////////////////////////

    /// @dev Morpho Positions Manager contract address
    address public immutable morphoPositionsManager;

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when action is not supported
    error UnsupportedAction(string action);

    /// @dev Error thrown when protocol address doesn't match Morpho
    error InvalidProtocolAddress();

    /// @dev Error thrown when market is not found for underlying asset
    error MarketNotFound(address underlying);

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the MorphoAdapter
     * @param _morphoPositionsManager The Morpho Positions Manager contract address
     */
    constructor(address _morphoPositionsManager) {
        if (_morphoPositionsManager == address(0)) {
            revert("MorphoAdapter:invalid-address");
        }
        morphoPositionsManager = _morphoPositionsManager;
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Executes a Morpho protocol action and returns transformation info
     * @param _protocolAddress The Morpho Positions Manager address (must match morphoPositionsManager)
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
        if (_protocolAddress != morphoPositionsManager) revert InvalidProtocolAddress();

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
     * @notice Handles Morpho deposit action
     * @param _tokenFrom The underlying token to deposit
     * @param _amountFrom The amount to deposit
     * @param _adapterManager The AdapterManager address to measure balances
     * @return transformationInfo_ The transformation information
     */
    function _handleDeposit(IERC20 _tokenFrom, uint256 _amountFrom, address _adapterManager)
        private
        returns (TransformationInfo memory transformationInfo_)
    {
        // Get Morpho market address for the underlying token
        address marketAddress_ = IMorphoPositionsManager(morphoPositionsManager).market(address(_tokenFrom));
        if (marketAddress_ == address(0)) revert MarketNotFound(address(_tokenFrom));

        // In Morpho, the market token (mToken) represents the position
        // For simplicity, we'll use the market address as the tokenTo
        // In production, you'd query the market contract for the actual mToken address
        IERC20 mToken_ = IERC20(marketAddress_);

        // Measure mToken balance of AdapterManager before deposit
        uint256 mTokenBalanceBefore_ = mToken_.balanceOf(_adapterManager);

        // Execute deposit (supply) to Morpho on behalf of AdapterManager
        IMorphoMarket(marketAddress_).supply(address(_tokenFrom), _amountFrom, _adapterManager, hex"");

        // Measure mToken balance of AdapterManager after deposit
        uint256 mTokenBalanceAfter_ = mToken_.balanceOf(_adapterManager);
        uint256 mTokenAmount_ = mTokenBalanceAfter_ - mTokenBalanceBefore_;

        return TransformationInfo({
            tokenFrom: address(_tokenFrom),
            amountFrom: _amountFrom,
            tokenTo: marketAddress_,
            amountTo: mTokenAmount_
        });
    }

    /**
     * @notice Handles Morpho withdraw action
     * @param _mToken The mToken to withdraw
     * @param _amountFrom The amount of mToken to withdraw
     * @param _actionData Additional data containing underlying token address and AdapterManager address
     * @param _adapterManager The AdapterManager address to measure balances
     * @return transformationInfo_ The transformation information
     */
    function _handleWithdraw(IERC20 _mToken, uint256 _amountFrom, bytes calldata _actionData, address _adapterManager)
        private
        returns (TransformationInfo memory transformationInfo_)
    {
        // Decode underlying token address from actionData (skip first 32 bytes which is adapterManager)
        address underlyingToken_ = abi.decode(_actionData[32:], (address));
        IERC20 underlyingToken = IERC20(underlyingToken_);

        // Measure underlying token balance of AdapterManager before withdraw
        uint256 underlyingBalanceBefore_ = underlyingToken.balanceOf(_adapterManager);

        // Execute withdraw from Morpho to AdapterManager
        IMorphoMarket(address(_mToken)).withdraw(underlyingToken_, _amountFrom, _adapterManager, _adapterManager);

        // Measure underlying token balance of AdapterManager after withdraw
        uint256 underlyingBalanceAfter_ = underlyingToken.balanceOf(_adapterManager);
        uint256 underlyingAmount_ = underlyingBalanceAfter_ - underlyingBalanceBefore_;

        return TransformationInfo({
            tokenFrom: address(_mToken),
            amountFrom: _amountFrom,
            tokenTo: underlyingToken_,
            amountTo: underlyingAmount_
        });
    }
}

